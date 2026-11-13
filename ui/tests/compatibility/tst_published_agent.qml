import QtQuick
import QtTest
import Quickshell
import "../.." as Omamail
import "../../account/Accounts.js" as Accounts
import "../qml/BackendFixture.js" as BackendFixture

// Docs: Run through tests/test_agent_published_qml.py with the pinned executable; shell, mail context and Claude are synthetic while job RPC is real.
Item {
  width: 1000; height: 720
  QtObject { id: shellStore; function updateEntryInline(id, entry) {} }
  Omamail.Service { id: service; shell: shellStore; manifest: ({id:"omamail"}) }
  Omamail.App { id: app; service: service }
  TestCase {
    name: "PublishedAgentFlow"
    when: windowShown
    readonly property int publishedApi: Number(Quickshell.env("OMAMAIL_TEST_AGENT_API"))
    property var fixture
    property var rpcErrors: []
    property var requests: []
    readonly property string owner: "ada@example.test"
    function forward(parameters, request) {
      requests = requests.concat([request])
      var xhr = new XMLHttpRequest()
      xhr.open("POST", Quickshell.env("OMAMAIL_TEST_AGENT_URL"))
      xhr.onreadystatechange = function() {
        if (xhr.readyState !== XMLHttpRequest.DONE) return
        if (xhr.status !== 200) { rpcErrors = rpcErrors.concat(["HTTP " + xhr.status]); return }
        var reply = JSON.parse(xhr.responseText)
        if (reply.error) rpcErrors = rpcErrors.concat([JSON.stringify(reply.error)])
        BackendFixture.respond(service, request, reply.result, reply.error)
      }
      xhr.send(JSON.stringify(request))
      return undefined
    }
    function initTestCase() {
      verify(Quickshell.env("OMAMAIL_TEST_AGENT_URL") !== "", "Use the published-binary test wrapper")
      verify(publishedApi >= 5, "The wrapper must provide the verified executable API")
      fixture = BackendFixture.install(service)
      var answers = {}
      var methods = ["agent.jobStart", "agent.jobsList", "agent.jobShow", "agent.jobsProjection"]
      if (publishedApi >= 6) methods.push("agent.providerStatus")
      for (var methodIndex = 0; methodIndex < methods.length; methodIndex++) answers[methods[methodIndex]] = forward
      answers["agent.context"] = function(parameters) {
        return {payload:{accountId:owner,account:"ada@example.test",messageId:"message-1",
          subject:"Thursday",message:"Can we meet Thursday at 10?",prompt:parameters.prompt}}
      }
      fixture.answers = answers
      BackendFixture.markReady(service, publishedApi)
      var list = Accounts.add(Accounts.emptyList(), {email:"ada@example.test",provider:"gmail",
        label:"",signature:""})
      service.accountList = Accounts.setActive(list, owner)
      service.accountsLoaded = true
      service.refreshCurrent()
      tryCompare(service, "activeAccountId", owner)
      var account = service.accountAt(0)
      account.auth.toolsChecked = true; account.auth.missingTools = []
      account.auth.credentials = {clientId:"123-example.apps.googleusercontent.com",clientSecret:"synthetic-secret"}
      account.auth.loggedIn = true
      tryCompare(account, "ready", true)
      account.profile = {email:"ada@example.test"}
      account.messages = [{id:"message-1",subject:"Thursday",from:{email:"bob@example.test",display:"Bob Example"},
        time:"10:00",to:[{email:"ada@example.test"}],cc:[],unread:false,labelIds:["INBOX"]}]
      app.opened = true
    }
    function enabledButton(item, name) {
      var found = item.objectName === name && item.enabled && item.visible ? item : null
      var children = item.children || []
      for (var childIndex = 0; childIndex < children.length; childIndex++) found = enabledButton(children[childIndex], name) || found
      return found
    }
    function awaitAnswer(panel, previous) {
      tryVerify(function() { return panel.job && panel.job.id !== previous && panel.job.state === "done" }, 15000)
      tryVerify(function() { return panel.output.indexOf("Synthetic Claude reply") >= 0 }, 5000)
      verify(panel.canContinue)
      compare(rpcErrors, [])
      return panel.job.id
    }
    function test_reader_and_composer_keep_claude_with_the_published_pin() {
      tryCompare(service, "agentAvailable", true)
      compare(service.backendCanChooseAgent, publishedApi >= 6)
      compare(service.backendCanAgentProposals, publishedApi >= 6)
      app.cursorId = "message-1"
      verify(app.runShortcut("askAgent", "Alt+G"), "Published-pin user can open AI from the mailbox")
      verify(app.agentPrompt.opened)
      verify(app.agentPrompt.submit("What's the gist?", false))
      var first = awaitAnswer(app.agentPrompt, "")
      verify(app.agentPrompt.submit("Explain a little more", false))
      awaitAnswer(app.agentPrompt, first)
      app.agentPrompt.close()
      app.startCompose("new")
      var to = findChild(app, "compose-to-field")
      to.text = "bob@example.test"
      var editor = findChild(app, "compose-body-editor")
      editor.text = "Thursday works for me."
      verify(app.runShortcut("askAgent", "Alt+G"))
      verify(app.composeAgent.opened)
      verify(app.composeAgent.submit("Make this more casual", false))
      first = awaitAnswer(app.composeAgent, "")
      verify(app.composeAgent.submit("Make it shorter", false))
      awaitAnswer(app.composeAgent, first)
      var action = publishedApi >= 6 ? "agent-apply-draft" : "agent-replace"
      tryVerify(function() { return enabledButton(app.composeAgent, action) !== null })
      mouseClick(enabledButton(app.composeAgent, action))
      compare(editor.text, "Synthetic Claude reply")
      compare(to.text, "bob@example.test")
      var starts = requests.filter(function(request) { return request.method === "agent.jobStart" })
      compare(starts.length, 4)
      for (var requestIndex = 0; requestIndex < starts.length; requestIndex++) {
        compare(starts[requestIndex].params.provider, undefined)
        compare(starts[requestIndex].params.model, undefined)
        var payload = starts[requestIndex].params.payload
        if (typeof payload === "string") payload = JSON.parse(payload)
        if (publishedApi < 6) {
          compare(payload.envelope, undefined)
          compare(payload.draftUpdate, undefined)
          compare(payload.mailUpdate, undefined)
        }
      }
      compare(fixture.requests.filter(function(request) {
        return request.method === "outbox.enqueue" || request.method === "message.compose"
      }).length, 0, "Reading and inserting the answer must never send mail")
      compare(fixture.requests.some(function(request) { return request.method === "agent.providerStatus" }), publishedApi >= 6)
    }
  }
}

import QtQuick 2.15
import QtTest 1.3
import qs.Commons
import qs.Commons as Commons
import "../.." as Omamail
import "../../components" as Mail
import "../../account/Accounts.js" as Accounts
import "BackendFixture.js" as BackendFixture
import "NativeIntentFixture.js" as NativeIntentFixture

// Invariant: projections use native code; mail-context reads and model starts remain controlled at their RPC boundaries.
Item {
  width: 900
  height: 600

  QtObject {
    id: shellStore
    function updateEntryInline(_id, _entry) {}
    function hide(_id) {}
  }

  Omamail.Service {
    id: mailService
    shell: shellStore
    manifest: ({ id: "omamail", __sourceDir: "/tmp/omamail-test" })
  }

  QtObject {
    id: bridge
    property bool ready: true
    property int apiVersion: 6
    property var modelBridge: null
    property var starts: []
    property var listed: []
    property var projectionErrors: []
    property bool holdStarts: false
    property var held: []
    property string refuse: ""
    function call(method, params, callback) {
      if (method === "agent.providerStatus") { callback({available:true,provider:"claude"}, ""); return }
      if (method === "agent.jobsProjection") { modelBridge.call(method, params, function(result, error) { if (error) bridge.projectionErrors = bridge.projectionErrors.concat([error]); callback(result, error) }); return }
      if (method === "agent.jobsList") { callback(listed, ""); return }
      if (method === "agent.jobStart") {
        starts = starts.concat([params.payload])
        if (refuse !== "") { var code = refuse; Qt.callLater(function() { callback(null, { code: -32000, message: code }) }); return }
        if (holdStarts) { held = held.concat([callback]); return }
        Qt.callLater(function() { callback({ id: "started" }, "") })
        return
      }
      callback(null, "unsupported_test_method")
    }
    function release() {
      var calls = held
      held = []
      for (var callIndex = 0; callIndex < calls.length; callIndex++) calls[callIndex]({ id: "started" }, "")
    }
  }

  Mail.EventSuggestionCard {
    id: card
    width: 500
    textColor: Commons.Color.foreground
    accentColor: Commons.Color.accent
    dimColor: Commons.Color.foreground
    dimmerColor: Commons.Color.foreground
    panelFontFamily: "monospace"
  }
  SignalSpy { id: added; target: card; signalName: "addRequested" }
  SignalSpy { id: dismissed; target: card; signalName: "dismissRequested" }

  TestCase {
    name: "EventSuggestions"
    when: windowShown

    readonly property string ada: "ada@example.com"
    readonly property string bob: "bob@example.com"
    property var listener: null
    property var contexts: []

    function entry(email) {
      return {
        email: email, provider: "gmail",
        label: "", signature: ""
      }
    }
    function summary(id, subject, from, labels) {
      return ({ id: id, threadId: "", subject: subject, snippet: "", time: "", date: new Date().toISOString(),
        from: { email: from || "bob@example.com", display: "Bob" }, unread: false, starred: false, inInbox: true,
        labelIds: labels || ["INBOX"] })
    }
    function runner() {
      var children = mailService.children
      for (var childIndex = 0; childIndex < children.length; childIndex++) {
        var candidate = children[childIndex].item || children[childIndex]
        if (candidate.jobs !== undefined && candidate.pluginDir !== undefined) return candidate
      }
      return null
    }
    function calendarFor(email) {
      return ({ version: 1, sources: [{
        id: "google:" + email, kind: "google", name: "Home", accountId: email,
        calendarId: "primary", enabled: true, readOnly: false, colorKey: "accent" }] })
    }
    function settled() { wait(1); tryVerify(function() { return bridge.modelBridge.pending.length === 0 }) }
    function setJobs(jobs) {
      bridge.listed = jobs
      runner().applyListing(jobs)
      settled()
      compare(bridge.projectionErrors.length, 0, "Synthetic looks must satisfy the native projection contract")
    }
    function look(id, account, message, state, events) {
      return { id: id, kind: "events", messageId: message, messageIds: [message], accountId: account, state: state,
        created: 1, createdOrder: Number(id.replace(/\D/g, "")) || 1, events: events || [] }
    }

    function initTestCase() {
      BackendFixture.markReady(mailService, 2)
      listener = BackendFixture.install(mailService)
      listener.answers["agent.context"] = function(params) {
        contexts = contexts.concat([params])
        var row = params.summaries[0]
        return { payload: { messageId: params.ids[0], accountId: params.accountId, account: params.accountId,
          folder: params.folder, subject: row.subject, prompt: params.prompt, message: "Subject: " + row.subject + "\n\n" + String(row.bodyText || "") } }
      }
      bridge.modelBridge = NativeIntentFixture.backend(mailService)
    }

    function seed(activeId) {
      var list = Accounts.emptyList()
      list = Accounts.add(list, entry("ada@example.com"))
      list = Accounts.add(list, entry("bob@example.com"))
      list = Accounts.setActive(list, activeId)
      mailService.activeIndex = -1
      mailService.accountList = list
      mailService.accountsLoaded = true
      wait(0)
      mailService.refreshCurrent()
      tryCompare(mailService, "activeAccountId", activeId)
      var agent = runner()
      verify(agent !== null)
      agent.backend = null
      bridge.starts = []
      bridge.projectionErrors = []
      bridge.holdStarts = false
      bridge.held = []
      bridge.refuse = ""
      contexts = []
      agent.backend = bridge
      setJobs([])
      return agent
    }
    function open(account, id, subject, text, from, labels) {
      account.selectedId = id
      account.selectedMessage = summary(id, subject, from, labels)
      account.selectedBody = ({ text: text, source: "" })
    }
    function lastStart() {
      tryVerify(function() { return bridge.starts.length > 0 }, 1000, "a look was started")
      return bridge.starts[bridge.starts.length - 1]
    }
    function named(item, name, output) {
      if (item.objectName === name) output.push(item)
      var children = item.children || []
      for (var childIndex = 0; childIndex < children.length; childIndex++) named(children[childIndex], name, output)
      return output
    }

    function init() {
      if (Qt.platform.os !== "linux") { skip("The plugin agent backend is Linux-only"); return }
      added.clear(); dismissed.clear(); card.suggestions = []
      BackendFixture.markReady(mailService, 2)
    }

    function test_a_dated_message_is_looked_at_once_when_asked() {
      var agent = seed(ada)
      var adas = mailService.accountAt(0)
      mailService.settings = ({ suggestEvents: false })
      open(adas, "message-42", "Dinner?", "Dinner on Thursday at 7pm?")
      wait(20)
      compare(bridge.starts.length, 0, "off is off")
      compare(contexts.length, 0, "and nothing is even read")

      mailService.settings = ({ suggestEvents: true })
      var first = lastStart()
      compare(first.messageId, "message-42", "on looks at what is open")
      compare(first.events, true)
      compare(first.accountId, ada)
      compare(first.prompt, "Find the calendar events in this message.")
      compare(contexts[0].ids[0], "message-42")
      compare(contexts[0].accountId, ada)
      verify(first.message.indexOf("Dinner?") >= 0)
      tryCompare(agent, "starting", false)

      bridge.starts = []
      open(adas, "message-43", "Hello", "Just saying hi")
      wait(20)
      compare(bridge.starts.length, 0, "no date, no look")

      open(adas, "message-44", "Dinner?", "Dinner on Thursday at 7pm?")
      compare(lastStart().messageId, "message-44")
      tryCompare(agent, "starting", false)

      bridge.starts = []
      open(adas, "message-46", "Dinner Thursday at 7pm at Luigi's", "see you there")
      compare(lastStart().messageId, "message-46", "the subject counts")
      tryCompare(agent, "starting", false)

      bridge.starts = []
      open(adas, "message-47", "Run failed: nightly", "Run failed at 14:30 on Sep 12", "notifications@github.com")
      open(adas, "message-48", "Sale ends Sep 30", "Only until Sep 30 at 23:59!", "bob@example.com", ["INBOX", "CATEGORY_PROMOTIONS"])
      adas.selectedUnsubscribe = ({ url: "https://list.example/leave" })
      open(adas, "message-49", "Meetup Thursday at 7pm", "Join us on Thursday at 7pm", "bob@example.com")
      adas.selectedUnsubscribe = null
      wait(20)
      compare(bridge.starts.length, 0, "no look at a notification, a promotion or a list")
      compare(contexts.length, 3, "and none of them was read either")

      setJobs([look("look-44", ada, "message-44", "running")])
      bridge.starts = []
      open(adas, "message-44", "Dinner?", "Dinner on Thursday at 7pm?")
      wait(20)
      compare(bridge.starts.length, 0, "one look per message")

      setJobs([look("look-1", ada, "message-1", "running"), look("look-2", ada, "message-2", "queued")])
      open(adas, "message-45", "Lunch?", "Lunch tomorrow at noon, 12:30?")
      wait(20)
      compare(bridge.starts.length, 0, "no third look while two run")
      setJobs([look("look-1", ada, "message-1", "done"), look("look-2", ada, "message-2", "queued")])
      compare(lastStart().messageId, "message-45")
    }

    function test_what_was_found_is_the_open_messages_and_the_accounts() {
      var agent = seed(ada)
      var adas = mailService.accountAt(0)
      mailService.settings = ({ suggestEvents: true })
      var start = new Date(2026, 8, 12, 19, 0).getTime()
      var allDayStart = new Date(2026, 8, 13).getTime()
      var allDayEnd = new Date(2026, 8, 15).getTime()
      setJobs([
        look("look-44", ada, "message-44", "done",
          [{ title: "Dinner with Bob", startMs: start, endMs: start + 7200000, location: "Luigi's" },
            { title: "Offsite", startMs: allDayStart, endMs: allDayEnd, allDay: true,
              location: "Conference centre", notes: "Bring your notebook" }]),
        look("look-99", bob, "message-44", "done", [{ title: "Bob's own", startMs: start, endMs: start + 3600000 }])
      ])
      adas.selectedId = "message-44"
      adas.selectedMessage = summary("message-44", "Dinner?")
      tryVerify(function() { return mailService.eventSuggestions.length === 2 }, 1000)
      compare(mailService.eventSuggestions[0].title, "Dinner with Bob")
      compare(mailService.eventSuggestions[0].key, "look-44:0")
      compare(mailService.agentJobs["message-44"], undefined, "a look draws no glyph")
      compare(mailService.agentAttention, false, "and asks for nobody")

      mailService.dismissSuggestion("look-44:0")
      tryVerify(function() { return mailService.eventSuggestions.length === 1 }, 1000)
      compare(mailService.eventSuggestions[0].title, "Offsite")

      adas.selectedId = "message-45"
      adas.selectedMessage = summary("message-45", "Other")
      tryVerify(function() { return mailService.eventSuggestions.length === 0 }, 1000, "another message, nothing found for it")

      // Invariant: a dismissal belongs to one account even when another account has the same message ID.
      mailService.switchToIndex(1)
      tryCompare(mailService, "activeAccountId", bob)
      var bobs = mailService.accountAt(1)
      bobs.selectedId = "message-44"
      bobs.selectedMessage = summary("message-44", "Dinner?")
      tryVerify(function() { return mailService.eventSuggestions.length === 1 }, 1000)
      compare(mailService.eventSuggestions[0].title, "Bob's own")
      mailService.switchToIndex(0)
      tryCompare(mailService, "activeAccountId", ada)

      adas.selectedId = "message-44"
      adas.selectedMessage = summary("message-44", "Dinner?")
      tryVerify(function() { return mailService.eventSuggestions.length === 1 }, 1000)
      var handed = null
      var controller = mailService.calendarController
      controller.sourceList = calendarFor("ada@example.com")
      tryVerify(function() { return controller.writableSourceGroups.length > 0 }, 1000)
      controller.composeRequested.connect(function(prefill) { handed = prefill })
      verify(mailService.addSuggestedEvent(mailService.eventSuggestions[0]))
      verify(handed !== null)
      compare(handed.title, "Offsite")
      compare(handed.allDay, true, "the composer receives an all-day event")
      compare(handed.startMs, allDayStart, "the original start date reaches the composer")
      compare(handed.endMs, allDayEnd, "the exclusive multi-day end reaches the composer")
      compare(handed.location, "Conference centre")
      compare(handed.description, "Bring your notebook", "the original notes reach the composer")
      compare(handed.accountId, ada, "the suggestion stays with the reading account")
      controller.eventCreated(false, "refused")
      compare(mailService.eventSuggestions.length, 1, "a refused write keeps the suggestion")
      controller.eventCreated(true, "")
      tryVerify(function() { return mailService.eventSuggestions.length === 0 }, 1000, "a written event is no longer a suggestion")
    }

    function test_a_look_waits_for_the_runner_and_asks_once() {
      var agent = seed(ada)
      var adas = mailService.accountAt(0)
      mailService.settings = ({ suggestEvents: true })
      bridge.holdStarts = true
      open(adas, "message-50", "Lunch?", "Lunch tomorrow at 12:30?")
      compare(lastStart().messageId, "message-50")
      tryCompare(agent, "starting", true)
      open(adas, "message-51", "Coffee?", "Coffee Friday at 9am?")
      wait(20)
      compare(bridge.starts.length, 1, "the runner is busy, so the look waits")
      compare(contexts.length, 1, "and the message is not read for nothing")
      bridge.release()
      tryCompare(agent, "starting", false)
      tryVerify(function() { return bridge.starts.length === 2 }, 1000, "and starts when it is free")
      compare(bridge.starts[1].messageId, "message-51")
      bridge.release()
      tryCompare(agent, "starting", false)
      // Invariant: a second body arrival before projection refresh must not start the same message twice.
      adas.selectedBody = ({ text: "Coffee Friday at 9am? (live)", source: "" })
      wait(20)
      compare(bridge.starts.length, 2, "asked once")
    }

    function test_add_respects_the_composer_and_the_calendars() {
      var agent = seed(ada)
      var adas = mailService.accountAt(0)
      mailService.settings = ({ suggestEvents: true })
      var start = new Date(2026, 8, 12, 19, 0).getTime()
      setJobs([look("look-46", ada, "message-46", "done", [{ title: "Dinner", startMs: start, endMs: start + 3600000 }])])
      adas.selectedId = "message-46"
      adas.selectedMessage = summary("message-46", "Dinner?")
      tryVerify(function() { return mailService.eventSuggestions.length === 1 }, 1000)
      var controller = mailService.calendarController
      var handed = []
      controller.composeRequested.connect(function(prefill) { handed.push(prefill) })
      controller.sourceList = ({ version: 1, sources: [] })
      compare(mailService.addSuggestedEvent(mailService.eventSuggestions[0]), false, "no calendar, no composer")
      verify(adas.lastError.indexOf("No calendar") >= 0, adas.lastError)
      compare(handed.length, 0)
      controller.sourceList = calendarFor("ada@example.com")
      tryVerify(function() { return controller.writableSourceGroups.length > 0 }, 1000)
      controller.composerHeld = true
      compare(mailService.addSuggestedEvent(mailService.eventSuggestions[0]), false)
      verify(adas.lastError.indexOf("Finish the event") >= 0, adas.lastError)
      controller.composerHeld = false
      verify(mailService.addSuggestedEvent(mailService.eventSuggestions[0]))
      compare(handed.length, 1)
      compare(handed[0].accountId, ada, "the reading mailbox's calendar")
      controller.composeEnded()
      controller.eventCreated(true, "")
      compare(mailService.eventSuggestions.length, 1, "an event written after the composer closed is not this one")
    }

    // Invariant: an unsupported system agent suppresses background checks until the selection is reset.
    function test_another_default_agent_refuses_once_and_quietly() {
      var agent = seed(ada)
      var adas = mailService.accountAt(0)
      mailService.settings = ({ suggestEvents: true })
      bridge.refuse = "agent_choose_claude"
      var line = adas.lastError
      open(adas, "message-60", "Dinner?", "Dinner on Thursday at 7pm?")
      compare(lastStart().messageId, "message-60")
      tryCompare(agent, "starting", false)
      compare(adas.lastError, line, "a refused look puts nothing on the status line")
      open(adas, "message-61", "Lunch?", "Lunch tomorrow at 12:30?")
      wait(20)
      compare(bridge.starts.length, 1, "and nothing more is asked this session")
      compare(contexts.length, 1, "nor read")
      mailService.settings = ({ suggestEvents: false })
      bridge.refuse = ""
      mailService.settings = ({ suggestEvents: true })
      tryVerify(function() { return bridge.starts.length === 2 }, 1000, "off and on asks again")
      compare(bridge.starts[1].messageId, "message-61")
    }

    // Invariant: API2 is the fixed suggestion feature floor; later release labels cannot raise it.
    function test_event_suggestions_require_api_two_across_releases() {
      var agent = seed(ada)
      var adas = mailService.accountAt(0)
      mailService.backend.protocolInfo = { apiVersion: 1, protocol: 1, version: "0.0.0" }
      mailService.backendRuntime.latestApiVersion = 2
      mailService.settings = ({ suggestEvents: true })
      open(adas, "message-70", "Dinner?", "Dinner on Thursday at 7pm?")
      wait(20)
      compare(bridge.starts.length, 0, "API 1 cannot run event suggestions")
      compare(contexts.length, 0, "no mail is read for an unsupported feature")
      mailService.backendRuntime.latestApiVersion = 1
      wait(20)
      compare(bridge.starts.length, 0, "changing release labels cannot make API 1 support the feature")
      mailService.backend.protocolInfo = { apiVersion: 2, protocol: 1, version: "0.0.0" }
      compare(lastStart().messageId, "message-70", "API 2 makes the pending feature available")
      mailService.backendRuntime.latestApiVersion = 3
      open(adas, "message-71", "Dinner again?", "Dinner on Friday at 7pm?")
      tryVerify(function() { return bridge.starts.length === 2 }, 1000)
      compare(lastStart().messageId, "message-71", "an unrelated API 3 does not disable API 2 features")
    }

    function test_the_card_draws_text_and_asks_the_reader() {
      var start = new Date(2026, 8, 12, 19, 0).getTime()
      card.suggestions = [
        { key: "j:0", jobId: "j", index: 0, title: "<b>Dinner</b> <img src=\"http://127.0.0.1:1/x\">",
          startMs: start, endMs: start + 3600000, location: "Luigi's", notes: "Bring <i>wine</i>" },
        { key: "j:1", jobId: "j", index: 1, title: "Offsite", startMs: start, endMs: start + 86400000, allDay: true, location: "", notes: "" }
      ]
      tryCompare(card, "visible", true)
      compare(named(card, "suggestionHeading", [])[0].text, "The agent found 2 events in this message")
      compare(named(card, "suggestionTitle", []).length, 0, "a guess is a line above the message, not a panel over it")
      compare(card.expanded, false)
      var foldedHeight = card.height
      mouseClick(named(card, "suggestionHeader", [])[0])
      tryCompare(card, "expanded", true)
      tryVerify(function() { return card.height > foldedHeight }, 1000, "and opens on a click")
      var titles = named(card, "suggestionTitle", [])
      compare(titles.length, 2)
      compare(titles[0].text, "<b>Dinner</b> <img src=\"http://127.0.0.1:1/x\">")
      compare(titles[0].textFormat, Text.PlainText, "the agent's words are text, never HTML")
      compare(named(card, "suggestionNotes", [])[0].textFormat, Text.PlainText)
      compare(named(card, "suggestionLocation", [])[0].textFormat, Text.PlainText)
      compare(named(card, "suggestionWhen", [])[1].text.indexOf("(all day)") > 0, true)
      var adds = named(card, "suggestionAdd", [])
      var dismisses = named(card, "suggestionDismiss", [])
      compare(adds.length, 2)
      mouseClick(adds[1])
      compare(added.count, 1)
      compare(added.signalArguments[0][0].title, "Offsite")
      mouseClick(dismisses[0])
      compare(dismissed.count, 1)
      compare(dismissed.signalArguments[0][0], "j:0")
      card.suggestions = [{ key: "j:1", jobId: "j", index: 1, title: "Offsite", startMs: start, endMs: start + 3600000, location: "", notes: "" }]
      compare(card.expanded, true, "one dismissed is still the same look")
      card.suggestions = [{ key: "k:0", jobId: "k", index: 0, title: "Other", startMs: start, endMs: start + 3600000, location: "", notes: "" }]
      compare(card.expanded, false, "a new look starts folded")
      card.suggestions = []
      tryCompare(card, "visible", false)
    }
  }
}

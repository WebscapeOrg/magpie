import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail
import "../../providers" as Providers
import "BackendFixture.js" as BackendFixture
import "NativeIntentFixture.js" as NativeIntentFixture

// Invariant: real App, Service and MailAccount objects preserve the move context
// across forwarding boundaries that isolated model tests cannot exercise.
Item {
  width: 900
  height: 600

  QtObject {
    id: fakeShell
    function hide(_id) {}
  }

  Omamail.Service {
    id: mailService
    shell: fakeShell
    manifest: ({ id: "omamail", __sourceDir: "" })
  }

  Omamail.App {
    id: app
    service: mailService
    shell: fakeShell
  }

  Component {
    id: refusingClient
    Providers.GmailApiClient {
      auth: null
      property var refusals: ({move:"Moving messages is unavailable for this account"})
    }
  }

  TestCase {
    name: "MoveWiring"
    when: windowShown
    property var backendFixture: null

    function initTestCase() {
      backendFixture = BackendFixture.markReady(mailService)
      NativeIntentFixture.install(mailService)
    }

    function named(item, objectName) {
      if (!item) return null
      if (item.objectName === objectName) return item
      var children = item.children || []
      for (var childIndex = 0; childIndex < children.length; childIndex++) {
        var found = named(children[childIndex], objectName)
        if (found) return found
      }
      return null
    }

    function installAccount(email) {
      mailService.accountsLoaded = true
      mailService.accountList = ({
        version: 1,
        accounts: [{ id: email, email: email, provider: "gmail", clientId: "" }],
        activeId: email
      })
      tryCompare(mailService, "accountCount", 1)
      tryVerify(function() { return mailService.current !== null }, 1000,
        "the real Service creates its MailAccount")
      wait(0)
      return mailService.current
    }

    function labelSlot(labelId) {
      var slots = app.sidebarSlots
      for (var slotIndex = 0; slotIndex < slots.length; slotIndex++) {
        if (slots[slotIndex].kind === "label" && slots[slotIndex].id === labelId) return slotIndex
      }
      return -1
    }

    function labelIds(labels) {
      var result = []
      for (var labelIndex = 0; labelIndex < labels.length; labelIndex++) result.push(labels[labelIndex].id)
      return result
    }

    function init() {
      app.opened = true
      app.cursorId = ""
      mailService.accountList = ({ version: 1, accounts: [], activeId: "" })
      wait(0)
    }

    function cleanup() {
      mailService.accountList = ({ version: 1, accounts: [], activeId: "" })
      wait(0)
    }

    function test_gmail_label_identity_reaches_the_picker_and_move_model() {
      var account = installAccount("me@example.com")
      account.mailboxKey = "starred"
      account.labels = [
        { id: "Label_3", name: "Bills", rawName: "Bills", system: false, unread: 0 },
        { id: "Label_7", name: "Receipts", rawName: "Receipts", system: false, unread: 0 }
      ]

      var slot = labelSlot("Label_3")
      verify(slot >= 0)
      app.goSlot(slot)

      tryCompare(account, "rawLabelId", "Label_3")
      compare(mailService.rawLabelId, "Label_3")
      compare(mailService.rawQuery, "label:Bills")
      compare(labelIds(named(app, "label-picker").matchingLabels), ["Label_7"],
        "the current label cannot trigger an optimistic removal that leaves it attached")

      account.auth.credentials = ({
        clientId: "123-test.apps.googleusercontent.com",
        clientSecret: "test",
        projectId: "test"
      })
      account.auth.toolsChecked = true
      account.auth.missingTools = []
      account.auth.loggedIn = true
      // Invariant: the optimistic action runs while provider transport stays pending.
      account.auth.refreshBusy = true
      tryCompare(account, "ready", true)
      account.messages = [
        { id: "one", labelIds: ["INBOX", "Label_3"], unread: false, starred: true,
          inInbox: true, subject: "One", time: "now", from: { display: "Sender" }, snippet: "First" },
        { id: "two", labelIds: ["INBOX", "Label_3"], unread: false, starred: true,
          inInbox: true, subject: "Two", time: "now", from: { display: "Sender" }, snippet: "Second" }
      ]
      app.cursorId = "one"
      app.openMessage("one")
      compare(app.currentView, "reader")
      compare(mailService.selectedId, "one")

      verify(app.actOnCursor("label:Label_7"))

      tryCompare(account, "actionPreparations", 0)
      tryCompare(mailService, "selectedId", "two", 5000,
        "the reader follows the action to the same next message as the cursor")
      compare(app.cursorId, "two",
        "App uses the raw query even though the old mailbox key is Starred")
      compare(account.messages.length, 1,
        "MailAccount uses the raw query to remove the row from the label view")
      compare(account.messages[0].id, "two")
    }

    function test_gmail_account_refusal_crosses_the_real_service_before_the_picker() {
      var account = installAccount("me@example.com")
      account.clientOverride = refusingClient
      tryCompare(account, "canMove", false)
      account.messages = [{id:"message-1",labelIds:["INBOX"],subject:"One"}]
      app.cursorId = "message-1"
      var before = JSON.stringify(account.messages)
      var requestCount = backendFixture.requests.length

      compare(app.openLabelPicker(), false)

      compare(named(app, "label-picker").opened, false)
      compare(mailService.actionStatus, "Moving messages is unavailable for this account")
      compare(JSON.stringify(account.messages), before)
      compare(account.actionPreparations, 0)
      compare(account.pendingAction, "")
      compare(backendFixture.requests.length, requestCount,
        "a refused picker must not prepare an optimistic action or send a request")
    }

    function test_current_gmail_label_is_not_its_own_move_destination() {
      var account = installAccount("me@example.com")
      account.labels = [
        { id: "Label_Archive", name: "Archive", rawName: "Archive", system: false, unread: 0 },
        { id: "Label_Receipts", name: "Receipts", rawName: "Receipts", system: false, unread: 0 }
      ]

      var slot = labelSlot("Label_Archive")
      verify(slot >= 0)
      app.goSlot(slot)

      tryCompare(account, "rawLabelId", "Label_Archive")
      compare(mailService.rawQuery, "label:Archive")
      compare(labelIds(named(app, "label-picker").matchingLabels), ["Label_Receipts"],
        "moving to the current Gmail label must not remove its message from the view")
    }
  }
}

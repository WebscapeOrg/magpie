import qs.Commons
import "../../settings"
import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail
import "NativeIntentFixture.js" as NativeIntentFixture
import "ModelFixture.js" as NativeModel
import "../../account/Accounts.js" as Accounts
import "../../account/Unified.js" as Unified

// Invariant: The batch's two boundaries, driven against a client the test controls.
//
// Ownership: the same message id can appear in multiple Gmail accounts,
// so ticks made in one mailbox must never be dispatched through
// another — however the switch reached the service. Reconciliation: one
// request per message answers per message, so a refusal on one row must
// put back that row and no other, and a whole-batch refusal must read the
// list again rather than restore rows the server may have changed.
Item {
  width: 900
  height: 600

  QtObject {
    id: shellStore
    function updateEntryInline(_id, _entry) {}
    function hide(_id) {}
  }

  QtObject {
    id: record
    property var trashed: []
    property var untrashed: []
    property var batches: []
    property int lists: 0
    property string refuse: ""
    property bool refuseBatch: false
    property bool hold: false
    property var pending: []
    function finish() {var callbacks=pending;pending=[];hold=false;for(var itemIndex=0;itemIndex<callbacks.length;itemIndex++)callbacks[itemIndex]()}
    function reset() { trashed = []; untrashed = []; batches = []; lists = 0; refuse = ""; refuseBatch = false; hold=false; pending=[] }
  }

  Component {
    id: controlledClient
    QtObject {
      property var auth: null
      property string email: ""
      function handle() { return ({ aborted: false }) }
      function later(callback) { if(record.hold)record.pending=record.pending.concat([callback]);else Qt.callLater(callback); return handle() }
      function trashMessage(id, callback) {
        var mine = record.trashed.slice(); mine.push(String(id)); record.trashed = mine
        var refused = String(id) === record.refuse
        return later(function() { callback(null, refused ? "the server refused this one" : "") })
      }
      function untrashMessage(id, callback) {
        var mine = record.untrashed.slice(); mine.push(String(id)); record.untrashed = mine
        var refused = String(id) === record.refuse
        return later(function() { callback(null, refused ? "the server refused this one" : "") })
      }
      function batchModify(ids, add, remove, callback) {
        var mine = record.batches.slice(); mine.push(ids.join(",")); record.batches = mine
        var refused = record.refuseBatch
        return later(function() { callback(null, refused ? "the batch was refused" : "") })
      }
      function modifyMessage(id, add, remove, callback) { return batchModify([id], add, remove, callback) }
      function listMessages() { record.lists = record.lists + 1; return handle() }
      function getMessages() { return handle() }
      function getMessage() { return handle() }
      function getLabels(callback) { return later(function() { callback([], "") }) }
      function getLabelCounts(id, callback) { return later(function() { callback({ id: id, unread: 0, total: 0, threadsUnread: 0 }, "") }) }
      function getProfile(callback) { return later(function() { callback({ email: email }, "") }) }
      function getSendAs(callback) { return later(function() { callback([], "") }) }
      function getAttachment() { return handle() }
      function saveDraft() { return handle() }
      function deleteDraft() { return handle() }
      function sendMessage() { return handle() }
      function createLabel() { return handle() }
      function renameLabel() { return handle() }
      function deleteLabel() { return handle() }
      function abortRequest(handle) { if (handle) handle.aborted = true }
    }
  }

  Omamail.Service {
    id: mailService
    shell: shellStore
    manifest: ({ id: "omamail", __sourceDir: "/tmp/omamail-test" })
  }

  Omamail.App { id: app; service: mailService }

  TestCase {
    name: "BatchActions"
    when: windowShown

    function initTestCase() { NativeModel.install(mailService); NativeIntentFixture.install(mailService) }

    readonly property string ada: "ada@example.com"
    readonly property string bob: "bob@example.com"

    function entry(email) {
      return {
        email: email, provider: "gmail",
        label: "", signature: ""
      }
    }

    function row(id) {
      return ({ id: id, threadId: "", from: { email: "x@example.com", display: "X" }, subject: id,
        snippet: "", time: "", date: "", unread: false, starred: false, inInbox: true, labelIds: ["INBOX"] })
    }

    function seed(entries, activeId) {
      var list = Accounts.emptyList()
      for (var itemIndex = 0; itemIndex < entries.length; itemIndex++) list = Accounts.add(list, entries[itemIndex])
      list = Accounts.setActive(list, activeId)
      mailService.activeIndex = -1
      mailService.accountList = list
      mailService.accountsLoaded = true
      wait(0)
      mailService.refreshCurrent()
      for (var accountIndex = 0; accountIndex < entries.length; accountIndex++) {
        var account = mailService.accountAt(accountIndex)
        verify(account !== null)
        account.clientOverride = controlledClient
        account.auth.toolsChecked = true
        account.auth.missingTools = []
        account.auth.credentials = {clientId: "123-example.apps.googleusercontent.com", clientSecret: "synthetic-secret"}
        account.auth.loggedIn = true
        tryCompare(account, "ready", true)
        account.listLoaded = true
      }
    }

    function init() {
      mailService.setDisplayPreference("layout", "Split view")
      record.reset()
      mailService.setUnifiedMailboxes(false)
      app.checkedIds = []
      app.checkedAccountId = ""
      app.resetNavigation()
    }

    function test_unified_trash_restores_failed_checks_and_reports_all_accounts() {
      seed([entry(ada), entry(bob)], ada)
      var first = mailService.accountAt(0)
      var second = mailService.accountAt(1)
      first.messages = [row("message-1"), row("message-2"), row("message-3")]
      second.messages = [row("message-1"), row("message-4")]
      mailService.setUnifiedMailboxes(true)
      var failed = Unified.unifiedId(first.accountId, "message-2")
      var ids = [Unified.unifiedId(first.accountId, "message-1"), failed,
        Unified.unifiedId(second.accountId, "message-1")]
      tryVerify(function() { return mailService.messages.length === 5 })
      app.checkedAccountId = mailService.activeAccountId
      app.checkedIds = ids
      app.cursorId = ids[0]
      record.refuse = "message-2"
      record.hold = true
      verify(app.actOnChecked("trash"))
      compare(app.checkedIds, [])
      tryVerify(function() { return record.trashed.length === 3 })
      compare(record.trashed.filter(function(id) { return id === "message-1" }).length, 2,
        "the identical local id reaches both owning accounts")
      record.finish()
      tryCompare(app, "checkedIds", [failed])
      tryVerify(function() { return mailService.lastError.indexOf("2 of 3 selected across 2 mailboxes") >= 0 })
      verify(mailService.lastError.indexOf(ada + ": 1 completed, 1 failed") >= 0)
      verify(mailService.lastError.indexOf(bob + ": 1 completed, 0 failed") >= 0)
      compare(first.messages.map(function(message) { return message.id }), ["message-2", "message-3"])
      compare(second.messages.map(function(message) { return message.id }), ["message-4"])
    }

    function test_batch_completion_reports_a_whole_batch_failure_once() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1"), row("message-2")]
      record.refuseBatch = true
      var answers = []
      verify(account.actMany(["message-1", "message-2"], "markRead", function(result) { answers.push(result) }))
      tryVerify(function() { return answers.length === 1 })
      compare(answers[0].failedIds, ["message-1", "message-2"])
      verify(answers[0].error !== "")
      compare(account.messages.length, 2)
    }

    function test_queued_batches_keep_every_completion_callback() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1"), row("message-2")]
      record.hold = true
      var answers = []
      verify(account.actMany(["message-1", "message-2"], "markRead", function(result) { answers.push(result) }))
      tryCompare(account, "pendingAction", "markRead")
      for (var itemIndex = 0; itemIndex < 2; itemIndex++)
        verify(account.actMany(["message-1", "message-2"], "markRead", function(result) { answers.push(result) }))
      tryVerify(function() { return account.queuedActions.length === 2 })
      record.finish()
      tryVerify(function() { return answers.length === 3 })
      for (var answerIndex = 0; answerIndex < answers.length; answerIndex++) compare(answers[answerIndex].failedIds, [])
      compare(record.batches.length, 3)
    }
    function test_sign_out_finishes_queued_batches_without_dispatching_them() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1"), row("message-2")]
      record.hold = true
      var answers = []
      verify(account.actMany(["message-1", "message-2"], "markRead", function(result) { answers.push(result) }))
      tryCompare(account, "pendingAction", "markRead")
      verify(account.actMany(["message-1", "message-2"], "markRead", function(result) { answers.push(result) }))
      tryVerify(function() { return account.queuedActions.length === 1 })
      compare(record.batches.length, 1)
      account.signOut()
      compare(answers.length, 2)
      compare(account.actionCompletions.length, 0)
      compare(account.queuedActions.length, 0)
      for (var itemIndex = 0; itemIndex < answers.length; itemIndex++) {
        compare(answers[itemIndex].failedIds, ["message-1", "message-2"])
        compare(answers[itemIndex].error, "Account signed out")
      }
      record.finish()
      wait(30)
      compare(answers.length, 2, "late replies cannot finish the same batch again")
      compare(record.batches.length, 1, "the queued mutation never reached the provider")
    }

    function having(item, accept) {
      if (accept(item)) return item
      var children = item.children || []
      for (var itemIndex = 0; itemIndex < children.length; itemIndex++) {
        var found = having(children[itemIndex], accept)
        if (found) return found
      }
      return null
    }

    function test_pane_widths_leave_room_for_the_reader_data() {
      return [
        { tag: "sidebar-first", sidebarFirst: true, collapsed: false },
        { tag: "list-first", sidebarFirst: false, collapsed: false },
        { tag: "collapsed-sidebar", sidebarFirst: true, collapsed: true }
      ]
    }

    function test_pane_widths_leave_room_for_the_reader(data) {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1")]
      account.selectedId = "message-1"
      account.selectedMessage = account.messages[0]
      app.open()
      app.pushEntry("reader", { id: account.selectedId })
      var window = having(app, function(item) { return item.title === "🐦 Magpie" })
      var reader = having(app, function(item) { return item.forceRichAnyway !== undefined })
      verify(window !== null && reader !== null)
      window.width = MailStyle.space(980)
      mailService.setSidebarCollapsed(data.collapsed)
      app.sidebarWidth = 0
      app.listWidth = 0
      if (data.sidebarFirst) {
        app.sidebarWidth = 360
        wait(0)
        app.listWidth = 4000
      } else {
        app.listWidth = 4000
        wait(0)
        app.sidebarWidth = 360
      }
      wait(0)
      verify(reader.width >= 200, "wide reader remains usable: " + reader.width)
      app.persistPaneWidths()
      app.close()
      app.open()
      app.pushEntry("reader", { id: account.selectedId })
      compare(app.listWidth, 4000, "clamping does not overwrite the saved preference")
      for (var itemIndex = 0; itemIndex < 4; itemIndex++) {
        window.width = [760, 759, 980, 1400][itemIndex]
        wait(0)
        verify(reader.width >= 200, "reader survives resize to " + window.width + ": " + reader.width)
      }
      app.close()
      window.width = MailStyle.space(980)
      mailService.setSidebarCollapsed(false)
      app.sidebarWidth = 0
      app.listWidth = 0
      app.persistPaneWidths()
    }

    function test_reader_mark_unread_uses_the_visible_selection_data() {
      return [
        { tag: "checked-open-message", checked: true, outside: false, compact: false, starred: false, expected: "message-1,message-2" },
        { tag: "checked-messages-already-starred", checked: true, outside: false, compact: false, starred: true, expected: "message-1,message-2" },
        { tag: "open-message-outside-selection", checked: true, outside: true, compact: false, starred: false, expected: "message-3" },
        { tag: "compact-reader-hides-selection", checked: true, outside: false, compact: true, starred: false, expected: "message-1" },
        { tag: "no-selection", checked: false, outside: false, compact: false, starred: false, expected: "message-1" }
      ]
    }

    function test_selection_toggles_and_shift_clears_a_range() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1"), row("message-2"), row("message-3")]
      app.open()
      app.cursorId = "message-1"
      app.runShortcut("toggleCheck", "Space")
      compare(app.checkedIds.join(","), "message-1")
      app.runShortcut("toggleCheck", "Space")
      compare(app.checkedIds.length, 0)
      app.checkRange("message-3")
      compare(app.checkedIds.join(","), "message-1,message-2,message-3")
      app.checkRange("message-1")
      compare(app.checkedIds.length, 0)
      app.close()
    }

    function test_ctrl_click_toggles_without_opening_data() {
      return [{ tag: "list", reading: false }, { tag: "reader", reading: true }]
    }

    function test_ctrl_temporarily_replaces_actions_with_checkboxes() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1")]
      app.open()
      app.cursorId = "message-1"
      var keyboard = having(app, function(item) { return item.ctrlDown !== undefined })
      verify(keyboard !== null)
      keyboard.parkKeyboard()
      wait(20)
      var target = having(app, function(item) {
        return item.summary && item.summary.id === "message-1"
          && item.checkToggled !== undefined
      })
      verify(target !== null)
      var check = findChild(target, "message-check")
      var unread = having(target, function(item) { return item.iconName === "unread" })
      verify(check !== null && unread !== null)
      compare(check.visible, false)
      compare(unread.visible, true)
      keyPress(Qt.Key_Control)
      tryCompare(check, "visible", true)
      compare(unread.visible, false)
      keyRelease(Qt.Key_Control)
      tryCompare(check, "visible", false)
      compare(unread.visible, true)
      mouseClick(target, 32, target.height / 2, Qt.LeftButton, Qt.ControlModifier)
      compare(check.visible, true, "selection mode survives releasing Ctrl")
      compare(unread.visible, false)
      compare(app.checkedIds.join(","), "message-1")
      // Invariant: Visibility changes synchronously, but Row lays out its replacement
      // controls on the next polish. Wait for the actual checkbox hit target,
      // otherwise this click can use the old three-button lane coordinates.
      tryCompare(check.parent, "width", check.width)
      tryCompare(check, "x", 0)
      mouseClick(check, check.width / 2, check.height / 2)
      compare(app.checkedIds.length, 0, "the checkbox click clears the selection")
      compare(check.visible, false, "clearing the last check restores actions")
      compare(unread.visible, true)
      app.close()
    }

    function test_ctrl_click_toggles_without_opening(data) {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1"), row("message-2")]
      app.open()
      if (data.reading) {
        account.selectedId = "message-1"
        app.pushEntry("reader", { id: account.selectedId })
      }
      app.toggleCheck("message-1")
      wait(0)
      var target = having(app, function(item) {
        return item.summary && item.summary.id === "message-2"
          && item.checkToggled !== undefined
      })
      verify(target !== null)
      var opened = account.selectedId
      var view = app.currentView
      mouseClick(target, 32, target.height / 2, Qt.LeftButton, Qt.ControlModifier)
      compare(app.checkedIds.join(","), "message-1,message-2")
      compare(account.selectedId, opened)
      compare(app.currentView, view)
      mouseClick(target, 32, target.height / 2, Qt.LeftButton, Qt.ControlModifier)
      compare(app.checkedIds.join(","), "message-1")
      compare(account.selectedId, opened)
      compare(app.currentView, view)
      app.close()
    }

    function test_reader_mark_unread_uses_the_visible_selection(data) {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      var messages = [row("message-1"), row("message-2"), row("message-3")]
      for (var itemIndex = 0; itemIndex < messages.length; itemIndex++) messages[itemIndex].starred = data.starred
      account.messages = messages
      account.selectedId = data.outside ? "message-3" : "message-1"
      account.selectedMessage = messages[data.outside ? 2 : 0]
      app.open()
      var window = having(app, function(item) { return item.title === "🐦 Magpie" })
      verify(window !== null)
      window.width = Style.space(data.compact ? 600 : 980)
      app.pushEntry("reader", { id: account.selectedId })
      if (data.checked) {
        verify(app.toggleCheck("message-1"))
        verify(app.toggleCheck("message-2"))
      }
      compare(app.selectionActive, data.checked && !data.compact)
      var cursorBefore = app.cursorId
      var reader = having(app, function(item) { return item.forceRichAnyway !== undefined })
      verify(reader !== null)
      var unread = having(reader, function(item) { return item.iconName === "unread" })
      verify(unread !== null)
      wait(0)
      mouseClick(unread, unread.width / 2, unread.height / 2)
      tryCompare(record, "batches", [data.expected])
      compare(app.cursorId, app.selectionActive && !data.outside ? cursorBefore : account.selectedId, "mark unread follows the visible reader unless acting on the selection")
      var acted = data.expected.split(",")
      for (var messageIndex = 0; messageIndex < messages.length; messageIndex++) {
        var changed = acted.indexOf(messages[messageIndex].id) >= 0
        compare(account.messages[messageIndex].unread, changed)
      }
      app.close()
      window.width = MailStyle.space(980)
    }

    // Invariant: Ada and Bob both hold message-42. Ticked in Ada's list, the id must not
    // become a trash request through Bob's client, whether the switch came
    // through the window or straight to the service.
    function test_ticks_do_not_cross_an_account_switch() {
      seed([entry(ada), entry(bob)], ada)
      mailService.accountAt(0).messages = [row("message-42"), row("message-43")]
      mailService.accountAt(1).messages = [row("message-42")]
      app.cursorId = "message-42"
      verify(app.toggleCheck("message-42"))
      compare(app.checkedIds.length, 1)

      verify(app.switchAccount(1))
      compare(mailService.activeAccountId, bob)
      compare(app.checkedIds.length, 0, "the switch dropped the ticks")
      compare(app.cursorId, "", "and the cursor, which is an id of Ada's too")
      app.runShortcut("trash", "d")
      wait(30)
      compare(record.trashed.length, 0, "nothing was trashed through Bob")

      verify(mailService.switchToIndex(0))
      app.cursorId = "message-42"
      verify(app.toggleCheck("message-42"))
      verify(mailService.switchToIndex(1))
      wait(30)
      compare(app.checkedIds.length, 0, "a switch at the service drops them too")
      app.checkedIds = ["message-42"]
      app.checkedAccountId = ada
      compare(app.actOnChecked("trash"), false, "ticks owned by another mailbox build no batch")
      compare(record.trashed.length, 0)
    }

    function test_a_partly_refused_trash_restores_only_the_refused_rows() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1"), row("message-2"), row("message-3")]
      record.refuse = "message-2"
      app.cursorId = "message-1"
      verify(app.toggleCheck("message-1"))
      verify(app.toggleCheck("message-2"))
      record.hold=true
      app.runShortcut("trash", "d")
      tryCompare(account, "pendingAction", "trash")
      compare(account.messages.length, 1, "both rows left optimistically")
      tryCompare(record, "trashed", ["message-1", "message-2"])
      record.finish()
      tryVerify(function() { return account.messages.length === 2 }, 1000)
      compare(account.messages.map(function(message) { return message.id }), ["message-2", "message-3"],
        "the refused row is back in its place; the accepted one is gone")
      verify(account.lastError.indexOf("1 of 2") >= 0, "the note counts the refusal: " + account.lastError)
    }

    // Invariant: The refused row is back, but the accepted one is gone, so the page
    // token the optimistic update cleared cannot simply come back: the page
    // is read again from the server, which is what makes older mail
    // reachable after a partial refusal.
    function test_a_partly_refused_trash_reads_the_page_again() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1"), row("message-2"), row("message-3")]
      account.nextPageToken = "older-page"
      record.refuse = "message-2"
      app.cursorId = "message-1"
      verify(app.toggleCheck("message-1"))
      verify(app.toggleCheck("message-2"))
      var listsBefore = record.lists
      record.hold=true
      app.runShortcut("trash", "d")
      tryCompare(account, "pendingAction", "trash")
      compare(account.hasMore, false, "the optimistic page has no token")
      tryCompare(record, "trashed", ["message-1", "message-2"])
      record.finish()
      tryVerify(function() { return account.messages.length === 2 }, 1000)
      tryVerify(function() { return record.lists > listsBefore }, 1000)
      compare(account.messages.map(function(message) { return message.id }), ["message-2", "message-3"],
        "the restored rows stay on screen while the server answers")
      verify(account.listLoading, "the page is being read again")
      verify(account.lastError.indexOf("1 of 2") >= 0, "the note is up while the page is read: " + account.lastError)
    }

    function test_a_refresh_waiting_on_a_partly_refused_batch_runs_after_it() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1"), row("message-2"), row("message-3")]
      record.refuse = "message-2"
      app.cursorId = "message-1"
      verify(app.toggleCheck("message-1"))
      verify(app.toggleCheck("message-2"))
      var listsBefore = record.lists
      record.hold=true
      app.runShortcut("trash", "d")
      tryCompare(account, "pendingAction", "trash")
      account.loadMessages(false, true, "")
      compare(record.lists, listsBefore, "the refresh waits on the action")
      verify(account.deferredListLoad !== null, "and is remembered")
      tryCompare(record, "trashed", ["message-1", "message-2"])
      record.finish()
      tryVerify(function() { return account.pendingAction === "" }, 1000)
      tryVerify(function() { return record.lists > listsBefore }, 1000)
      compare(account.deferredListLoad, null, "the waiting refresh ran")
      compare(account.messages.map(function(message) { return message.id }), ["message-2", "message-3"],
        "with the refused row back and the accepted one gone")
      verify(account.lastError.indexOf("1 of 2") >= 0, account.lastError)
    }

    function test_a_refresh_waiting_on_a_batch_runs_after_it() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1"), row("message-2")]
      app.cursorId = "message-1"
      verify(app.toggleCheck("message-1"))
      verify(app.toggleCheck("message-2"))
      var listsBefore = record.lists
      record.hold=true
      app.runShortcut("markRead", "I")
      tryCompare(account, "pendingAction", "markRead")
      account.loadMessages(false, true, "")
      compare(record.lists, listsBefore, "the refresh waits on the action")
      record.finish()
      tryVerify(function() { return account.pendingAction === "" }, 1000)
      tryVerify(function() { return record.lists > listsBefore }, 1000)
      compare(account.deferredListLoad, null, "the waiting refresh ran")
    }

    // Invariant: A whole-batch refusal from a client that answers with one word is not
    // proof that nothing changed: the list is read again from the server.
    function test_a_refused_batch_reads_the_list_again() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("message-1"), row("message-2")]
      record.refuseBatch = true
      app.cursorId = "message-1"
      verify(app.toggleCheck("message-1"))
      verify(app.toggleCheck("message-2"))
      var listsBefore = record.lists
      app.runShortcut("archive", "e")
      tryCompare(record, "batches", ["message-1,message-2"])
      tryVerify(function() { return record.lists > listsBefore }, 1000)
    }
  }
}

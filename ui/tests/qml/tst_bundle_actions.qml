import qs.Commons
import "../../settings"
import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail
import "NativeIntentFixture.js" as NativeIntentFixture
import "ModelFixture.js" as NativeModel
import "BackendFixture.js" as BackendFixture
import "../../account/Accounts.js" as Accounts
import "../../account/Unified.js" as Unified

// Invariant: Archive, Trash and the mark-read of opening a bundled row reach every mail in it through
// the real batch path, split by account, with an Undo that names how many (Q-020).
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
    property var batches: []
    property int ticket: 0
    property string refuse: ""
    function reset() { trashed = []; batches = []; ticket = 0; refuse = "" }
    function next() { ticket++; return {ticket: "ticket-" + ticket, queued: true} }
  }

  Component {
    id: controlledClient
    QtObject {
      property var auth: null
      property string email: ""
      function handle() { return ({ aborted: false }) }
      function later(callback) { Qt.callLater(callback); return handle() }
      function trashMessage(id, callback) {
        var mine = record.trashed.slice(); mine.push(String(id)); record.trashed = mine
        var refused = String(id) === record.refuse
        var payload = record.next()
        return later(function() { callback(refused ? null : payload, refused ? "the server refused this one" : "") })
      }
      function untrashMessage(id, callback) { return later(function() { callback(null, "") }) }
      function batchModify(ids, add, remove, callback) {
        var mine = record.batches.slice(); mine.push(ids.join(",")); record.batches = mine
        var payload = record.next()
        return later(function() { callback(payload, "") })
      }
      function modifyMessage(id, add, remove, callback) { return batchModify([id], add, remove, callback) }
      function listMessages() { return handle() }
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
    onRawMessagesChanged: {
      var prepared = Object.assign({},inboxTools.overviews)
      eachHost(function(host) { for (var i=0;i<host.messages.length;i++) prepared[host.accountId+"\n"+host.messages[i].id] = {state:"ready",version:2,text:"Prepared fixture",expiresAt:0} })
      inboxTools.overviews = prepared
    }
    shell: shellStore
    manifest: ({ id: "omamail", __sourceDir: "/tmp/omamail-test" })
  }

  Omamail.App { id: app; service: mailService }

  TestCase {
    name: "BundleActions"
    when: windowShown
    property var fixture: null

    readonly property string ada: "ada@example.com"
    readonly property string bob: "bob@example.com"
    readonly property var methods: ["inbox.bundles", "inbox.approveBundle", "inbox.refuseBundle", "inbox.snooze", "inbox.wake",
      "model.intent", "model.apply", "model.unified", "account.identities", "account.conversation", "providers.resolve",
      "local.cancelEdit", "local.edits", "local.summaries", "system.info"]

    function initTestCase() {
      NativeModel.install(mailService)
      NativeIntentFixture.install(mailService)
      fixture = BackendFixture.markReady(mailService, 8)
      mailService.backend.protocolInfo = {apiVersion: 8, protocol: 1, version: "0.0.0", methods: methods}
    }

    function entry(email) { return { email: email, provider: "gmail", label: "", signature: "" } }

    function row(id) {
      return ({ id: id, threadId: "t-" + id, from: { email: "x@example.com", display: "X" }, subject: id,
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
      mailService.inboxTools.bundles.dismissUndo()
      mailService.inboxTools.bundles.states = ({})
      mailService.inboxTools.bundles.answered = ({})
      mailService.inboxTools.bundles.fetched = ({})
    }

    function bundle(accountId, front, covered) {
      mailService.inboxTools.bundles.accept(accountId, {bundles:[{front:front,covered:covered}],proposals:[]}, null)
    }

    function offerText() { var offer = mailService.inboxTools.bundles.undoOffer; return offer ? offer.text : "" }

    function test_archive_on_a_bundled_row_reaches_every_mail_and_undo_names_the_count() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("front"), row("older"), row("oldest"), row("alone")]
      bundle(ada, "front", ["older", "oldest"])
      tryVerify(function() { return mailService.messages.length === 2 })
      compare(mailService.messages[0].bundleCount, 3)
      app.cursorId = "front"
      verify(app.actOnCursor("archive"))
      tryVerify(function() { return record.batches.length === 1 })
      compare(record.batches[0], "front,older,oldest")
      tryVerify(function() { return offerText() === "Archived 3 messages" }, 3000, "the toast names how many: " + offerText())
      compare(mailService.messages.map(function(message) { return message.id }), ["alone"],
        "the bundled mails leave together; none comes back as its own row")
      var cancelled = []
      fixture.answers["local.cancelEdit"] = function(params) { cancelled.push(params.ticket); return {cancelled:true} }
      verify(mailService.inboxTools.bundles.runUndo())
      tryVerify(function() { return mailService.inboxTools.bundles.undoOffer === null })
      compare(cancelled, ["ticket-1"], "Undo cancels the same edit the row made")
    }

    function test_undo_after_the_edit_synced_says_so_plainly() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("front"), row("older")]
      bundle(ada, "front", ["older"])
      tryVerify(function() { return mailService.messages.length === 1 })
      app.cursorId = "front"
      verify(app.actOnCursor("archive"))
      tryVerify(function() { return offerText() === "Archived 2 messages" })
      fixture.answers["local.cancelEdit"] = function(params, request) {
        BackendFixture.respond(mailService, request, null, {code: -32000, message: "local_edit_already_started"})
        return undefined
      }
      verify(mailService.inboxTools.bundles.runUndo())
      tryVerify(function() { return mailService.inboxTools.bundles.undoOffer !== null && mailService.inboxTools.bundles.undoOffer.canUndo === false })
      compare(offerText(), "Gmail already has this change, so Undo can't bring them back. Find them in All mail and choose Move to Inbox.")
      fixture.answers["local.cancelEdit"] = undefined
    }

    function test_undo_goes_to_the_account_the_action_started_in() {
      seed([entry(ada), entry(bob)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("front"), row("older")]
      bundle(ada, "front", ["older"])
      tryVerify(function() { return mailService.messages.length === 1 })
      app.cursorId = "front"
      verify(app.actOnCursor("archive"))
      mailService.accountList = Accounts.setActive(mailService.accountList, bob)
      mailService.refreshCurrent()
      compare(mailService.activeAccountId, bob)
      tryVerify(function() { return offerText() === "Archived 2 messages" })
      var accounts = []
      fixture.answers["local.cancelEdit"] = function(params) { accounts.push(params.accountId); return {cancelled:true} }
      verify(mailService.inboxTools.bundles.runUndo())
      tryVerify(function() { return mailService.inboxTools.bundles.undoOffer === null })
      compare(accounts, [ada], "the ticket belongs to the account that made it")
      fixture.answers["local.cancelEdit"] = undefined
    }

    function test_undo_that_breaks_does_not_say_gmail_has_it() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("front"), row("older")]
      bundle(ada, "front", ["older"])
      tryVerify(function() { return mailService.messages.length === 1 })
      app.cursorId = "front"
      verify(app.actOnCursor("archive"))
      tryVerify(function() { return offerText() === "Archived 2 messages" })
      fixture.answers["local.cancelEdit"] = function(params, request) {
        BackendFixture.respond(mailService, request, null, {code: -32000, message: "local_disk_full"})
        return undefined
      }
      verify(mailService.inboxTools.bundles.runUndo())
      tryVerify(function() { return mailService.inboxTools.bundles.undoOffer !== null && mailService.inboxTools.bundles.undoOffer.canUndo === false })
      compare(offerText(), "Undo could not finish. Find them in All mail and choose Move to Inbox.")
      fixture.answers["local.cancelEdit"] = undefined
    }

    function test_archiving_an_opened_conversation_keeps_the_whole_conversation() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      var opened = row("front"); opened.thread = {id: "t-front", memberIds: ["front", "earlier-reply"], count: 2, unread: false}
      account.messages = [opened, row("older"), row("alone")]
      bundle(ada, "front", ["older"])
      tryVerify(function() { return mailService.messages.length === 2 })
      app.cursorId = "front"
      verify(app.actOnCursor("archive"))
      tryVerify(function() { return record.batches.length === 1 })
      compare(record.batches[0].split(",").sort(), ["earlier-reply", "front", "older"])
    }

    function test_the_unified_view_says_it_once_in_the_toast() {
      seed([entry(ada), entry(bob)], ada)
      var first = mailService.accountAt(0)
      first.messages = [row("front"), row("older")]
      mailService.setUnifiedMailboxes(true)
      tryVerify(function() { return mailService.messages.length === 2 })
      bundle(ada, "front", ["older"])
      tryVerify(function() { return mailService.messages.length === 1 })
      first.actionStatus = ""
      if (mailService.current !== first) mailService.current.actionStatus = ""
      app.cursorId = Unified.unifiedId(first.accountId, "front")
      verify(app.actOnCursor("archive"))
      tryVerify(function() { return offerText() === "Archived 2 messages" })
      wait(0)
      compare(mailService.current.actionStatus, "", "no status line beside the toast")
    }

    function test_opening_marks_covered_mail_outside_the_loaded_page_read() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("front"), row("alone")]
      var unreadElsewhere = row("older-unloaded"); unreadElsewhere.unread = true
      fixture.answers["local.summaries"] = {summaries: [unreadElsewhere]}
      bundle(ada, "front", ["older-unloaded"])
      tryVerify(function() { return mailService.inboxTools.bundles.summaryOf(ada, "older-unloaded") !== undefined })
      tryVerify(function() { return mailService.messages[0].unread === true })
      mailService.select("front", false)
      tryVerify(function() { return record.batches.length === 1 })
      compare(record.batches[0], "older-unloaded")
      tryVerify(function() { return account.previewMessages.every(function(row) { return row.id !== "older-unloaded" }) }, 3000, "the helper row does not linger where the bar can see it")
      fixture.answers["local.summaries"] = undefined
    }

    function test_the_toast_counts_only_mail_that_could_be_reached() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("front"), row("older"), row("alone")]
      fixture.answers["local.summaries"] = {summaries: []}
      bundle(ada, "front", ["older", "not-yet-read"])
      tryVerify(function() { return mailService.messages.length === 2 })
      app.cursorId = "front"
      verify(app.actOnCursor("archive"))
      tryVerify(function() { return offerText() !== "" })
      compare(offerText(), "Archived 2 messages", "the mail Magpie could not read is not counted")
      fixture.answers["local.summaries"] = undefined
    }

    function test_stepping_in_the_reader_walks_the_bundle() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("front"), row("older")]
      bundle(ada, "front", ["older"])
      tryVerify(function() { return mailService.messages.length === 1 })
      mailService.select("front", false)
      tryCompare(mailService, "selectedId", "front")
      app.stepMember(1)
      tryCompare(mailService, "selectedId", "older")
      app.stepMember(-1)
      tryCompare(mailService, "selectedId", "front")
    }

    function test_report_spam_on_a_bundled_row_reports_only_the_newest_mail() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("front"), row("older")]
      bundle(ada, "front", ["older"])
      tryVerify(function() { return mailService.messages.length === 1 })
      verify(mailService.act("front", "spam"))
      tryVerify(function() { return record.batches.length === 1 })
      compare(record.batches[0], "front")
    }

    function test_trash_on_a_checked_selection_acts_on_every_mail_across_the_selection() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("front"), row("older"), row("alone"), row("spare")]
      bundle(ada, "front", ["older"])
      tryVerify(function() { return mailService.messages.length === 3 })
      app.checkedAccountId = mailService.activeAccountId
      app.checkedIds = ["front", "alone"]
      app.cursorId = "front"
      verify(app.actOnChecked("trash"))
      compare(app.checkedIds, [])
      tryVerify(function() { return record.trashed.length === 3 })
      compare(record.trashed.slice().sort(), ["alone", "front", "older"])
      tryVerify(function() { return offerText() === "Moved 3 messages to trash" })
    }

    function test_covered_mail_outside_the_loaded_page_is_still_acted_on() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      account.messages = [row("front"), row("alone")]
      fixture.answers["local.summaries"] = {summaries: [row("older-unloaded")]}
      bundle(ada, "front", ["older-unloaded"])
      tryVerify(function() { return mailService.inboxTools.bundles.summaryOf(ada, "older-unloaded") !== undefined })
      app.cursorId = "front"
      verify(app.actOnCursor("archive"))
      tryVerify(function() { return record.batches.length === 1 })
      compare(record.batches[0], "front,older-unloaded")
      fixture.answers["local.summaries"] = undefined
    }

    function test_a_failure_keeps_a_row_selected_data() {
      return [{tag:"front-fails-older-stays-with-it",refuse:"front",expected:"front"},
        {tag:"older-fails-front-gone-comes-back-as-its-own-row",refuse:"older",expected:"older"}]
    }
    function test_a_failure_keeps_a_row_selected(data) {
      seed([entry(ada), entry(bob)], ada)
      var first = mailService.accountAt(0), second = mailService.accountAt(1)
      first.messages = [row("front"), row("older")]
      second.messages = [row("other")]
      mailService.setUnifiedMailboxes(true)
      tryVerify(function() { return mailService.messages.length === 3 })
      bundle(ada, "front", ["older"])
      tryVerify(function() { return mailService.messages.length === 2 })
      var frontId = Unified.unifiedId(first.accountId, "front"), otherId = Unified.unifiedId(second.accountId, "other")
      app.checkedAccountId = mailService.activeAccountId
      app.checkedIds = [frontId, otherId]
      app.cursorId = frontId
      record.refuse = data.refuse
      verify(app.actOnChecked("trash"))
      tryVerify(function() { return record.trashed.length === 3 })
      tryCompare(app, "checkedIds", [Unified.unifiedId(first.accountId, data.expected)], 3000)
    }

    function test_opening_a_bundled_row_marks_every_mail_read() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      var unreadOlder = row("older"); unreadOlder.unread = true
      account.messages = [row("front"), unreadOlder]
      bundle(ada, "front", ["older"])
      tryVerify(function() { return mailService.messages.length === 1 })
      compare(mailService.messages[0].unread, true, "the row reads unread from the older mail")
      mailService.select("front", false)
      tryVerify(function() { return record.batches.length === 1 })
      compare(record.batches[0], "older", "opening marks the older mail read")
    }

    function test_preview_does_not_mark_the_bundle_read() {
      seed([entry(ada)], ada)
      var account = mailService.accountAt(0)
      var unreadOlder = row("older"); unreadOlder.unread = true
      account.messages = [row("front"), unreadOlder]
      bundle(ada, "front", ["older"])
      tryVerify(function() { return mailService.messages.length === 1 })
      mailService.select("front", true)
      wait(50)
      compare(record.batches.length, 0)
    }
  }
}

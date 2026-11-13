import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail
import "../../account/Unified.js" as Unified
import "ModelFixture.js" as NativeModel
import "BackendFixture.js" as BackendFixture
import "NativeIntentFixture.js" as NativeIntentFixture

// Invariant: The service routing a merged list, against a real `Service` with real
// account hosts.
//
// This is the gap the review named: `select`, `hostForId`, `sourceIdFor` on
// real messages, `chooseUnified`, the Gmail mailbox controls and the
// per-mailbox properties had no test at all, and every defect found landed in
// exactly those gaps.
//
// The hosts use either no credentials or controlled clients with synthetic
// credentials; no live mail is fetched or sent.
Item {
  id: fixtureRoot
  width: 1200
  height: 700

  QtObject {
    id: fakeShell
    property var written: []
    function updateEntryInline(id, entry) {
      var next = written.slice()
      next.push({ id: id, entry: entry })
      written = next
    }
    function hide(_id) {}
  }

  Omamail.Service {
    id: service
    shell: fakeShell
    manifest: ({ id: "omamail", __sourceDir: "/tmp/omamail-unified-test" })
  }

  Component {
    id: keyboardApp
    Omamail.App {}
  }

  QtObject {
    id: actionRecord
    property var writes: []
  }

  Component {
    id: controlledClient
    QtObject {
      property var auth: null
      property string email: ""
      property var refusals: ({})
      function handle() { return ({aborted:false}) }
      function later(callback) { Qt.callLater(callback); return handle() }
      function listMessages() { return handle() }
      function getMessages() { return handle() }
      function getMessage() { return handle() }
      function getLabels(callback) { return later(function() { callback([], "") }) }
      function getLabelCounts(id, callback) { return later(function() { callback({id:id, unread:0, total:0}, "") }) }
      function getProfile(callback) { return later(function() { callback({email:email}, "") }) }
      function getSendAs(callback) { return later(function() { callback([], "") }) }
      function batchModify(ids, add, remove, callback) {
        actionRecord.writes = actionRecord.writes.concat([{accountId:email, ids:ids}])
        return later(function() { callback(null, "") })
      }
      function modifyMessage(id, add, remove, callback) { return batchModify([id], add, remove, callback) }
      function abortRequest(request) { if (request) request.aborted = true }
    }
  }

  TestCase {
    name: "UnifiedRouting"
    when: windowShown

    readonly property string adaId: "ada@example.org"
    readonly property string bobId: "bob@example.net"
    property var backendFixture: null

    function initTestCase() {
      NativeModel.install(service)
      backendFixture = BackendFixture.install(service)
      NativeIntentFixture.install(service)
    }

    function seed() {
      service.applySettings({ unifiedMailboxes: true })
      service.applyAccounts(JSON.stringify({
        version: 1,
        activeId: adaId,
        accounts: [
          { id: adaId, email: adaId, provider: "gmail" },
          { id: bobId, email: bobId, provider: "gmail" }
        ]
      }))
      wait(50)
    }

    function ada() { return service.findAccount(adaId) }
    function bob() { return service.findAccount(bobId) }

    function makeReady(account) {
      account.clientOverride = controlledClient
      account.auth.toolsChecked = true
      account.auth.missingTools = []
      account.auth.credentials = ({clientId:"123-test.apps.googleusercontent.com", clientSecret:"synthetic"})
      account.auth.refreshBusy = true
      account.auth.loggedIn = true
      account.api.email = account.accountId
      tryCompare(account, "ready", true)
      account.listLoaded = true
      wait(0)
    }

    function row(id, date, subject) {
      return { id: id, subject: subject, unread: true, starred: false,
        inInbox: true, inTrash: false, isDraft: false, labelIds: ["INBOX"],
        from: { email: "sender@example.com", display: "Sender" },
        snippet: "", time: "now", fullTime: "today", date: date }
    }

    function init() {
      actionRecord.writes = []
      seed()
      ada().messages = [row("1", 3000, "ada newest"), row("2", 1000, "ada oldest")]
      bob().messages = [row("1", 2000, "bob middle")]
      service.bumpListEpoch()
      wait(20)
    }

    function cleanup() {
      for (var index = 0; index < service.accountCount; index++) {
        var account = service.accountAt(index)
        account.auth.loggedIn = false
        account.auth.credentials = null
        account.auth.refreshBusy = false
        account.clientOverride = null
      }
    }

    function test_two_mailboxes_become_one_list() {
      compare(service.unified, true)
      compare(service.messages.length, 3)
      compare(service.messages.map(function(message) { return message.subject }),
        ["ada newest", "bob middle", "ada oldest"])
    }

    // Invariant: Two mailboxes numbering their own messages from 1 is the collision the
    // composed id exists for.
    function test_each_row_is_addressed_by_its_own_mailbox() {
      var ids = service.messages.map(function(message) { return message.id })
      compare(ids[0], Unified.unifiedId(adaId, "1"))
      compare(ids[1], Unified.unifiedId(bobId, "1"))
      compare(ids[2], Unified.unifiedId(adaId, "2"))
      compare(ids[0] === ids[1], false, "three rows, three distinct ids")
    }

    function test_one_mailbox_is_not_merged() {
      service.applyAccounts(JSON.stringify({
        version: 1, activeId: adaId,
        accounts: [{ id: adaId, email: adaId, provider: "gmail" }]
      }))
      wait(50)
      compare(service.accountCount, 1)
      compare(service.unified, false,
        "a merged view of one mailbox is the mailbox")
    }

    function test_an_id_names_the_mailbox_that_owns_it() {
      compare(service.hostForId(Unified.unifiedId(adaId, "1")), ada())
      compare(service.hostForId(Unified.unifiedId(bobId, "1")), bob())
      compare(service.sourceIdFor(Unified.unifiedId(bobId, "42:Sent Items")),
        "42:Sent Items", "a folder with a space in it survives the trip")
    }

    // Invariant: An id for a mailbox that is not here reaches none rather than the wrong
    // one — which a bare id, read as composed, could have done.
    function test_an_id_for_a_mailbox_that_is_not_here_reaches_nothing() {
      compare(service.hostForId(Unified.unifiedId("gone@example.com", "1")), null)
      compare(service.hostForId("42:Sent Items"), null,
        "a bare message id is not a composed one")
      compare(service.act("42:Sent Items", "archive"), false)
    }

    // Invariant: Selecting routes to the owning mailbox, and clears the others: a second
    // mailbox still holding a selection goes on answering for the reader.
    function test_selecting_clears_every_other_mailbox() {
      service.select(Unified.unifiedId(bobId, "1"))
      compare(bob().selectedId, "1")
      compare(ada().selectedId, "", "whatever was open elsewhere is not what is shown")
      compare(service.selectedId, Unified.unifiedId(bobId, "1"),
        "and it comes back composed, because the panel compares it against the list")

      service.select(Unified.unifiedId(adaId, "2"))
      compare(ada().selectedId, "2")
      compare(bob().selectedId, "")
    }

    function test_image_preference_does_not_load_a_unified_preview() {
      service.setAlwaysShowImages(false)
      service.select(Unified.unifiedId(bobId, "1"), true)
      compare(bob().selectionIsPreview, true)
      bob().readerSourceKey = "native-key"
      service.setAlwaysShowImages(true)
      compare(bob().remoteImagesAllowed, false,
        "a preview must remain blocked when the standing preference changes")
      compare(bob().remoteImagesLoading, false)
    }

    function test_keyboard_navigation_opens_the_correct_account_without_changing_query() {
      failOnWarning(/Binding loop detected|Unable to assign.*QColor/)
      var app = createTemporaryObject(keyboardApp, fixtureRoot, {service: service, shell: fakeShell})
      verify(app)
      app.opened = true
      app.backToList()
      app.cursorId = ""
      var queryA = ada().effectiveQuery
      var queryB = bob().effectiveQuery
      var mailboxA = ada().mailboxKey
      var mailboxB = bob().mailboxKey
      app.moveCursor(1)
      compare(service.selectedId, Unified.unifiedId(adaId, "1"))
      compare(ada().selectedId, "1")
      compare(ada().selectionIsPreview, false)
      app.moveCursor(1)
      compare(app.cursorId, Unified.unifiedId(bobId, "1"))
      compare(service.selectedId, app.cursorId)
      compare(bob().selectedId, "1")
      compare(ada().selectedId, "")
      compare(bob().selectionIsPreview, false)
      compare(app.currentView, "reader")
      app.moveCursor(-1)
      compare(service.selectedId, Unified.unifiedId(adaId, "1"))
      compare(bob().selectedId, "")
      compare(ada().effectiveQuery, queryA)
      compare(bob().effectiveQuery, queryB)
      compare(ada().mailboxKey, mailboxA)
      compare(bob().mailboxKey, mailboxB)
    }

    function test_compose_belongs_to_the_mailbox_the_message_arrived_in() {
      service.select(Unified.unifiedId(bobId, "1"))
      compare(service.composeAccountId, bobId,
        "not the account that happens to be active")

      service.select(Unified.unifiedId(adaId, "1"))
      compare(service.composeAccountId, adaId)
    }

    function test_clearing_the_selection_clears_all_of_them() {
      service.select(Unified.unifiedId(bobId, "1"))
      service.clearSelection()
      compare(bob().selectedId, "")
      compare(ada().selectedId, "")
      compare(service.selectedId, "")
    }

    function test_the_rail_is_what_every_mailbox_has() {
      var keys = service.mailboxes.map(function(mailbox) { return mailbox.key })
      compare(keys.indexOf("inbox") >= 0, true)
      compare(keys.indexOf("spam") >= 0, true, "two Gmail mailboxes share Gmail's rail")
    }

    function test_a_label_cannot_be_shown_or_moved_to() {
      compare(service.labels.length, 0, "a label belongs to one mailbox")
      compare(service.rawLabelId, "")
      compare(service.canMoveToLabel, false,
        "so there is nothing for the picker to offer")
    }

    function test_the_unread_count_is_every_mailbox() {
      ada().inboxUnread = 3
      bob().inboxUnread = 4
      service.recount()
      wait(20)
      compare(service.inboxUnread, 7)
    }

    function test_a_rail_row_reaches_every_mailbox() {
      service.selectMailbox("sent")
      compare(service.mailboxKey, "sent")
      compare(ada().mailboxKey, "sent")
      compare(bob().mailboxKey, "sent")
    }

    // Invariant: Attachment IDs are account-local; a refusal must reach only the message's owner.
    function test_saving_an_attachment_asks_the_mailbox_that_owns_it() {
      ada().lastError = ""
      bob().lastError = ""
      compare(service.activeAccountId, adaId, "A is the active mailbox")

      service.saveAttachment(Unified.unifiedId(bobId, "1"),
        { attachmentId: "2", filename: "invoice.pdf" })

      verify(bob().lastError !== "", "B was asked, because the message is B's")
      compare(ada().lastError, "", "and A was not asked at all")
    }

    // Invariant: The spinner is keyed by mailbox and attachment, and the reader holds
    // only an attachment id — so composing the key is the service's job. It
    // was looked up bare, found nothing, and the row never went busy.
    function test_the_saving_row_is_the_owning_mailboxs_row() {
      bob().markSavingAttachment("2", true)

      compare(service.attachmentIsSaving(Unified.unifiedId(bobId, "1"), "2"), true)
      compare(service.attachmentIsSaving(Unified.unifiedId(adaId, "1"), "2"), false,
        "A is not saving anything, whatever B is doing")
      compare(service.attachmentIsSaving("", "2"), false)
      compare(service.attachmentIsSaving(Unified.unifiedId(bobId, "1"), ""), false)

      bob().markSavingAttachment("2", false)
      compare(service.attachmentIsSaving(Unified.unifiedId(bobId, "1"), "2"), false)
    }

    // Invariant: `active` is what earns a mailbox a list: `refresh` will not reload one
    // without it, and neither will the poll. Leaving it on the visible account
    // meant a merged list refreshed one mailbox's rows and left the others as
    // they were — the counts moved and the mail did not.
    function test_every_merged_mailbox_is_given_a_list() {
      compare(service.unified, true)
      compare(ada().active, true)
      compare(bob().active, true, "B is on screen too, so B gets a list")
      compare(bob().windowOpen, ada().windowOpen,
        "and the same answer about the window, which refresh also asks")
    }

    function test_leaving_the_merged_view_stands_the_others_down() {
      service.applySettings({ unifiedMailboxes: false })
      wait(30)
      compare(service.unified, false)
      compare(ada().active, true, "A is the mailbox on screen")
      compare(bob().active, false, "and B is no longer being drawn")
    }

    // Invariant: Two mailboxes can share a send-as alias, and the address alone then
    // names both. Whichever host answered first got the message.
    function test_a_draft_is_sent_from_the_mailbox_it_names() {
      compare(service.sendHostFor({ accountId: bobId, from: "shared@example.com" }),
        bob(), "the mailbox the composer named, not the one the address matched")

      ada().profile = { email: "shared@example.com" }
      bob().profile = { email: "shared@example.com" }
      compare(service.sendHostFor({ from: "shared@example.com" }), ada(),
        "with nothing named the first match is all there is to go on")
      compare(service.sendHostFor({ accountId: bobId, from: "shared@example.com" }),
        bob(), "and naming one is what settles it")
      ada().profile = null
      bob().profile = null

      compare(service.sendHostFor({}), service.current)
    }

    // Invariant: A draft raised from a merged list names its mailbox in its own id, so a
    // submission that carries only that still reaches the right one.
    function test_a_draft_id_alone_names_the_sending_mailbox() {
      compare(service.sendHostFor({ draftId: Unified.unifiedId(bobId, "d1") }), bob())
    }

    // Invariant: A named mailbox that is not here is a refusal rather than permission to
    // fall back to matching the address.
    function test_a_draft_naming_a_mailbox_that_is_gone_is_not_sent() {
      ada().lastError = ""
      bob().lastError = ""
      compare(service.sendHostFor({ accountId: "gone@example.com", from: adaId }), null,
        "A matches the address, and is still not asked")
      compare(service.send({ accountId: "gone@example.com",
        from: adaId, to: "her@example.com", subject: "x", body: "y" }), false)
      compare(ada().lastError, "", "nothing was sent from anywhere")
      compare(bob().lastError, "")
    }

    // Invariant: A draft opened from a merged list carries a composed id, and a provider
    // handed one answers that the draft is gone and writes nothing.
    function test_a_draft_is_saved_under_the_id_its_provider_issued() {
      compare(service.draftOwner({ draftId: Unified.unifiedId(bobId, "d1") }), bobId,
        "the owner is readable from the id alone")
      compare(service.withSourceDraftId(
        { draftId: Unified.unifiedId(bobId, "d1") }).draftId, "d1")

      compare(service.draftOwner({ accountId: adaId, draftId: Unified.unifiedId(bobId, "d1") }),
        adaId)
      compare(service.withSourceDraftId({ draftId: "d1" }).draftId, "d1")
    }

    // Invariant: Not gated on the merged view still being on: the composer can be opened
    // from one and saved after the reader has left it.
    function test_a_composed_draft_id_is_decoded_after_the_view_changes() {
      service.applySettings({ unifiedMailboxes: false })
      wait(30)
      compare(service.unified, false)
      compare(service.withSourceDraftId(
        { draftId: Unified.unifiedId(bobId, "d1") }).draftId, "d1")
      compare(service.draftOwner({ draftId: Unified.unifiedId(bobId, "d1") }), bobId)
    }

    function test_combined_gmail_controls_keep_account_scoped_labels() {
      compare(service.canArchive, true)
      compare(service.canReportSpam, true)
      compare(service.canStar, true)
      compare(service.canOpenOnWeb, true)
      compare(service.canMoveToLabel, false)
      compare(service.mailboxes.map(function(mailbox) { return mailbox.key }),
        ada().mailboxes.map(function(mailbox) { return mailbox.key }))
    }

    function test_single_action_respects_owning_account_refusal() {
      makeReady(ada())
      makeReady(bob())
      bob().api.refusals = ({archive:"Archive is unavailable for Bob"})
      compare(service.canArchive, true)
      compare(bob().canArchive, false)
      compare(service.act(Unified.unifiedId(bobId, "1"), "archive"), false)
      compare(actionRecord.writes.length, 0)
      compare(bob().messages.length, 1)
      compare(bob().actionStatus, "Archive is unavailable for Bob")

      compare(service.act(Unified.unifiedId(adaId, "1"), "archive"), true)
      tryCompare(actionRecord, "writes", [{accountId:adaId, ids:["1"]}])
      compare(bob().messages.length, 1)
    }

    function test_bulk_action_writes_only_to_accounts_that_allow_it() {
      makeReady(ada())
      makeReady(bob())
      bob().api.refusals = ({archive:"Archive is unavailable for Bob"})
      var refusedId = Unified.unifiedId(bobId, "1")
      var ids = [Unified.unifiedId(adaId, "1"), refusedId, Unified.unifiedId(adaId, "2")]
      var result = null
      compare(service.canArchive, true)
      compare(service.actMany(ids, "archive", function(value) { result = value }), true)
      tryVerify(function() { return result !== null })
      compare(result.failedIds, [refusedId])
      compare(actionRecord.writes, [{accountId:adaId, ids:["1", "2"]}])
      compare(bob().messages.length, 1)
      compare(bob().messages[0].id, "1")
    }

    function test_unready_selected_sender_never_uses_another_ready_account() {
      makeReady(ada())
      tryVerify(function() {
        return service.sendIdentities.length === 1 && service.sendIdentities[0].accountId === adaId
      })
      service.select(Unified.unifiedId(bobId, "1"))
      compare(service.composeAccountId, bobId)
      compare(bob().ready, false)
      compare(service.sendHostFor({accountId:bobId, from:bobId}), bob())
      var before = backendFixture.requests.length
      service.send({accountId:bobId, from:bobId, to:"recipient@example.org", subject:"Synthetic", body:"Test"})
      wait(20)
      var writes = backendFixture.requests.slice(before).filter(function(request) {
        return request.method === "message.compose" || request.method.indexOf("outbox.") === 0
          || request.method === "gmail.send" || request.method === "mail.send"
      })
      compare(writes.length, 0)
      compare(actionRecord.writes.length, 0)
      compare(ada().lastError, "")
      compare(bob().lastError, "The mailbox is not ready to send")
      compare(service.composeAccountId, bobId)
    }

    // Invariant: The rail steps from one member to the next and hands the id back to
    // `select` and `act`. A raw member id reached no mailbox, so a merged
    // conversation could be drawn and not walked.
    function test_a_conversation_member_is_addressed_like_every_other_row() {
      bob().selectedThread = { id: "t1", count: 2, unread: false, flagged: false,
        memberIds: ["1", "2"] }
      bob().memberSummaries = ({
        "1": { id: "1", unread: true, labelIds: ["UNREAD"] },
        "2": { id: "2", unread: false, labelIds: [] }
      })
      service.select(Unified.unifiedId(bobId, "1"))

      compare(service.selectedThread.memberIds,
        [Unified.unifiedId(bobId, "1"), Unified.unifiedId(bobId, "2")])
      compare(service.selectedThread.id, "t1",
        "the thread's own handle is not a message id and is left alone")

      var key = Unified.unifiedId(bobId, "2")
      verify(service.memberSummaries[key], "the summaries are keyed the same way")
      compare(service.memberSummaries[key].id, key,
        "and a stop carries that id onward to an open")

      compare(service.hostForId(service.selectedThread.memberIds[1]), bob())

      bob().selectedThread = null
      bob().memberSummaries = ({})
    }

    function test_gmail_threads_do_not_collapse_the_message_list() {
      compare(ada().showsConversations, false)
      compare(bob().showsConversations, false)
      ada().selectedId = "1"
      ada().selectedThread = { id: "shared-thread", count: 2, memberIds: ["1", "2"] }
      bob().selectedId = "1"
      bob().selectedThread = { id: "shared-thread", count: 2, memberIds: ["1", "2"] }
      try {
        service.selectionHost = ada()
        compare(service.selectedThread.memberIds[0], Unified.unifiedId(adaId, "1"))
        compare(service.conversationProjection.showsRail, false)
        service.selectionHost = bob()
        compare(service.selectedThread.memberIds[0], Unified.unifiedId(bobId, "1"))
        compare(service.conversationProjection.showsRail, false)
        compare(service.messages.length, 3)
      } finally {
        service.clearSelection()
      }
    }

    function test_a_search_reaches_every_mailbox() {
      service.search("invoice")
      tryCompare(ada(), "searchQuery", "invoice")
      tryCompare(bob(), "searchQuery", "invoice")
    }
  }
}

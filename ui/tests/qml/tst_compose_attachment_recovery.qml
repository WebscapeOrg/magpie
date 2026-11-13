import QtQuick
import QtTest
import "../../components" as Omamail

Item {
  id: host
  width: 900
  height: 600
  property string captureDirectory: ""

  QtObject {
    id: backend
    property bool ready: true
    property int apiVersion: 8
    property var pending: []
    property var calls: []
    function call(method, parameters, callback) {
      if (method === "message.composeText") {
        callback({body: "", quote: ""}, null)
        return
      }
      calls = calls.concat([{method: method, parameters: parameters}])
      if (method === "attachment.forget") {
        callback({ok: true}, null)
        return
      }
      pending = pending.concat([{callback: callback, parameters: parameters}])
    }
    function finish() {
      var request = pending[0]
      pending = pending.slice(1)
      request.callback({ok: true, filename: "notes.txt", mimeType: "text/plain",
        size: 4, data: "dGVzdA==", handle: "retained-file"}, null)
    }
  }

  QtObject {
    id: mail
    property var backend: backend
    property string composeAccountId: "writer@example.test"
    property string activeAccountId: composeAccountId
    property var recipientContacts: []
    property var sendAsAliases: []
    property var sendIdentities: []
    property var senderSources: []
    property var sent: []
    property var errors: []
    property string selectedId: "unrelated-selection"
    property var loads: []
    property int hostAttachmentRequests: 0
    property var pickerCallback: null
    function chooseFiles(callback) { hostAttachmentRequests++; pickerCallback = callback }
    function finishPicker(paths) { var callback = pickerCallback; pickerCallback = null; callback({ok:true, paths:paths}) }
    function clipboardAttachment(directory, callback) { hostAttachmentRequests++ }
    function loadAttachments(messageId, attachments, callback, draftKey, accountId) {
      loads = loads.concat([{messageId: messageId, attachments: attachments,
        callback: callback, draftKey: draftKey, accountId: accountId}])
    }
    function finishLoad(error) {
      var request = loads[0]
      loads = loads.slice(1)
      request.callback(error ? [] : [{filename: "original.txt", handle: "source-handle"}], error || "")
    }
    function signatureFor(account) { return "" }
    function preferredSendAs(recipients) { return {email: composeAccountId} }
    function refreshRecipientContacts() {}
    function findAccount(account) { return {providerId: "gmail"} }
    function fail(message) { errors = errors.concat([message]) }
    function send(fields) { sent = sent.concat([fields]); return "send-1" }
  }

  Omamail.ComposeView {
    id: compose
    anchors.fill: parent
    service: mail
    textColor: Qt.rgba(238/255, 238/255, 238/255, 1)
    backgroundColor: Qt.rgba(34/255, 34/255, 34/255, 1)
    accentColor: Qt.rgba(233/255, 163/255, 95/255, 1)
    dimColor: Qt.rgba(170/255, 170/255, 170/255, 1)
    dimmerColor: Qt.rgba(136/255, 136/255, 136/255, 1)
    popupBackgroundColor: Qt.rgba(51/255, 51/255, 51/255, 1)
    popupBorderColor: Qt.rgba(119/255, 119/255, 119/255, 1)
    panelFontFamily: "monospace"
  }

  TestCase {
    name: "ComposeAttachmentRecovery"
    when: windowShown
    function init() {
      backend.pending = []
      backend.calls = []
      compose.activeAttachJob = null
      compose.attachmentReadPending = false
      compose.attachmentHostPending = false
      compose.reset()
      mail.sent = []
      mail.errors = []
      mail.loads = []
      mail.hostAttachmentRequests = 0
      mail.pickerCallback = null
      backend.calls = []
      compose.begin("new", null, "", [])
    }
    function selectFile(path) {
      compose.queueSelectedAttachments(compose, [path], compose.draftKey, compose.accountId)
    }
    function parkAndOpenNewer() {
      compose.parkForSend("original-send")
      compose.begin("new", null, "", [])
      compose.restoreDraft({accountId: mail.composeAccountId, draftKey: "newer-draft",
        subject: "Keep this newer draft"})
    }
    function test_interrupted_import_and_queued_read_return_to_the_owning_draft() {
      parkAndOpenNewer()
      selectFile("/synthetic/first.txt")
      selectFile("/synthetic/second.txt")
      verify(compose.resumePendingSend("original-send", false))
      compare(compose.interruptedFields(), null, "Auto-save must wait for all newer draft attachments")
      backend.finish()
      compare(compose.draftAttachments.length, 0, "The older draft must not receive the newer file")
      compose.finish()
      compare(compose.draftKey, "newer-draft")
      compare(compose.draftAttachments.length, 1)
      compare(backend.pending.length, 1, "The second queued read resumes")
      compare(backend.calls[1].parameters.draftKey, "newer-draft")
      compose.submit()
      compare(mail.sent.length, 0, "The queued read still prevents sending")
      backend.finish()
      compose.submit()
      compare(mail.sent.length, 1)
      compare(mail.sent[0].attachments.length, 2)
    }
    function test_import_completion_after_restore_is_applied_once() {
      parkAndOpenNewer()
      selectFile("/synthetic/first.txt")
      verify(compose.resumePendingSend("original-send", false))
      compose.finish()
      compare(compose.attachmentsReady, false)
      backend.finish()
      compare(compose.draftAttachments.length, 1)
      compare(backend.calls.length, 1, "An active read is not started a second time")
      compare(compose.attachmentsReady, true)
    }
    function test_completed_import_is_kept_for_the_interrupted_draft() {
      parkAndOpenNewer()
      selectFile("/synthetic/first.txt")
      verify(compose.resumePendingSend("original-send", false))
      backend.finish()
      compare(compose.draftAttachments.length, 0)
      compose.finish()
      compare(compose.draftKey, "newer-draft")
      compare(compose.draftAttachments.length, 1, "The completed attachment must survive the interruption")
    }
    function test_completed_import_follows_a_draft_in_the_recovery_queue() {
      parkAndOpenNewer()
      selectFile("/synthetic/first.txt")
      compose.interruptedDraft = {draftKey: "already-interrupted", accountId: mail.composeAccountId,
        subject: "An earlier interruption"}
      verify(compose.resumePendingSend("original-send", false))
      compare(compose.recoveryDrafts.length, 1)
      backend.finish()
      compare(compose.draftAttachments.length, 0)
      compose.finish()
      compare(compose.draftKey, "already-interrupted")
      compose.finish()
      compare(compose.draftKey, "newer-draft")
      compare(compose.draftAttachments.length, 1)
    }
    function test_interrupted_clipboard_text_does_not_paste_into_the_active_draft() {
      parkAndOpenNewer()
      var owner = compose.draftKey
      verify(compose.resumePendingSend("original-send", false))
      compose.pasteInFlight = true
      var pastes = 0
      compose.finishAttach("clipboard", JSON.stringify({ok:false,error:"no-image"}), owner,
        {paste:function() { pastes++ }}, mail.composeAccountId)
      compare(pastes, 0)
      compare(compose.pasteInFlight, true, "The active draft still owns its separate paste")
      compare(compose.draftAttachments.length, 0)
    }
    function test_pending_only_draft_is_meaningful_and_requires_leave_confirmation() {
      selectFile("/synthetic/first.txt")
      verify(compose.hasMeaningfulDraft())
      verify(compose.hasUserChanges())
    }
    function test_persisted_paths_do_not_authorize_file_reads_data() {
      return [{tag:"pending-read", mode:"read", queued:false},
        {tag:"pending-recover", mode:"recover", queued:false},
        {tag:"pending-owned", mode:"recover-owned", queued:false},
        {tag:"queued-read", mode:"read", queued:true}]
    }
    function test_persisted_paths_do_not_authorize_file_reads(data) {
      var job = {mode:data.mode, path:"/synthetic/private-file.txt",
        owner:"restored-owner", accountId:mail.composeAccountId}
      var saved = {accountId:mail.composeAccountId, draftKey:"restored-owner", body:"Keep my text"}
      if (data.queued) saved.attachJobs = [job]
      else saved.pendingAttachment = job
      compose.restoreDraft(saved)
      compare(backend.calls.length, 0, "Stored metadata cannot authorize read or import")
      compare(mail.hostAttachmentRequests, 0)
      compare(compose.currentFields().body, "Keep my text")
      verify(compose.attachmentRecoveryError !== "")
      compose.submit()
      compare(mail.sent.length, 0)
      compare(compose.snapshotDraft().attachJobs[0].path, job.path, "Retain the selection intent without reading it")
    }
    function test_reselection_resolves_only_the_selected_missing_file() {
      var owner = "restored-owner"
      compose.restoreDraft({accountId:mail.composeAccountId, draftKey:owner, body:"Keep my text",
        attachJobs:[{mode:"read",path:"/synthetic/first.txt",owner:owner,accountId:mail.composeAccountId},
          {mode:"read",path:"/synthetic/second.txt",owner:owner,accountId:mail.composeAccountId}]})
      var choose = findChild(compose, "compose-recovery-choose-files")
      verify(choose && waitForRendering(choose))
      choose.forceActiveFocus()
      keyClick(Qt.Key_Space)
      compare(mail.hostAttachmentRequests, 1)
      mail.finishPicker(["/synthetic/first.txt"])
      compare(backend.calls.length, 1)
      compare(backend.calls[0].parameters.path, "/synthetic/first.txt")
      backend.finish()
      compare(compose.draftAttachments.length, 1)
      compare(compose.snapshotDraft().attachJobs.length, 1)
      verify(compose.attachmentRecoveryError.indexOf("second.txt") >= 0)
      compose.submit()
      compare(mail.sent.length, 0)
      var dismiss = findChild(compose, "compose-recovery-dismiss")
      verify(waitForRendering(dismiss))
      mouseClick(dismiss, dismiss.width/2, dismiss.height/2)
      compare(compose.snapshotDraft().attachJobs.length, 0)
      compare(compose.currentFields().body, "Keep my text")
      compare(mail.sent.length, 0)
      verify(compose.attachmentsReady)
    }
    function test_picker_completion_grants_only_the_interrupted_draft() {
      parkAndOpenNewer()
      compose.chooseFiles()
      verify(compose.resumePendingSend("original-send", false))
      mail.finishPicker(["/synthetic/newer-file.txt"])
      compare(backend.calls.length, 0)
      compose.finish()
      compare(backend.calls.length, 1)
      compare(backend.calls[0].parameters.draftKey, "newer-draft")
      backend.finish()
      compare(compose.draftAttachments.length, 1)
    }
    function test_read_grants_do_not_cross_draft_ownership() {
      selectFile("/synthetic/first.txt")
      backend.finish()
      compose.restoreDraft({accountId:mail.composeAccountId,draftKey:"another-owner",body:"Keep my text",
        pendingAttachment:{mode:"read",path:"/synthetic/first.txt",owner:"another-owner",accountId:mail.composeAccountId}})
      compare(backend.calls.length, 1, "The old draft selection does not authorize another draft read")
      verify(compose.attachmentRecoveryError !== "")
      compose.submit()
      compare(mail.sent.length, 0)
    }
    function test_recovery_error_is_bounded_without_losing_file_intent() {
      var jobs = []
      for (var index = 0; index < 1000; index++) jobs.push({mode:"read",path:"/synthetic/" + "a".repeat(100) + index,
        owner:"restored-owner",accountId:mail.composeAccountId})
      var files = []
      for (var fileIndex = 0; fileIndex < 1000; fileIndex++) files.push({path:"/synthetic/legacy"+fileIndex,owned:true})
      compose.restoreDraft({accountId:mail.composeAccountId,draftKey:"restored-owner",attachJobs:jobs,
        pendingAttachment:{mode:"read",path:"/synthetic/pending",owner:"restored-owner",accountId:mail.composeAccountId},
        draftAttachments:files})
      compare(backend.calls.length, 0)
      var saved = compose.snapshotDraft()
      compare(saved.attachJobs.length, 1000)
      compare(saved.pendingAttachment.path, "/synthetic/pending")
      compare(saved.draftAttachments.length, 1000)
      verify(compose.attachmentRecoveryError.length < 4096)
    }
    function test_mismatched_recovery_job_cannot_read_or_send() {
      compose.restoreDraft({accountId: mail.composeAccountId, draftKey: "restored-owner", body: "Keep my text",
        pendingAttachment: {mode: "read", path: "/synthetic/other-account.txt",
          owner: "restored-owner", accountId: "other@example.test"}})
      compare(backend.calls.length, 0, "The wrong mailbox must not read or import the path")
      compare(compose.currentFields().body, "Keep my text")
      verify(compose.attachmentRecoveryError !== "")
      compose.submit()
      compare(mail.sent.length, 0)
    }
    function test_host_selection_is_not_replayed_after_restart_data() {
      return [{tag: "picker", mode: "pick"}, {tag: "clipboard", mode: "clipboard"}]
    }
    function test_host_selection_is_not_replayed_after_restart(data) {
      compose.restoreDraft({accountId: mail.composeAccountId, draftKey: "restored-owner", body: "Keep my text",
        pendingAttachment: {mode: data.mode, path: "", owner: "restored-owner", accountId: mail.composeAccountId}})
      compare(mail.hostAttachmentRequests, 0, "Recovery must not silently reopen a chooser or reread the clipboard")
      compare(compose.currentFields().body, "Keep my text")
      verify(compose.attachmentRecoveryError !== "")
      compose.submit()
      compare(mail.sent.length, 0)
      var dismiss = findChild(compose, "compose-recovery-dismiss")
      verify(dismiss && waitForRendering(dismiss))
      mouseClick(dismiss, dismiss.width / 2, dismiss.height / 2)
      compare(compose.attachmentRecoveryError, "")
      compare(mail.sent.length, 0, "Acknowledging the missing file must not send")
      verify(compose.attachmentsReady)
    }
    function test_completed_provider_load_is_kept_for_the_interrupted_draft_data() {
      return [{tag: "forward", mode: "forward"}, {tag: "provider-draft", mode: "draft"}]
    }
    function test_completed_provider_load_is_kept_for_the_interrupted_draft(data) {
      compose.parkForSend("original-send")
      if (data.mode === "forward")
        compose.begin("forward", {id: "original-message", subject: "Source", threadId: "thread", messageId: "<source@example.test>"}, "", [{attachmentId: "part-1"}])
      else compose.beginDraft({mode: "draft", subject: "Source"}, "original-message", [{attachmentId: "part-1"}])
      var owner = compose.draftKey
      verify(compose.resumePendingSend("original-send", false))
      mail.finishLoad("")
      compare(compose.allOutgoingAttachments().length, 0)
      compose.finish()
      compare(compose.draftKey, owner)
      compare(compose.allOutgoingAttachments().length, 1, "The source attachment must survive the interruption")
    }
    function test_interrupted_forward_and_provider_draft_load_data() {
      return [{tag: "forward", mode: "forward"}, {tag: "provider-draft", mode: "draft"}]
    }
    function test_interrupted_forward_and_provider_draft_load(data) {
      compose.parkForSend("original-send")
      if (data.mode === "forward")
        compose.begin("forward", {id: "original-message", subject: "Source", threadId: "thread", messageId: "<source@example.test>"}, "", [{attachmentId: "part-1"}])
      else compose.beginDraft({mode: "draft", subject: "Source"}, "original-message", [{attachmentId: "part-1"}])
      var owner = compose.draftKey
      compare(mail.loads.length, 1)
      compare(mail.loads[0].messageId, "original-message")
      compare(mail.loads[0].accountId, mail.composeAccountId)
      verify(compose.resumePendingSend("original-send", false))
      compare(compose.interruptedFields(), null)
      mail.finishLoad("")
      compare(compose.allOutgoingAttachments().length, 0)
      compose.finish()
      compare(compose.draftKey, owner)
      compare(compose.allOutgoingAttachments().length, 1)
      compare(compose.attachmentsReady, true)
    }
    function test_forward_retry_uses_its_original_source_after_selection_changes() {
      compose.begin("forward", {id: "original-message", subject: "Source", threadId: "thread", messageId: "<source@example.test>"}, "", [{attachmentId: "part-1"}])
      mail.finishLoad("Temporary attachment failure")
      mail.selectedId = "different-message"
      compose.loadForwardAttachments()
      compare(mail.loads[0].messageId, "original-message")
      compare(mail.loads[0].accountId, mail.composeAccountId)
      mail.finishLoad("")
      compare(compose.forwardedAttachments.length, 1)
    }
    function test_provider_draft_load_keeps_manually_added_files() {
      compose.beginDraft({mode: "draft", subject: "Source"}, "original-message", [{attachmentId: "part-1"}])
      selectFile("/synthetic/manual.txt")
      backend.finish()
      mail.finishLoad("")
      compare(compose.draftAttachments.length, 2)
      compare(compose.draftAttachments[0].filename, "notes.txt")
      compare(compose.draftAttachments[1].filename, "original.txt")
    }
    function test_restored_provider_load_keeps_its_source_and_blocks_send() {
      compose.restoreDraft({accountId: mail.composeAccountId, draftKey: "restored-owner", mode: "draft",
        sourceDraftId: "original-message", attachmentSourceMessageId: "original-message",
        originalAttachments: [{attachmentId: "part-1"}], forwardAttachmentsLoading: true, forwardLoadSerial: 7})
      compare(mail.loads.length, 1)
      compare(mail.loads[0].messageId, "original-message")
      compare(mail.loads[0].accountId, mail.composeAccountId)
      compose.submit()
      compare(mail.sent.length, 0)
      mail.finishLoad("")
      verify(compose.attachmentsReady)
    }
    function test_discarded_provider_load_cannot_enter_a_new_draft() {
      compose.beginDraft({mode: "draft", subject: "Source"}, "original-message", [{attachmentId: "part-1"}])
      compose.finish()
      compose.begin("new", null, "", [])
      mail.finishLoad("")
      compare(compose.draftAttachments.length, 0)
      compare(compose.forwardedAttachments.length, 0)
    }
    function test_legacy_paths_do_not_authorize_file_reads_data() {
      return [{tag:"borrowed", owned:false}, {tag:"owned", owned:true}]
    }
    function test_legacy_paths_do_not_authorize_file_reads(data) {
      compose.restoreDraft({accountId:mail.composeAccountId, draftKey:"recovered-draft", body:"Keep my text",
        draftAttachments:[{path:"/synthetic/private-file.txt", owned:data.owned}]})
      compare(backend.calls.length, 0, "An owned flag in stored metadata is not file-read authority")
      compare(mail.hostAttachmentRequests, 0)
      compare(compose.currentFields().body, "Keep my text")
      verify(compose.attachmentRecoveryError !== "")
      compose.submit()
      compare(mail.sent.length, 0)
      compare(compose.snapshotDraft().draftAttachments[0].path, "/synthetic/private-file.txt")
    }
    function test_retained_attachment_handles_do_not_reread_the_original_file() {
      compose.restoreDraft({accountId: mail.composeAccountId, draftKey: "recovered-draft",
        draftAttachments: [{path: "/removed/original.txt", handle: "retained-file", owned: false}]})
      compare(backend.calls.length, 0)
      compare(compose.draftAttachments.length, 1)
      compare(compose.draftAttachments[0].handle, "retained-file")
      compare(mail.errors.length, 0)
    }
    function test_submit_waits_for_attachment_import() {
      selectFile("/synthetic/notes.txt")
      compare(backend.pending.length, 1)
      compose.submit()
      compare(mail.sent.length, 0, "Send must not dispatch while the attachment is absent")
      verify(compose.opened)
      backend.finish()
      compose.submit()
      compare(mail.sent.length, 1)
      compare(mail.sent[0].attachments.length, 1)
    }
    function test_send_click_waits_for_import() {
      selectFile("/synthetic/notes.txt")
      var button = findChild(compose, "compose-send-button")
      verify(button)
      mouseClick(button, button.width / 2, button.height / 2)
      compare(mail.sent.length, 0)
      backend.finish()
      mouseClick(button, button.width / 2, button.height / 2)
      compare(mail.sent.length, 1)
      compare(mail.sent[0].attachments.length, 1)
    }
    function test_submit_waits_for_host_picker() {
      compose.attachmentHostPending = true
      compose.submit()
      compare(mail.sent.length, 0)
    }
    function test_submit_waits_for_queued_attachment() {
      compose.attachJobs = [{mode: "read", path: "/synthetic/notes.txt"}]
      compose.submit()
      compare(mail.sent.length, 0)
    }
    function test_preview_uses_imported_bytes_instead_of_reopening_the_path() {
      var bytes = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
      compose.draftAttachments = [{filename: "picture.png", mimeType: "image/png",
        data: bytes, path: "/synthetic/no-longer-present.png"}]
      var preview = findChild(compose, "compose-attachment-preview-0")
      verify(preview)
      compare(String(preview.source), "data:image/png;base64," + bytes)
      tryCompare(preview, "status", Image.Ready)
    }
    function test_untrusted_preview_bytes_never_reach_the_decoder_data() {
      return [
        {tag: "svg-disguised-as-png", mimeType: "image/png",
          data: "PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnPjwvc3ZnPg=="},
        {tag: "svg", mimeType: "image/svg+xml",
          data: "PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnPjwvc3ZnPg=="},
        {tag: "path-without-validated-bytes", mimeType: "image/png", data: ""}
      ]
    }
    function test_untrusted_preview_bytes_never_reach_the_decoder(data) {
      compose.draftAttachments = [{filename: "picture.png", mimeType: data.mimeType,
        data: data.data, path: "/synthetic/untrusted-preview.svg"}]
      var preview = findChild(compose, "compose-attachment-preview-0")
      verify(preview)
      compare(String(preview.source), "", "Qt must receive neither unvalidated data nor a local path")
      compare(preview.status, Image.Null)
      verify(!preview.visible)
      compare(compose.draftAttachments.length, 1, "The attachment remains available to send")
    }
    function test_preview_metadata_shares_a_bounded_draft_budget() {
      // Invariant: synthetic PNG metadata exercises admission without allocating the declared pixels.
      var large = {mimeType: "image/png",
        data: "iVBORw0KGgoAAAANSUhEUgAAEAAAAAYACAIAAAB5zxq0AAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"}
      var oversized = {mimeType: "image/png",
        data: "iVBORw0KGgoAAAANSUhEUgABhqAAAYagCAIAAAAnMJyfAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"}
      var previews = compose.previewsFor([oversized, large, large, large])
      compare(previews[0], "")
      verify(previews[1] !== "")
      verify(previews[2] !== "")
      compare(previews[3], "", "Three 48 MiB images must not exceed the 128 MiB draft budget")
    }
    function test_capture_recovery_states() {
      if (host.captureDirectory === "") skip("Capture directory was not requested")
      parkAndOpenNewer()
      selectFile("/synthetic/first.txt")
      compose.resumePendingSend("original-send", false)
      backend.finish()
      compose.finish()
      wait(150)
      grabImage(host).save(host.captureDirectory + "/recovered-file.png")

      init()
      compose.parkForSend("original-send")
      compose.beginDraft({mode:"draft",subject:"Provider draft",body:"Please keep the original attachment."},
        "original-message", [{attachmentId:"part-1",filename:"original.txt",size:4096}])
      mail.finishLoad("Could not include original.txt")
      compose.resumePendingSend("original-send", false)
      compose.finish()
      wait(150)
      grabImage(host).save(host.captureDirectory + "/provider-error.png")

      init()
      compose.restoreDraft({accountId:mail.composeAccountId,draftKey:"restored-owner",
        subject:"Recovered draft",body:"Please keep this authored text.",
        pendingAttachment:{mode:"pick",path:"",owner:"restored-owner",accountId:mail.composeAccountId}})
      wait(150)
      grabImage(host).save(host.captureDirectory + "/interrupted-picker.png")

      init()
      compose.restoreDraft({accountId:mail.composeAccountId,draftKey:"restored-owner",
        subject:"Recovered file selection",body:"Please keep this authored text.",
        draftAttachments:[{filename:"notes.txt",path:"/synthetic/notes.txt",owned:false}]})
      wait(150)
      grabImage(host).save(host.captureDirectory + "/reselect-files.png")
    }
  }
}

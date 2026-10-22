import QtQuick
import QtTest
import "../../components" as Omamail

Item {
  width: 900
  height: 600

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
        size: 4, data: "dGVzdA==", path: request.parameters.path, handle: "retained-file"}, null)
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
      compose.attachmentReadPending = false
      compose.attachmentHostPending = false
      compose.reset()
      mail.sent = []
      mail.errors = []
      backend.calls = []
      compose.begin("new", null, "", [])
    }
    function test_restored_files_are_imported_for_the_owning_draft_data() {
      return [{tag: "borrowed", owned: false}, {tag: "owned", owned: true}]
    }
    function test_restored_files_are_imported_for_the_owning_draft(data) {
      compose.restoreDraft({accountId: mail.composeAccountId, draftKey: "recovered-draft",
        draftAttachments: [{path: "/synthetic/notes.txt", owned: data.owned}]})
      compare(backend.calls.length, 1)
      compare(backend.calls[0].method, "attachment.import")
      compare(backend.calls[0].parameters.accountId, mail.composeAccountId)
      compare(backend.calls[0].parameters.draftKey, "recovered-draft")
      backend.finish()
      compare(compose.draftAttachments.length, 1)
      compare(compose.draftAttachments[0].owned, data.owned)
      compare(mail.errors.length, 0)
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
      compose.enqueueAttach("read", "/synthetic/notes.txt")
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
      compose.enqueueAttach("read", "/synthetic/notes.txt")
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
      // Test coverage: metadata-only PNG headers exercise admission without allocating their pixels.
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
  }
}

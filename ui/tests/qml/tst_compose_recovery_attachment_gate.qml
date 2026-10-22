import QtQuick
import QtTest
import "../../compose" as Compose

Item {
  QtObject {
    id: backend
    property bool ready: true
    property int apiVersion: 7
    property var calls: []
    function call(method, parameters, callback) {
      calls = calls.concat([{method:method, parameters:parameters}])
    }
  }
  QtObject { id: service; property var backend: backend }
  QtObject {
    id: composer
    property bool opened: true
    property bool parkedForSend: false
    property var pendingDraft: null
    property var interruptedDraft: null
    property var parkedDrafts: []
    property var recoveryDrafts: []
    property var draft: ({})
    function snapshotDraft() { return draft }
  }
  Timer { id: recoveryTimer }
  QtObject {
    id: app
    property var service: service
    property var composeRecovery: ({})
    property bool composeRecoveryLoaded: true
    property bool composeRecoveryRestoring: false
    property int composeRecoveryRevision: 0
    property int composeCommittedRevision: 0
    property string lastComposeRecoveryText: ""
    property string composeWritePayload: ""
    property bool composeWriteQueued: false
    property bool composeWriting: false
    property bool composeReading: false
    property bool composeRecoveryConflict: false
    property string composeStorageRevision: "stored-revision"
    property string composeRecoveryNotice: ""
    property bool composeRecoveryUpdateNoticePending: false
    function readComposeRecovery() {}
    function drainComposeRecovery() { controller.drainComposeRecovery() }
    function writeComposeRecovery(raw) { controller.writeComposeRecovery(raw) }
    function parkedBesides(draft) { return controller.parkedBesides(draft) }
    function composeReturnView() { return "list" }
    function clearComposeRecovery() { controller.clearComposeRecovery() }
  }
  Compose.RecoveryController {
    id: controller
    app: app
    composer: composer
    recoveryTimer: recoveryTimer
  }
  TestCase {
    name: "ComposeRecoveryAttachmentGate"
    function init() {
      app.composeWriteQueued = false
      app.composeWriting = false
      app.composeRecoveryRevision = 0
      app.composeCommittedRevision = 0
      app.composeWritePayload = ""
      app.lastComposeRecoveryText = ""
      app.composeRecoveryNotice = ""
      app.composeRecoveryUpdateNoticePending = false
      composer.parkedDrafts = []
      composer.recoveryDrafts = []
      composer.interruptedDraft = null
      composer.draft = {accountId:"writer@example.test",draftKey:"draft-owner",body:"Keep the authored text"}
      backend.apiVersion = 7
      backend.calls = []
    }
    function test_old_api_does_not_receive_attachment_recovery_data() {
      return [
        {tag:"pending-read",fields:{pendingAttachment:{mode:"read",path:"/synthetic/file.txt",owner:"draft-owner",accountId:"writer@example.test"}}},
        {tag:"queued-read",fields:{attachJobs:[{mode:"read",path:"/synthetic/file.txt",owner:"draft-owner",accountId:"writer@example.test"}]}},
        {tag:"provider-load",fields:{attachmentSourceMessageId:"message-1",forwardAttachmentsLoading:true}},
        {tag:"source-only",fields:{attachmentSourceMessageId:"message-1"}},
        {tag:"provider-error",fields:{forwardAttachmentError:"Attachment unavailable"}},
        {tag:"host-interruption",fields:{attachmentRecoveryError:"Choose files again"}}
      ]
    }
    function test_old_api_does_not_receive_attachment_recovery(data) {
      composer.draft = Object.assign({}, composer.draft, data.fields)
      controller.saveComposeRecovery()
      compare(backend.calls.length, 0, "An older backend must not normalize away pending work")
      verify(app.composeWriteQueued)
      compare(app.composeCommittedRevision, 0)
      compare(app.composeRecovery.draft.body, "Keep the authored text")
      verify(app.composeRecoveryNotice.indexOf("updated backend") >= 0)
      verify(app.composeRecoveryNotice.indexOf("Keep this window open") >= 0)
      backend.apiVersion = 8
      tryVerify(function() { return backend.calls.length === 1 })
      compare(backend.calls[0].method, "compose.recoverySave")
      compare(backend.calls[0].parameters.record.draft, composer.draft)
    }
    function test_ordinary_recovery_still_uses_the_older_supported_api() {
      controller.saveComposeRecovery()
      compare(backend.calls.length, 1)
      compare(backend.calls[0].method, "compose.recoverySave")
      compare(backend.calls[0].parameters.record.draft.body, "Keep the authored text")
    }
    function test_interrupted_attachment_work_is_retained_and_gated() {
      composer.interruptedDraft = {accountId:"writer@example.test",draftKey:"interrupted-owner",body:"Newer text",
        pendingAttachment:{mode:"read",path:"/synthetic/file.txt",owner:"interrupted-owner",accountId:"writer@example.test"}}
      controller.saveComposeRecovery()
      compare(app.composeRecovery.parked.length, 1)
      compare(app.composeRecovery.parked[0], composer.interruptedDraft)
      compare(backend.calls.length, 0)
    }
  }
}

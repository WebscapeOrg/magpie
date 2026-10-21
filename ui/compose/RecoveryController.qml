import QtQuick
import "Recovery.js" as Recovery
import "../account/Navigation.js" as Nav

// Invariant: reconcile durable delivery receipts before restoring drafts; transport failures cannot authorize resending.
QtObject {
  id: controller
  required property var app
  required property var composer
  required property var recoveryTimer
  readonly property var composeRecoveryTimer: recoveryTimer
  // Invariant: retry the held revision only after a proven unsent refusal; an interrupted write requires rereading storage.
  readonly property var unsentRefusals: [-32000, -32011]

  readonly property int maxRecoveryRetries: 6
  property int recoveryRetries: 0
  readonly property Timer recoveryRetryTimer: Timer {
    interval: 1000
    repeat: false
    onTriggered: controller.drainComposeRecovery()
  }
  readonly property var root: app
  readonly property var compose: composer
  readonly property var service: app ? app.service : null
  // Invariant: explicit empty-draft edit history requires the fixed API 3 feature gate.
  readonly property bool recoverySupported: !!service && !!service.backend
    && service.backend.ready && service.backend.apiVersion >= 3
  readonly property bool recoveryNeedsUpdate: !!service && !!service.backend
    && service.backend.ready && !recoverySupported
  readonly property string recoveryUpdateNotice: "Draft recovery needs an updated backend. Keep this window open."
  // Invariant: restore an obscured notice only while the save-failure notice still owns the composer status.
  property bool recoverySaveFailurePending: false
  property string noticeBehindSaveFailure: ""
  property bool saveFailureHidUpdateNotice: false
  onRecoverySupportedChanged: { if (recoverySupported) root.readComposeRecovery() }
  onRecoveryNeedsUpdateChanged: {
    if (recoveryNeedsUpdate && root.composeWriteQueued) showRecoveryNotice(recoveryUpdateNotice, true)
  }
  function showRecoveryNotice(message, needsUpdate) {
    controller.forgetNoticeBehindSaveFailure()
    root.composeRecoveryUpdateNoticePending = needsUpdate === true
    root.composeRecoveryNotice = message
  }
  function showSaveFailureNotice() {
    var owned = controller.recoverySaveFailurePending
    var behind = owned ? controller.noticeBehindSaveFailure : root.composeRecoveryNotice
    var hidUpdate = owned ? controller.saveFailureHidUpdateNotice : root.composeRecoveryUpdateNoticePending
    showRecoveryNotice("Draft recovery could not be saved. Keep this window open.")
    controller.recoverySaveFailurePending = true
    controller.noticeBehindSaveFailure = behind
    controller.saveFailureHidUpdateNotice = hidUpdate
  }
  function forgetNoticeBehindSaveFailure() {
    controller.recoverySaveFailurePending = false
    controller.noticeBehindSaveFailure = ""
    controller.saveFailureHidUpdateNotice = false
  }
  function reconcileComposeReceipts() {
    if (root.composeReceiptChecking) return
    var record = root.composeRecovery
    var drafts = record && record.active && record.draft ? [record.draft].concat(record.parked || []) : []
    var pending = drafts.filter(function(draft) { return String(draft.pendingSendId || "") !== "" })
    if (pending.length === 0) { Qt.callLater(root.restoreComposeRecovery); return }
    if (!root.service || !root.service.backend || !root.service.backend.ready) return
    root.composeReceiptChecking = true
    var mine = root.composeRecoveryRevision
    var states = {}
    var at = 0
    function next() {
      if (!root || typeof root.restoreComposeRecovery !== "function") return
      if (mine !== root.composeRecoveryRevision) { root.composeReceiptChecking = false; return }
      if (at >= pending.length) { finish(); return }
      var draft = pending[at++]
      root.service.backend.call("outbox.snapshot", { accountId: String(draft.accountId || ""), sendId: String(draft.pendingSendId) }, function(result, error) {
        if (!root || typeof root.restoreComposeRecovery !== "function") return
        if (error || !result || !Array.isArray(result.entries)) {
          root.composeReceiptChecking = false
          showRecoveryNotice("Checking whether the recovered message was sent. Reconnect the mail backend.")
          return
        }
        states[String(draft.accountId) + "\n" + String(draft.pendingSendId)] = result.entries.length ? String(result.entries[0].state || "unknown") : "missing"
        Qt.callLater(next)
      })
    }
    function finish() {
      root.composeReceiptChecking = false
      root.composeDeliveryStates = states
      var restored = [], waiting = [], receipts = []
      for (var draftIndex = 0; draftIndex < drafts.length; draftIndex++) {
        var draft = drafts[draftIndex]
        var id = String(draft.pendingSendId || "")
        if (id === "") { restored.push(draft); continue }
        var state = states[String(draft.accountId) + "\n" + id]
        if (state === "queued" || state === "sending") { waiting.push(draft); continue }
        if (state !== "unknown" && state !== "missing") receipts.push({accountId: String(draft.accountId), sendId: id})
        if (state === "sent") continue
        var recovered = Object.assign({}, draft)
        delete recovered.pendingSendId
        recovered.deliveryUnknown = state === "unknown"
        restored.push(recovered)
      }
      var parked = compose.parkedDrafts.slice()
      for (var waitingIndex = 0; waitingIndex < waiting.length; waitingIndex++) {
        var id = String(waiting[waitingIndex].pendingSendId)
        if (!parked.some(function(entry) { return entry.sendId === id && entry.draft && String(entry.draft.accountId || "") === String(waiting[waitingIndex].accountId || "") })) parked.push({sendId:id,draft:waiting[waitingIndex]})
      }
      compose.parkedDrafts = parked
      var all = restored.concat(waiting)
      var updated = all.length ? {version:1,active:true,returnView:record.returnView,draft:all[0],parked:all.slice(1)} : Recovery.empty()
      root.composeRecovery = updated
      root.composeRecoveryRevision++
      root.lastComposeRecoveryText = updated.active ? JSON.stringify(updated) : ""
      // Invariant: Recovery.empty() is presentation state; Rust stores versioned records.
      root.writeComposeRecovery(all.length ? JSON.stringify(updated) : '{"version":1,"active":false}')
      for (var receiptIndex = 0; receiptIndex < receipts.length; receiptIndex++) root.queueComposeReceiptAck(receipts[receiptIndex].accountId, receipts[receiptIndex].sendId, root.composeRecoveryRevision)
      Qt.callLater(root.restoreComposeRecovery)
    }
    next()
  }

  function queueComposeReceiptAck(accountId, sendId, revision) {
    if (accountId === "" || sendId === "") return
    // Invariant: forgetting releases payloads but retains send-ID/digest tombstones after recovery is durable.
    var next = root.composeReceiptAcks.filter(function(entry) { return entry.accountId !== accountId || entry.sendId !== sendId })
    next.push({accountId:accountId,sendId:sendId,revision:revision})
    root.composeReceiptAcks = next
    controller.acknowledgeComposeReceipts()
  }
  function acknowledgeComposeReceipts() {
    if (!root.service || !root.service.backend || !root.service.backend.ready) return
    for (var receiptIndex = 0; receiptIndex < root.composeReceiptAcks.length; receiptIndex++)
      acknowledgeComposeReceipt(root.composeReceiptAcks[receiptIndex])
  }

  function acknowledgeComposeReceipt(entry) {
    var key = entry.accountId + "\n" + entry.sendId
    if (entry.revision > root.composeCommittedRevision || root.composeReceiptAckBusy[key]) return
    var busy = Object.assign({}, root.composeReceiptAckBusy); busy[key] = true; root.composeReceiptAckBusy = busy
    root.service.backend.call("outbox.snapshot", {accountId:entry.accountId,sendId:entry.sendId}, function(result,error) {
      if (!root || typeof root.acknowledgeComposeReceipts !== "function") return
      var state = !error && result && result.entries && result.entries.length ? result.entries[0].state : ""
      if (state !== "sent" && state !== "cancelled" && state !== "failed") {
        var busy = Object.assign({}, root.composeReceiptAckBusy); delete busy[key]; root.composeReceiptAckBusy = busy
        return
      }
      root.service.backend.call("outbox.forget", {accountId:entry.accountId,sendId:entry.sendId}, function(result,error) {
        if (!root || typeof root.acknowledgeComposeReceipts !== "function") return
        var busy = Object.assign({}, root.composeReceiptAckBusy); delete busy[key]; root.composeReceiptAckBusy = busy
        if (!error) root.composeReceiptAcks = root.composeReceiptAcks.filter(function(value) { return value.accountId !== entry.accountId || value.sendId !== entry.sendId })
      })
    })
  }

  function readComposeRecovery() {
    if (!recoverySupported || root.composeReading) return
    root.composeReading = true
    var mine = root.composeRecoveryRevision
    root.service.backend.call("compose.recoveryRead", {}, function(result, error) {
      if (!root) return
      root.composeReading = false
      if (error || !result) return
      if (root.composeRecoveryConflict && root.composeWriteQueued) return
      root.composeStorageRevision = String(result.revision || "")
      root.composeRecoveryLoaded = true
      if (root.composeRecoveryRevision === mine && root.composeWritePayload === "") {
        root.composeCommittedRevision = mine
        root.loadComposeRecovery(result.record)
      }
      root.drainComposeRecovery()
    })
  }

  function restoreComposeRecovery() {
    if (root.composeReceiptChecking || !root.opened || !root.composeRecoveryLoaded || root.composeRecovery.active !== true
        || compose.opened || !root.composeRecovery.draft) return false
    if (String(root.composeRecovery.draft.pendingSendId || "") !== "") return false
    if (root.composeRecovery.draft.deliveryUnknown === true) showRecoveryNotice("Delivery status is unknown. Check Sent before trying again.")
    var accountId = String(root.composeRecovery.draft.accountId || "")
    if (accountId !== "" && root.service
        && String(root.service.activeAccountId || "") !== accountId
        && typeof root.service.switchTo === "function" && root.service.switchTo(accountId) === false) {
      showRecoveryNotice("This draft belongs to an unavailable account.")
      return false
    }
    root.pendingComposeReturnTo = root.composeRecovery.returnView === "reader" ? Nav.depth(root.nav) : 1
    root.composeRecoveryRestoring = true
    compose.restoreDraft(root.composeRecovery.draft)
    root.composeRecoveryRestoring = false
    var parked = (root.composeRecovery.parked || []).filter(function(draft) { return String(draft.pendingSendId || "") === "" })
    if (parked.length > 0) compose.recoveryDrafts = compose.recoveryDrafts.concat(parked)
    return true
  }

  function parkedBesides(draft) {
    var out = []
    var parked = compose.parkedDrafts || []
    for (var parkedIndex = 0; parkedIndex < parked.length; parkedIndex++) {
      if (parked[parkedIndex].draft !== draft) out.push(Object.assign({}, parked[parkedIndex].draft, {pendingSendId: String(parked[parkedIndex].sendId || "")}))
    }
    var recovered = compose.recoveryDrafts || []
    for (var recoveredIndex = 0; recoveredIndex < recovered.length; recoveredIndex++) {
      if (recovered[recoveredIndex] !== draft) out.push(recovered[recoveredIndex])
    }
    return out
  }

  function saveComposeRecovery(saved) {
    composeRecoveryTimer.stop()
    var draft = saved || (compose.opened ? compose.snapshotDraft()
      : (compose.parkedForSend ? compose.pendingDraft : null))
    if (!draft) {
      root.clearComposeRecovery()
      return root.composeRecoveryRevision
    }
    var recordDraft = draft
    var sends = compose.parkedDrafts || []
    for (var sendIndex = 0; sendIndex < sends.length; sendIndex++) if (sends[sendIndex].draft === draft) recordDraft = Object.assign({}, draft, {pendingSendId: String(sends[sendIndex].sendId || "")})
    var record = { version: 1, active: true, returnView: root.composeReturnView(), draft: recordDraft, parked: root.parkedBesides(draft) }
    var raw = JSON.stringify(record)
    root.composeRecovery = record
    if (raw === root.lastComposeRecoveryText) return root.composeRecoveryRevision
    root.composeRecoveryRevision++
    root.lastComposeRecoveryText = raw
    root.writeComposeRecovery(raw)
    return root.composeRecoveryRevision
  }

  // Invariant: unchanged draft text does not reschedule writes; a refused save needs its own retry timer.
  function scheduleComposeRecoveryRetry() {
    if (recoveryRetries >= maxRecoveryRetries) return
    recoveryRetries++
    recoveryRetryTimer.interval = 1000 * Math.pow(2, recoveryRetries - 1)
    recoveryRetryTimer.restart()
  }

  // Invariant: only a successful write resets recovery retries; successful reads prove no write capability.
  function resetComposeRecoveryRetry() {
    recoveryRetries = 0
    recoveryRetryTimer.stop()
  }

  function scheduleComposeRecovery() {
    if (root.composeRecoveryRestoring) return
    composeRecoveryTimer.restart()
  }

  function clearComposeRecovery(expectedRevision) {
    if (expectedRevision !== undefined
        && Number(expectedRevision) !== root.composeRecoveryRevision) return false
    // Invariant: clearing a draft discards its hidden notice but retains an unresolved save-failure notice.
    controller.noticeBehindSaveFailure = ""
    controller.saveFailureHidUpdateNotice = false
    composeRecoveryTimer.stop()
    root.composeRecovery = Recovery.empty()
    root.composeRecoveryRevision++
    if (root.lastComposeRecoveryText === "") return true
    root.lastComposeRecoveryText = ""
    root.writeComposeRecovery('{"version":1,"active":false}')
    return true
  }

  function writeComposeRecovery(raw) {
    root.composeWritePayload = String(raw || "")
    root.composeWriteQueued = true
    if (recoveryNeedsUpdate)
      showRecoveryNotice(recoveryUpdateNotice, true)
    if (!root.composeRecoveryLoaded || root.composeStorageRevision === "") root.readComposeRecovery()
    else root.drainComposeRecovery()
  }

  function drainComposeRecovery() {
    if (root.composeRecoveryConflict || root.composeWriting || !root.composeWriteQueued || !root.composeRecoveryLoaded
        || !recoverySupported || root.composeStorageRevision === "") return
    var raw = root.composeWritePayload
    var mine = root.composeRecoveryRevision
    root.composeWriteQueued = false
    root.composeWriting = true
    root.service.backend.call("compose.recoverySave", { record: JSON.parse(raw), expectedRevision: root.composeStorageRevision }, function(result, error) {
      if (!root) return
      root.composeWriting = false
      if (error || !result) {
        // Invariant: stale processes must never overwrite another instance's recovery by retrying with a fresh revision.
        root.composeWriteQueued = true
        root.composeRecoveryConflict = !!error && error.message === "recovery_conflict"
        controller.showSaveFailureNotice()
        if (!root.composeRecoveryConflict && error
            && controller.unsentRefusals.indexOf(error.code) >= 0)
          controller.scheduleComposeRecoveryRetry()
        return
      }
      controller.resetComposeRecoveryRetry()
      root.composeStorageRevision = String(result.revision || "")
      root.composeCommittedRevision = Math.max(root.composeCommittedRevision, mine)
      if (controller.recoverySaveFailurePending) {
        // Invariant: a successful save clears its own update/save warning, preserving unrelated delivery warnings.
        controller.showRecoveryNotice(
          controller.saveFailureHidUpdateNotice ? "" : controller.noticeBehindSaveFailure)
      } else if (root.composeRecoveryUpdateNoticePending) {
        controller.showRecoveryNotice("")
      }
      root.acknowledgeComposeReceipts()
      if (mine === root.composeRecoveryRevision && !root.composeWriteQueued) {
        root.composeRecovery = result.record
        if (!result.record || result.record.active !== true) root.lastComposeRecoveryText = ""
        root.composeWritePayload = ""
      }
      root.drainComposeRecovery()
    })
  }

}

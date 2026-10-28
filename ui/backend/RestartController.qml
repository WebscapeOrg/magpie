import QtQuick

QtObject {
  id: root
  required property var app
  readonly property var service: app ? app.service : null
  property string phase: "idle"
  readonly property bool busy: phase !== "idle"
  readonly property bool canCancel: phase === "saving"
  property string message: ""
  property bool failed: false
  property int serial: 0
  property int persistenceRevision: 0
  property bool resumeWrites: false
  property int prepareTimeout: 15000
  property double expires: 0

  function finish(message, failed) {
    phase = "idle"
    root.message = message
    root.failed = failed === true
    serial++
  }

  function request() {
    if (busy) return false
    if (!service || !service.backend || typeof service.backend.restart !== "function"
        || !service.backendRuntime || typeof service.backendRuntime.refresh !== "function") {
      finish("Restart is unavailable in this session.", true)
      return false
    }
    if (service.backendRuntime.busy) {
      finish("Wait for the mail backend check to finish, then restart.", true)
      return false
    }
    failed = false
    message = "Saving your work before restarting"
    persistenceRevision = Number(service.persistenceFailureRevision || 0)
    resumeWrites = service.backend.processExitConfirmed === true && !service.backend.ready
    phase = "saving"
    expires = Date.now() + prepareTimeout
    serial++
    app.prepareRestart()
    Qt.callLater(advance)
    return true
  }

  function cancel() {
    if (!canCancel) return false
    finish("Restart cancelled. Your window is still open.", false)
    return true
  }

  function advance() {
    if (phase === "saving" || phase === "finishing") {
      if (Number(service.persistenceFailureRevision || 0) !== persistenceRevision
          || app.composeRecoveryConflict) {
        finish(phase === "finishing"
          ? "Mail restarted, but your changes could not be saved. Keep this window open."
          : "Your changes could not be saved. Restart cancelled; your window and draft are still open.", true)
        return
      }
      if (phase === "saving" && resumeWrites) {
        stopAndValidate()
        return
      }
      if (!app.restartWorkSaved) {
        if (Date.now() >= expires)
          finish(phase === "finishing"
            ? "Mail restarted. Some changes are still being saved; keep this window open."
            : "Your changes are still being saved. Try Restart again when saving finishes.", true)
        return
      }
      if (phase === "finishing") {
        finish("Mail restarted. Your window and draft stayed in place.", false)
        return
      }
      stopAndValidate()
      return
    }
    if (phase !== "checking") return
    if (service.backendRuntime.busy) {
      if (Date.now() >= expires)
        finish("The mail engine check did not finish. Try Restart again.", true)
      return
    }
    if (service.backendRuntime.state !== "ready") {
      finish("The installed mail engine could not be verified. Check Mail backend below, then try Restart again.", true)
      return
    }
    phase = "starting"
    message = "Starting mail"
    var generation = serial
    service.backend.restart(function(error) {
      if (!root || root.serial !== generation) return
      if (!error && root.resumeWrites) {
        root.phase = "finishing"
        root.message = "Saving your changes after reconnecting"
        root.expires = Date.now() + root.prepareTimeout
        root.app.prepareRestart()
        Qt.callLater(root.advance)
        return
      }
      root.finish(error
        ? "Mail could not restart. Your window and draft are still open. Try Restart again."
        : "Mail restarted. Your window and draft stayed in place.", !!error)
    })
  }

  function stopAndValidate() {
    phase = "stopping"
    message = "Restarting mail"
    var generation = serial
    if (service.backend.shutdownFinished && service.backend.processExitConfirmed) {
      validateRuntime(generation)
      return
    }
    service.backend.shutdown(function(error) {
      if (!root || root.serial !== generation) return
      if (error) {
        root.finish("Mail could not stop cleanly. Your window and draft are still open. Try Restart again.", true)
        return
      }
      root.validateRuntime(generation)
    })
  }

  function validateRuntime(generation) {
    if (serial !== generation) return
    phase = "checking"
    message = "Checking the installed mail engine"
    expires = Date.now() + 240000
    if (typeof service.backendRuntime.restartEngine === "function") service.backendRuntime.restartEngine()
    else service.backendRuntime.refresh()
    Qt.callLater(advance)
  }

  readonly property Timer progress: Timer {
    interval: 50
    repeat: true
    running: root.phase === "saving" || root.phase === "checking" || root.phase === "finishing"
    onTriggered: root.advance()
  }
}

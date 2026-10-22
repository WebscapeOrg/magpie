import QtQuick
import QtTest
import "../../backend" as Backend

Item {
  id: fixture
  property var events: []

  QtObject {
    id: fakeBackend
    property bool shutdownFinished: false
    property bool processExitConfirmed: false
    property bool ready: true
    property var shutdownCallback: null
    property var restartCallback: null
    function shutdown(callback) {
      fixture.events = fixture.events.concat(["stop"])
      shutdownCallback = callback
    }
    function restart(callback) {
      fixture.events = fixture.events.concat(["start"])
      restartCallback = callback
    }
    function stopped(error) {
      ready = false
      shutdownFinished = true
      processExitConfirmed = !error
      shutdownCallback(error)
    }
    function restarted(error) {
      ready = !error
      if (!error) {
        shutdownFinished = false
        processExitConfirmed = false
      }
      restartCallback(error)
    }
  }

  QtObject {
    id: runtime
    property bool busy: false
    property string state: "ready"
    function refresh() {
      fixture.events = fixture.events.concat(["validate"])
      busy = true
    }
  }

  QtObject {
    id: fakeService
    property var backend: fakeBackend
    property var backendRuntime: runtime
    property int persistenceFailureRevision: 0
  }

  QtObject {
    id: fakeApp
    property var service: fakeService
    property bool restartWorkSaved: true
    property bool composeRecoveryConflict: false
    property bool failSave: false
    property string draft: "Unsent synthetic draft"
    property int windowWidth: 987
    property string workspace: "4"
    function prepareRestart() {
      fixture.events = fixture.events.concat(["save"])
      if (failSave) fakeService.persistenceFailureRevision++
    }
  }

  Component {
    id: controllerFactory
    Backend.RestartController { app: fakeApp }
  }

  TestCase {
    name: "RestartController"

    function init() {
      fixture.events = []
      fakeApp.restartWorkSaved = true
      fakeApp.composeRecoveryConflict = false
      fakeApp.failSave = false
      fakeBackend.shutdownFinished = false
      fakeBackend.processExitConfirmed = false
      fakeBackend.ready = true
      fakeBackend.shutdownCallback = null
      fakeBackend.restartCallback = null
      runtime.busy = false
      runtime.state = "ready"
    }

    function makeController() {
      var controller = createTemporaryObject(controllerFactory, fixture)
      verify(controller)
      return controller
    }

    function verifyWindowAndDraft() {
      compare(fakeApp.draft, "Unsent synthetic draft")
      compare(fakeApp.windowWidth, 987)
      compare(fakeApp.workspace, "4")
    }

    function finishValidation(controller) {
      runtime.busy = false
      controller.advance()
      compare(controller.phase, "starting")
      compare(fixture.events[fixture.events.length - 1], "start")
    }

    function test_saves_then_confirms_exit_then_validates_then_waits_for_readiness() {
      var controller = makeController()
      verify(controller.request())
      compare(controller.phase, "saving")
      controller.advance()
      compare(fixture.events, ["save", "stop"])
      compare(controller.phase, "stopping")
      fakeBackend.stopped(null)
      compare(fixture.events, ["save", "stop", "validate"])
      compare(controller.phase, "checking")
      controller.advance()
      compare(controller.phase, "checking")
      finishValidation(controller)
      verify(controller.busy)
      fakeBackend.restartCallback(null)
      verify(!controller.busy)
      verify(!controller.failed)
      verify(controller.message.indexOf("Mail restarted") >= 0)
      verifyWindowAndDraft()
    }

    function test_pending_account_settings_or_draft_writes_block_shutdown() {
      var controller = makeController()
      fakeApp.restartWorkSaved = false
      controller.request()
      controller.advance()
      compare(fixture.events, ["save"])
      fakeApp.restartWorkSaved = true
      controller.advance()
      compare(fixture.events, ["save", "stop"])
    }

    function test_failed_save_refuses_shutdown_and_keeps_work() {
      var controller = makeController()
      fakeApp.failSave = true
      controller.request()
      controller.advance()
      verify(controller.failed)
      verify(!controller.busy)
      compare(fixture.events, ["save"])
      verifyWindowAndDraft()
    }

    function test_draft_conflict_refuses_shutdown() {
      var controller = makeController()
      fakeApp.composeRecoveryConflict = true
      controller.request()
      controller.advance()
      verify(controller.failed)
      compare(fixture.events, ["save"])
    }

    function test_pending_save_timeout_is_bounded_and_cannot_shutdown_later() {
      var controller = makeController()
      fakeApp.restartWorkSaved = false
      controller.request()
      controller.expires = 0
      controller.advance()
      verify(controller.failed)
      fakeApp.restartWorkSaved = true
      controller.advance()
      compare(fixture.events, ["save"])
    }

    function test_duplicate_request_and_cancel_do_not_restart_backend() {
      var controller = makeController()
      fakeApp.restartWorkSaved = false
      verify(controller.request())
      verify(!controller.request())
      verify(controller.cancel())
      controller.advance()
      compare(fixture.events, ["save"])
      verify(!controller.failed)
      verifyWindowAndDraft()
    }

    function test_cancel_cannot_interrupt_shutdown() {
      var controller = makeController()
      controller.request()
      controller.advance()
      verify(!controller.cancel())
      compare(controller.phase, "stopping")
    }

    function test_failed_stop_retries_only_after_exit_is_confirmed() {
      var controller = makeController()
      controller.request()
      controller.advance()
      fakeBackend.stopped({message: "stop timeout"})
      verify(controller.failed)
      verify(!controller.busy)
      compare(fixture.events, ["save", "stop"])
      fakeBackend.processExitConfirmed = true
      controller.request()
      controller.advance()
      compare(fixture.events, ["save", "stop", "save", "validate"])
      finishValidation(controller)
      fakeBackend.restartCallback(null)
      verify(!controller.failed)
      verifyWindowAndDraft()
    }

    function test_failed_runtime_check_keeps_window_and_can_be_retried() {
      var controller = makeController()
      controller.request()
      controller.advance()
      fakeBackend.stopped(null)
      runtime.busy = false
      runtime.state = "error"
      controller.advance()
      verify(controller.failed)
      compare(fixture.events, ["save", "stop", "validate"])
      verifyWindowAndDraft()
      controller.request()
      controller.advance()
      runtime.state = "ready"
      finishValidation(controller)
      fakeBackend.restartCallback(null)
      verify(!controller.failed)
    }

    function test_failed_start_reports_failure_and_preserves_work() {
      var controller = makeController()
      controller.request()
      controller.advance()
      fakeBackend.stopped(null)
      finishValidation(controller)
      fakeBackend.restartCallback({message: "incompatible backend"})
      verify(controller.failed)
      verify(!controller.busy)
      verifyWindowAndDraft()
    }

    function test_confirmed_stopped_backend_resumes_before_flushing_queued_edits() {
      var controller = makeController()
      fakeBackend.ready = false
      fakeBackend.shutdownFinished = true
      fakeBackend.processExitConfirmed = true
      fakeApp.restartWorkSaved = false
      controller.request()
      controller.advance()
      compare(fixture.events, ["save", "validate"])
      finishValidation(controller)
      fakeBackend.restarted(null)
      compare(controller.phase, "finishing")
      controller.advance()
      verify(controller.busy)
      fakeApp.restartWorkSaved = true
      controller.advance()
      verify(!controller.busy)
      verify(!controller.failed)
      verify(fixture.events.indexOf("stop") < 0)
      verifyWindowAndDraft()
    }

    function test_resumed_backend_reports_save_failure_without_stopping_again() {
      var controller = makeController()
      fakeBackend.ready = false
      fakeBackend.shutdownFinished = true
      fakeBackend.processExitConfirmed = true
      fakeApp.restartWorkSaved = false
      controller.request()
      controller.advance()
      finishValidation(controller)
      fakeBackend.restarted(null)
      fakeService.persistenceFailureRevision++
      controller.advance()
      verify(controller.failed)
      verify(controller.message.indexOf("Mail restarted") >= 0)
      verify(fixture.events.indexOf("stop") < 0)
      verifyWindowAndDraft()
    }

    function test_already_exited_backend_is_held_stopped_during_validation() {
      var controller = makeController()
      fakeBackend.ready = false
      fakeBackend.processExitConfirmed = true
      fakeApp.restartWorkSaved = false
      controller.request()
      controller.advance()
      compare(fixture.events, ["save", "stop"])
      fakeBackend.stopped(null)
      compare(fixture.events, ["save", "stop", "validate"])
      finishValidation(controller)
      fakeBackend.restarted(null)
      fakeApp.restartWorkSaved = true
      controller.advance()
      verify(!controller.busy)
      verify(!controller.failed)
    }
  }
}

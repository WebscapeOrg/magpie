import QtQuick
import QtTest
import Magpie.Acceptance
import "../../app/qml" as Standalone

Item {
  width: 1; height: 1
  Standalone.Main {
    id: desktop
    title: "Magpie synthetic acceptance"
    x: 0; y: 0
    property int marker: 0
    Rectangle {
      x: 8; y: 8; width: 16; height: 16; z: 10000
      color: desktop.marker % 2 ? "#ff00ff" : "#00ffff"
    }
    TestCase {
      name: "DesktopAcceptance"
      when: desktop.visible
      SignalSpy { id: sendClicks; signalName: "clicked" }
      function capture(kind, started) {
        desktop.marker++
        Probe.capture(kind, started, desktop.marker)
        tryVerify(function() { return Probe.captured(desktop.marker) }, 15000)
      }
      function find(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var children = item.children || []
        for (var i = 0; i < children.length; i++) {
          var found = find(children[i], name)
          if (found) return found
        }
        return null
      }
      function row(id) {
        var rows = desktop.service.messages
        for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return rows[i]
        return null
      }
      function undoLatest() {
        desktop.service.localMailbox.refreshEdits()
        var ticket = ""
        tryVerify(function() {
          var edits = desktop.service.localMailbox.edits
          for (var i = edits.length - 1; i >= 0; i--) {
            if (edits[i].state === "queued") { ticket = edits[i].ticket; return true }
          }
          return false
        }, 5000)
        desktop.service.localMailbox.undo(ticket)
      }
      function test_offline_desktop() {
        tryCompare(desktop.service.backend, "ready", true, 15000)
        tryVerify(function() { return desktop.service.messages.length > 0 }, 15000)
        tryCompare(desktop.service, "listLoading", false, 15000)
        compare(desktop.service.backend.apiVersion, 8)
        capture("coldInbox", Probe.launchedAt)
        verify(desktop.service.localMailbox.hasMail)
        Probe.checkpoint("cached-inbox-visible-without-credentials")
        if (Probe.options.accessibility) {
          Probe.checkpoint("accessibility-inbox")
          tryVerify(function() { return Probe.checkpointComplete("accessibility-inbox") }, 15000)
          tryCompare(desktop.service.localMailbox.status, "paused", true)
        }
        var samples = Number(Probe.options.samples || 7)
        desktop.app.openMessage(desktop.service.messages[20].id)
        tryVerify(function() { return !!desktop.service.selectedBody.text && !desktop.service.detailLoading }, 10000)
        for (var i = 0; i < samples; i++) {
          var previous = desktop.app.cursorId
          var started = Date.now()
          Probe.press(desktop, i % 2 === 0 ? Qt.Key_J : Qt.Key_K)
          verify(desktop.app.cursorId !== previous)
          capture("input", started)
        }
        for (var j = 0; j < samples; j++) {
          var oldId = desktop.app.cursorId
          var navigationStarted = Date.now()
          Probe.press(desktop, j % 2 === 0 ? Qt.Key_K : Qt.Key_J)
          verify(desktop.app.cursorId !== oldId)
          tryVerify(function() { return !!desktop.service.selectedBody.text && !desktop.service.detailLoading }, 10000)
          capture("navigation", navigationStarted)
        }
        desktop.app.backToList()
        for (var n = 0; n < samples; n++) {
          var began = Date.now()
          desktop.service.search(n % 2 === 0 ? "needle" : "ordinary")
          tryVerify(function() { return !desktop.service.listLoading && desktop.service.messages.length > 0 }, 10000)
          capture("search", began)
        }
        desktop.service.search("")
        tryVerify(function() { return !desktop.service.listLoading && desktop.service.messages.length > 0 }, 10000)
        var large = Probe.options.largeIds || []
        for (var h = 0; h < large.length; h++) {
          var htmlStarted = Date.now()
          desktop.app.openMessage(large[h])
          tryVerify(function() { return desktop.service.selectedHasHtml && desktop.service.detailPainted && !desktop.service.detailLoading }, 15000)
          capture("largeHtml", htmlStarted)
        }
        desktop.app.backToList()
        var editedId = desktop.service.messages[25].id
        var editStarted = Date.now()
        desktop.service.toggleStar(editedId)
        tryVerify(function() { return row(editedId) && row(editedId).starred === true }, 5000)
        capture("offlineEdit", editStarted)
        undoLatest()
        tryVerify(function() { return row(editedId) && row(editedId).starred === false }, 5000)
        verify(desktop.service.act(editedId, "archive"))
        tryVerify(function() { return row(editedId) === null }, 5000)
        undoLatest()
        tryVerify(function() { return row(editedId) !== null }, 5000)
        Probe.checkpoint("offline-star-and-archive-visible-and-undo-restores-mail")
        var composeStarted = Date.now()
        desktop.app.startCompose("new")
        tryCompare(desktop.app, "composing", true)
        capture("compose", composeStarted)
        var send = find(desktop.app, "compose-send-button")
        verify(send !== null)
        var focusStarted = Date.now()
        send.forceActiveFocus()
        verify(send.activeFocus)
        capture("composeFocus", focusStarted)
        if (Probe.options.accessibility) {
          Probe.checkpoint("accessibility-compose")
          tryVerify(function() { return Probe.checkpointComplete("accessibility-compose") }, 15000)
          tryCompare(desktop.app, "composing", false, 10000)
          tryCompare(desktop.service, "sendPending", true, 10000)
          Probe.checkpoint("accessible-send-durably-queued-without-credentials")
        } else {
          find(desktop.app, "compose-to-field").text = "recipient@example.test"
          find(desktop.app, "compose-subject-field").text = "Synthetic keyboard send"
          find(desktop.app, "compose-body-editor").text = "Synthetic body"
          wait(50)
          send.forceActiveFocus()
          verify(send.activeFocus)
          sendClicks.target = send
          sendClicks.clear()
          Probe.press(desktop, Qt.Key_Space)
          compare(sendClicks.count, 1)
          tryCompare(desktop.app, "composing", false, 10000)
          tryCompare(desktop.service, "sendPending", true, 10000)
          Probe.checkpoint("keyboard-send-durably-queued-without-credentials")
        }
        desktop.service.backend.shutdown(function() {})
      }
    }
  }

}

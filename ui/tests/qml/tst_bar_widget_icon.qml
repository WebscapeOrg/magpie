import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail
import "../../bar/Bridge.js" as BarBridge

Item {
  width: 400
  height: 60

  QtObject {
    id: fakeService

    property bool showBarIcon: true
    property bool ready: true
    property bool windowOpen: false
    property int unreadTotal: 3
    property string barTooltip: "Omamail"
    property var barMessages: []
    property var barEvents: []
    property string contentDirection: "Auto"
    property int refreshCount: 0
    property int calendarRefreshCount: 0

    property var appliedSettings: null
    property int applyCount: 0

    function applySettings(values) {
      appliedSettings = values
      applyCount += 1
    }

    function refresh() { refreshCount += 1 }
    function refreshCalendarPreview() { calendarRefreshCount += 1 }
  }

  QtObject {
    id: fakeShell
    function serviceFor(_id) { return fakeService }
    function summon(_id, _payload) {}
  }

  QtObject {
    id: startingShell
    property string lastPayload: ""
    function serviceFor(_id) { return null }
    function summon(_id, payload) { lastPayload = payload }
  }

  QtObject {
    id: fakeBar
    property var shell: fakeShell
    property bool vertical: false
    property color barForeground: Qt.rgba(1, 1, 1, 1)
  }

  Omamail.BarWidget {
    id: widget
    bar: fakeBar
    settings: ({ refreshIntervalSec: 300, showBarIcon: true })
  }

  TestCase {
    name: "BarWidgetIcon"
    when: windowShown

    function init() {
      BarBridge.clear(BarBridge.current())
      if (typeof widget.syncBridge === "function") widget.syncBridge()
      fakeBar.shell = fakeShell
      fakeService.ready = true
      fakeService.windowOpen = false
      fakeService.showBarIcon = true
      fakeService.applyCount = 0
      fakeService.refreshCount = 0
      fakeService.calendarRefreshCount = 0
      widget.previewOpen = false
    }

    function cleanup() {
      BarBridge.clear(BarBridge.current())
      if (typeof widget.syncBridge === "function") widget.syncBridge()
    }

    function publishPreview() {
      return BarBridge.publish(function() { return fakeService },
        function(values) { fakeService.applySettings(values) },
        function() { fakeService.refresh() },
        function() { fakeService.refreshCalendarPreview() })
    }

    function button() {
      for (var childIndex = 0; childIndex < widget.children.length; childIndex++)
        if (widget.children[childIndex].iconComponent) return widget.children[childIndex]
      fail("bar button was not instantiated")
    }

    function test_replacement_bar_restores_status_settings_and_actions() {
      fakeBar.shell = startingShell
      var api = publishPreview()
      tryVerify(function() { return widget.gmail !== null && widget.gmail.ready }, 2000,
        "a connected mailbox must remain connected inside a restricted replacement bar")
      tryCompare(widget, "bridgeApi", api, 2000)
      verify(widget.gmail !== null)
      verify(widget.gmail !== fakeService, "the full service must stay private")
      compare(widget.gmail.ready, true)
      compare(widget.gmail.unreadTotal, 3)
      verify(fakeService.applyCount > 0, "settings reach the service through the bridge")

      var icon = button().iconComponent.createObject(widget)
      verify(icon !== null)
      compare(icon.children[0].crossed, false)
      compare(icon.children[0].dot, true)
      fakeService.ready = false
      fakeService.windowOpen = true
      widget.syncBridge()
      compare(icon.children[0].crossed, true, "real disconnects still show a slash")
      compare(button().windowOpen, true)
      icon.destroy()

      button().pressed(Qt.MiddleButton)
      compare(fakeService.refreshCount, 1)
      button().pressed(Qt.RightButton)
      compare(widget.previewOpen, true)
      compare(fakeService.calendarRefreshCount, 1)
      widget.openMessage("ada@example.org", "mail-1")
      compare(JSON.parse(startingShell.lastPayload).messageId, "mail-1")

      fakeService.showBarIcon = false
      widget.syncBridge()
      compare(widget.drawsIcon, false)
      compare(widget.implicitWidth, 0)
      fakeService.applyCount = 0
      var replacement = publishPreview()
      BarBridge.clear(api)
      widget.syncBridge()
      verify(fakeService.applyCount > 0, "hot reload reapplies the widget settings")
      compare(widget.bridgeApi, replacement)
      BarBridge.clear(replacement)
      BarBridge.clear(api)
      widget.syncBridge()
      compare(widget.gmail, null, "no stale session survives service shutdown")
    }

    function test_the_icon_is_drawn_by_default() {
      compare(widget.drawsIcon, true)
      compare(widget.visible, true)
      verify(widget.implicitWidth > 0)
    }

    function test_normal_bar_keeps_direct_service_when_bridge_is_available() {
      var bridgeCalls = 0
      var api = BarBridge.publish(function() { return { ready: false, unreadTotal: 0 } },
        function(_values) { bridgeCalls += 1 },
        function() { bridgeCalls += 1 },
        function() { bridgeCalls += 1 })
      widget.syncBridge()
      compare(widget.gmail, fakeService)
      compare(widget.gmail.ready, true)
      fakeService.applyCount = 0
      widget.pushSettings()
      compare(fakeService.applyCount, 1)
      var icon = button().iconComponent.createObject(widget)
      compare(icon.children[0].crossed, false)
      compare(icon.children[0].dot, true)
      fakeService.ready = false
      fakeService.unreadTotal = 0
      compare(icon.children[0].crossed, true)
      compare(icon.children[0].dot, false)
      button().pressed(Qt.MiddleButton)
      button().pressed(Qt.RightButton)
      compare(fakeService.refreshCount, 1)
      compare(fakeService.calendarRefreshCount, 1)
      compare(bridgeCalls, 0, "normal bar actions must use the direct service")
      icon.destroy()
      fakeService.unreadTotal = 3
      BarBridge.clear(api)
    }

    function test_turning_it_off_takes_the_width_with_it() {
      fakeService.showBarIcon = false
      compare(widget.drawsIcon, false)
      compare(widget.visible, false)
      compare(widget.implicitWidth, 0)
      compare(widget.implicitHeight, 0)
    }

    function test_a_hidden_widget_still_hands_settings_to_the_service() {
      fakeService.showBarIcon = false
      fakeService.applyCount = 0

      widget.settings = ({ refreshIntervalSec: 600, showBarIcon: false })

      compare(fakeService.applyCount, 1,
        "a hidden widget is still the only route settings have")
      compare(fakeService.appliedSettings.refreshIntervalSec, 600)
      compare(widget.drawsIcon, false, "and it is still hidden")
    }

    function test_no_service_yet_still_draws() {
      fakeBar.shell = startingShell
      compare(widget.gmail, null, "the shell has no service to hand over yet")
      compare(widget.drawsIcon, true)
      compare(widget.visible, true)
      verify(widget.implicitWidth > 0)
    }
  }
}

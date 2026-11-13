import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail

Item {
  width: 400
  height: 60

  QtObject {
    id: fakeShell
    property int serviceCalls: 0
    property int summonCalls: 0
    property int toggleCalls: 0
    function serviceFor(_id) { serviceCalls += 1; return null }
    function summon(_id, _payload) { summonCalls += 1 }
    function toggle(_id, _payload) { toggleCalls += 1 }
  }

  QtObject {
    id: fakeBar
    property var shell: fakeShell
    property bool vertical: false
    property string position: "bottom"
    property string fontFamily: "monospace"
    property color barForeground: Qt.rgba(1, 1, 1, 1)
  }

  Omamail.BarWidget {
    id: widget
    bar: fakeBar
    statusPath: ""
    settings: ({ showBarIcon: true })
  }

  TestCase {
    name: "BarWidgetIcon"
    when: windowShown

    function init() {
      fakeBar.vertical = false
      fakeShell.serviceCalls = 0
      fakeShell.summonCalls = 0
      fakeShell.toggleCalls = 0
      widget.settings = ({ showBarIcon: true })
      widget.activationCommand = ["magpie-mail"]
      widget.launchFailed = false
      statusFile().contents = ""
      statusFile().loaded()
      launchProcess().running = false
    }

    function statusFile() { return findChild(widget, "bar-status-file") }
    function launchProcess() { return findChild(widget, "bar-launch-process") }

    function publish(overrides) {
      var value = {
        ready: true,
        windowOpen: false,
        showBarIcon: true,
        unreadTotal: 3,
        updated: Date.now()
      }
      for (var key in overrides) value[key] = overrides[key]
      statusFile().contents = JSON.stringify(value)
      statusFile().loaded()
    }

    function button() {
      for (var childIndex = 0; childIndex < widget.children.length; childIndex++)
        if (widget.children[childIndex].iconComponent) return widget.children[childIndex]
      fail("bar button was not instantiated")
    }

    function test_a_fresh_snapshot_shows_a_numeric_count_and_open_state() {
      publish({ windowOpen: true, accountEmail: "private@example.test", subject: "private" })
      compare(widget.connected, true)
      compare(widget.unreadTotal, 3)
      compare(widget.countText, "3")
      compare(widget.windowOpen, true)
      compare(widget.barStatus.accountEmail, undefined)
      compare(widget.barStatus.subject, undefined)
      compare(widget.barTooltip, "Open Magpie Mail · 3 unread messages")
      compare(findChild(widget, "bar-open-indicator").visible, true)
      verify(button().slotSize > widget.baseSlot)

      var icon = button().iconComponent.createObject(widget)
      var count = findChild(icon, "bar-count-horizontal")
      verify(count !== null)
      compare(count.text, "3")
      compare(count.visible, true)
      compare(count.textFormat, Text.PlainText)
      compare(count.Accessible.ignored, true)
      compare(count.parent.children[0].Accessible.ignored, true)
      compare(button().Accessible.name, widget.barTooltip)
      icon.destroy()

      publish({ unreadTotal: 1000, windowOpen: false })
      compare(widget.countText, "999+")
      compare(widget.barTooltip, "Open Magpie Mail · 1000 unread messages")
      publish({ unreadTotal: 0 })
      compare(widget.countText, "")
      compare(button().slotSize, widget.baseSlot)
    }

    function test_count_never_overlaps_the_envelope_in_either_bar_direction() {
      publish({})
      var icon = button().iconComponent.createObject(widget)
      var horizontal = findChild(icon, "bar-count-horizontal")
      var horizontalLogo = horizontal.parent.children[0]
      verify(horizontal.x >= horizontalLogo.x + horizontalLogo.width)
      verify(horizontal.parent.width >= horizontal.x + horizontal.width)

      fakeBar.vertical = true
      publish({ unreadTotal: 1000 })
      var vertical = findChild(icon, "bar-count-horizontal")
      var verticalLogo = vertical.parent.children[0]
      verify(vertical.visible)
      verify(vertical.x >= verticalLogo.x + verticalLogo.width)
      verify(vertical.parent.width >= vertical.x + vertical.width)
      icon.destroy()
    }

    function test_stale_and_malformed_status_never_show_a_count() {
      publish({ updated: Date.now() - 45001 })
      compare(widget.barStatus, null)
      compare(widget.connected, false)
      compare(widget.countText, "")
      compare(widget.drawsIcon, true)
      compare(widget.barTooltip, "Open Magpie Mail")

      statusFile().contents = '{"ready":true,"unreadTotal":99}'
      statusFile().loaded()
      compare(widget.barStatus, null)
      compare(widget.countText, "")
    }

    function test_the_envelope_has_no_service_preview_or_toggle() {
      publish({})
      button().pressed(Qt.RightButton)
      button().pressed(Qt.MiddleButton)
      compare(fakeShell.serviceCalls, 0)
      compare(fakeShell.summonCalls, 0)
      compare(fakeShell.toggleCalls, 0)
      compare(widget.previewOpen, undefined)
      compare(widget.gmail, undefined)
    }

    function test_left_click_launches_the_native_app_and_reports_failure() {
      publish({})
      button().pressed(Qt.LeftButton)
      compare(launchProcess().running, true)
      compare(JSON.stringify(launchProcess().command), '["magpie-mail"]')
      compare(fakeShell.summonCalls, 0)
      compare(fakeShell.toggleCalls, 0)
      compare(widget.openWindow(), false, "one in-flight activation is enough")

      launchProcess().running = false
      launchProcess().exited(1)
      compare(widget.launchFailed, true)
      compare(widget.barTooltip, "Magpie Mail could not open. Click to try again.")
      button().pressed(Qt.LeftButton)
      compare(widget.launchFailed, false)
      compare(launchProcess().running, true)
      launchProcess().running = false
      launchProcess().exited(0)
      compare(widget.launchFailed, false)
    }

    function test_native_and_local_visibility_settings_both_take_the_width() {
      publish({ showBarIcon: false })
      compare(widget.drawsIcon, false)
      compare(widget.visible, false)
      compare(widget.implicitWidth, 0)
      compare(widget.implicitHeight, 0)

      publish({ showBarIcon: true })
      compare(widget.drawsIcon, true)
      widget.settings = ({ showBarIcon: false })
      compare(widget.drawsIcon, false)
      compare(widget.implicitWidth, 0)
    }
  }
}

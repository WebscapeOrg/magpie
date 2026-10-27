import QtQuick
import QtTest
import qs.Commons as Commons
import "../../controls" as Mail
import "../../components" as Components
import "../../settings"
import "../../settings/Display.js" as Display

Rectangle {
  id: scene
  width: 1200
  height: 1100
  color: Commons.Color.background
  QtObject {
    id: service
    property var displayPreferences: Display.normalize({})
    function setDisplayPreference(key, value) {
      displayPreferences = Display.changed(displayPreferences, key, value)
    }
  }
  Column {
    x: 24; y: 24; width: 320; spacing: 24
    Mail.PanelSectionHeader { id: heading; text: "Mail controls" }
    Mail.Button { id: button; text: "Open settings" }
    Mail.Button { id: disabledButton; text: "Unavailable"; enabled: false }
    Mail.TextField { id: field; width: parent.width; placeholderText: "Name"; text: "Synthetic account" }
    Mail.NumberField { id: number; label: "Size"; value: 17 }
    Mail.Dropdown { id: dropdown; width: parent.width; label: "Folder"; options: ["Inbox", "Sent"]; value: "Inbox" }
    Mail.PanelActionButton { id: action; iconText: "+"; tooltipText: "Add account"; focusable: true; bordered: true }
  }
  Components.DisplaySettings {
    id: settings
    x: 390; y: 24; width: 780
    service: service
    textColor: Commons.Color.foreground
    dimColor: Commons.Color.foreground
    accentColor: Commons.Color.accent
  }
  Mail.PanelToolTip { id: tip; text: "Open settings" }
  TestCase {
    name: "PanelTheme"
    when: windowShown
    function test_shell_colours_are_resolved_explicitly() {
      compare(button.foreground, Commons.Color.foreground)
      compare(button.accent, Commons.Color.accent)
      compare(button.tooltipBackground, Commons.Color.tooltip.background)
      compare(heading.foreground, Commons.Color.foreground)
      compare(field.foreground, Commons.Color.foreground)
      compare(number.foreground, Commons.Color.foreground)
      compare(dropdown.background, Commons.Color.popups.background)
      compare(dropdown.popupBorder, Commons.Color.popups.border)
      compare(action.foreground, Commons.Color.foreground)
      compare(tip.panelBackground, Commons.Color.tooltip.background)
      compare(tip.panelForeground, Commons.Color.tooltip.text)
      compare(findChild(settings, "interface-font").palette.base, Commons.Color.popups.background)
      compare(findChild(settings, "interface-size").palette.base, Commons.Color.popups.background)
    }
    function test_keyboard_focus_and_disabled_control() {
      action.forceActiveFocus()
      verify(action.activeFocus)
      verify(action._showFocusRing)
      verify(!disabledButton.enabled)
    }
  }
}

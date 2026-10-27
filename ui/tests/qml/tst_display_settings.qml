import QtQuick
import qs.Commons
import qs.Commons as Commons
import QtTest
import "../../components" as Mail
import "../../settings"
import "../../settings/Display.js" as Display

Item {
  width: 720
  height: 1100
  QtObject {
    id: service
    property var displayPreferences: Display.normalize({})
    function setDisplayPreference(key, value) {
      displayPreferences = Display.changed(displayPreferences, key, value)
    }
  }
  Binding { target: MailStyle; property: "preferences"; value: service.displayPreferences }
  Mail.DisplaySettings {
    id: settings
    width: 660
    service: service
    textColor: Commons.Color.foreground
    dimColor: Commons.Color.foreground
    accentColor: Commons.Color.accent
  }
  TestCase {
    name: "DisplaySettings"
    when: windowShown
    function init() { service.displayPreferences = Display.normalize({}) }
    function test_independent_size_controls_and_point_units() {
      var list = findChild(settings, "list-size")
      verify(list)
      list.forceActiveFocus()
      keyClick(Qt.Key_Up)
      compare(service.displayPreferences.listSize, 18)
      compare(service.displayPreferences.interfaceSize, 17)
      compare(service.displayPreferences.messageSize, 17)
      compare(MailStyle.listSize, 18 * 96 / 72)
      compare(MailStyle.body, 17 * 96 / 72)
    }
    function test_system_font_selection_keeps_other_regions() {
      var chooser = findChild(settings, "interface-font")
      verify(chooser)
      mouseClick(chooser)
      keyClick(Qt.Key_Home)
      keyClick(Qt.Key_Return)
      compare(service.displayPreferences.interfaceFamily, "")
      compare(MailStyle.family, "sans-serif")
      compare(MailStyle.listFamily, "Chillax Light")
      compare(MailStyle.messageFamily, "Chillax Light")
    }
  }
}

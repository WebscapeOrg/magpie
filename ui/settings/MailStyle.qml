pragma Singleton
import QtQuick
import Quickshell
import qs.Commons
import "Display.js" as Display

QtObject {
  id: root
  property FontLoader chillax: FontLoader {
    source: {
      var home = Quickshell.env("HOME")
      var data = Quickshell.env("XDG_DATA_HOME") || (home ? home + "/.local/share" : "")
      return data ? "file://" + data + "/fonts/Chillax/Chillax-Light.otf" : ""
    }
  }
  property var preferences: Display.normalize({})
  readonly property string family: preferences.interfaceFamily || "sans-serif"
  readonly property string listFamily: preferences.listFamily || "sans-serif"
  readonly property string messageFamily: preferences.messageFamily || "sans-serif"
  readonly property real body: preferences.interfaceSize * 96 / 72
  readonly property real listSize: preferences.listSize * 96 / 72
  readonly property real messageSize: preferences.messageSize * 96 / 72
  readonly property real bodySmall: body
  readonly property real caption: body * 0.9
  readonly property real subtitle: body * 1.08
  readonly property real title: body * 1.16
  readonly property real heading: body * 1.33
  function muted(foreground, background) {
    return Qt.rgba(foreground.r * 0.68 + background.r * 0.32,
      foreground.g * 0.68 + background.g * 0.32,
      foreground.b * 0.68 + background.b * 0.32, 1)
  }
  function space(value) {
    return Math.round(Style.space(value) * Math.max(1, root.body / Math.max(12, Style.font.body)))
  }
}

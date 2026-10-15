pragma Singleton
import QtQuick

QtObject {
  property color foreground: Qt.rgba(1, 1, 1, 1)
  readonly property color background: Qt.rgba(0.025,0.07,0.08,1)
  readonly property color urgent: Qt.rgba(1,0.3,0.2,1)
  readonly property var popups: ({text:foreground, background:Qt.rgba(0.1,0.1,0.1,1), border:foreground})
  readonly property var tooltip: ({text:foreground, background:Qt.rgba(0.1,0.1,0.1,1), border:foreground})
  readonly property color accent: Qt.rgba(1, 0.5, 0, 1)
}

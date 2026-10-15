import QtQuick
import qs.Commons

Item {
  id: root
  required property color foreground
  required property color accent
  property bool animated: false
  implicitWidth: Style.space(64)
  implicitHeight: implicitWidth
  Text {
    anchors.centerIn: parent
    text: "🐦"
    font.family: "Noto Color Emoji"
    font.pixelSize: root.width * 0.8
    Accessible.name: "Magpie"
  }
}

import QtQuick
import qs.Commons
Item {
  id: root
  required property color foreground
  required property color accent
  property bool animated: false
  implicitWidth: Style.space(64)
  implicitHeight: implicitWidth
  Accessible.role: Accessible.Graphic
  Accessible.name: "Magpie"
  Image {
    anchors.fill: parent
    source: "../assets/magpie.svg"
    sourceSize.width: width * 2
    sourceSize.height: height * 2
    fillMode: Image.PreserveAspectFit
  }
}

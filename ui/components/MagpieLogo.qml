import QtQuick
import qs.Commons
// Apple's ✉️, the same 160 px drawing as the iPhone app's icon (magpie-ios scripts/emoji.sh), smoothed down to size.
Item {
  readonly property alias image: picture
  implicitWidth: Style.space(64)
  implicitHeight: implicitWidth
  Accessible.role: Accessible.Graphic
  Accessible.name: "Magpie Mail"
  Image {
    id: picture
    anchors.fill: parent
    source: "../assets/magpie-mail.png"
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
  }
}

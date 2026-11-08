import QtQuick
import qs.Commons
// Apple's ✉️, the same 160 px drawing as the iPhone app's icon (magpie-ios scripts/emoji.sh), smoothed down to size.
Image {
  implicitWidth: Style.space(64)
  implicitHeight: implicitWidth
  source: "../assets/magpie-mail.png"
  fillMode: Image.PreserveAspectFit
  smooth: true
  mipmap: true
  Accessible.role: Accessible.Graphic
  Accessible.name: "Magpie Mail"
}

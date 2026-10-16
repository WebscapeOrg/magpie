import QtQuick
import "MailboxIdentity.js" as Identity
Rectangle {
  id: root
  property var sender: ({})
  property string imageData: ""
  required property color foreground
  required property color accent
  required property string fontFamily
  readonly property string safeImage: Identity.image(imageData)
  radius: width / 2
  color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)
  Accessible.role: Accessible.Graphic
  Accessible.name: String(sender.display || sender.email || "Sender")
  Text {
    anchors.centerIn: parent
    visible: root.safeImage === "" || !picture.loaded
    textFormat: Text.PlainText
    text: Identity.initial(root.sender)
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.height * 0.5
  }
  Image {
    id: picture
    anchors.centerIn: parent
    width: parent.width * Math.SQRT1_2 * 0.85
    height: parent.height * Math.SQRT1_2 * 0.85
    source: root.safeImage
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
    readonly property bool loaded: status === Image.Ready
  }
}

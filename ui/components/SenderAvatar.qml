import QtQuick
import QtQuick.Window
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
    objectName: "sender-avatar-image"
    anchors.centerIn: parent
    width: parent.width
    height: parent.height
    source: root.safeImage
    sourceSize: Qt.size(Math.max(1, Math.ceil(width * Screen.devicePixelRatio)),
      Math.max(1, Math.ceil(height * Screen.devicePixelRatio)))
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
    readonly property bool loaded: status === Image.Ready
  }
}

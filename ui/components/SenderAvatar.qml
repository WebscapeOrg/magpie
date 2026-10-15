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
  Canvas {
    id: picture
    anchors.fill: parent
    property bool loaded: root.safeImage !== "" && isImageLoaded(root.safeImage)
    onImageLoaded: { loaded = root.safeImage !== "" && isImageLoaded(root.safeImage); requestPaint() }
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Connections {
      target: root
      function onSafeImageChanged() {
        picture.loaded = false
        if (root.safeImage !== "") picture.loadImage(root.safeImage)
        picture.requestPaint()
      }
    }
    Component.onCompleted: if (root.safeImage !== "") loadImage(root.safeImage)
    onPaint: {
      var context = getContext("2d")
      context.reset()
      if (!loaded || root.safeImage === "") return
      context.save()
      context.beginPath()
      context.arc(width / 2, height / 2, width / 2, 0, 2 * Math.PI)
      context.clip()
      context.drawImage(root.safeImage, 0, 0, width, height)
      context.restore()
    }
  }
}

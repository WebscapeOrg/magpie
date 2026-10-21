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
  Canvas {
    id: ink
    anchors.fill: parent
    antialiasing: true
    readonly property url source: "../assets/magpie.svg"
    onImageLoaded: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Component.onCompleted: loadImage(source)
    Connections {
      target: root
      function onForegroundChanged() { ink.requestPaint() }
    }
    onPaint: {
      if (!isImageLoaded(source)) return
      var context = getContext("2d")
      context.reset()
      context.clearRect(0, 0, width, height)
      var size = Math.min(width, height)
      context.drawImage(source, (width - size) / 2, (height - size) / 2, size, size)
      context.globalCompositeOperation = "source-in"
      context.fillStyle = root.foreground
      context.fillRect(0, 0, width, height)
    }
  }
}

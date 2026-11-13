import QtQuick
import "../settings"
import qs.Commons
import qs.Commons as Commons
import "Icons.js" as Icons

Item {
  id: root

  property string name: ""
  property color color: Commons.Color.foreground
  property color markColor: color
  property bool brand: false
  property bool filled: false
  property real iconSize: Style.font.icon
  property string fontFamily: MailStyle.family
  // Docs: strokeScale is measured against the 16-unit vector grid.
  property real strokeScale: 1.4

  readonly property bool drawsMark: brand && name === "gmail"
  readonly property string imageSource: drawsMark ? "" : Icons.source(name, color, filled)

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Image {
    anchors.fill: parent
    visible: root.imageSource !== ""
    source: root.imageSource
    sourceSize.width: Math.max(1, Math.ceil(root.iconSize * 2))
    sourceSize.height: Math.max(1, Math.ceil(root.iconSize * 2))
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
  }

  Canvas {
    id: mark
    visible: root.drawsMark
    anchors.fill: parent
    antialiasing: true

    onVisibleChanged: requestPaint()
    Connections {
      target: root
      function onColorChanged() { mark.requestPaint() }
      function onMarkColorChanged() { mark.requestPaint() }
      function onIconSizeChanged() { mark.requestPaint() }
      function onStrokeScaleChanged() { mark.requestPaint() }
    }

    onPaint: {
      var context = getContext("2d")
      context.reset()
      var scale = width / 16
      if (scale <= 0) return
      context.lineWidth = Math.max(1, root.strokeScale * scale)
      context.lineCap = "round"
      context.lineJoin = "round"

      context.strokeStyle = root.color
      context.beginPath()
      context.rect(1 * scale, 3 * scale, 14 * scale, 10 * scale)
      context.stroke()
      context.strokeStyle = root.markColor
      context.beginPath()
      context.moveTo(3.6 * scale, 13 * scale); context.lineTo(3.6 * scale, 5.6 * scale); context.lineTo(8 * scale, 9.3 * scale)
      context.lineTo(12.4 * scale, 5.6 * scale); context.lineTo(12.4 * scale, 13 * scale)
      context.stroke()
    }
  }
}

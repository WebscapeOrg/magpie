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
      var ctx = getContext("2d")
      ctx.reset()
      var s = width / 16
      if (s <= 0) return
      ctx.lineWidth = Math.max(1, root.strokeScale * s)
      ctx.lineCap = "round"
      ctx.lineJoin = "round"

      ctx.strokeStyle = root.color
      ctx.beginPath()
      ctx.rect(1 * s, 3 * s, 14 * s, 10 * s)
      ctx.stroke()
      ctx.strokeStyle = root.markColor
      ctx.beginPath()
      ctx.moveTo(3.6 * s, 13 * s); ctx.lineTo(3.6 * s, 5.6 * s); ctx.lineTo(8 * s, 9.3 * s)
      ctx.lineTo(12.4 * s, 5.6 * s); ctx.lineTo(12.4 * s, 13 * s)
      ctx.stroke()
    }
  }
}

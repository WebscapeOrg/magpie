import QtQuick
Text {
  id: root
  property bool marked: false
  required property color markerColor
  property var bands: []
  textFormat: Text.PlainText
  onLineLaidOut: function(line) {
    var next = line.number === 0 ? [] : bands.slice(0,line.number)
    var width = Math.min(line.implicitWidth,line.width)
    var x = line.x
    if (effectiveHorizontalAlignment === Text.AlignRight) x += line.width-width
    else if (effectiveHorizontalAlignment === Text.AlignHCenter) x += (line.width-width)/2
    var em = line.height*0.75
    var lead = em*[0.21,0.27,0.33][line.number%3]
    next.push({x:x-lead,y:line.y+line.height*0.05,width:width+lead+em*0.25,height:line.height*0.9})
    bands = next
  }
  onBandsChanged: marker.requestPaint()
  onMarkerColorChanged: marker.requestPaint()
  Canvas {
    id: marker
    z: -1
    x: -14
    width: root.width+28
    height: root.height
    visible: root.marked
    property url stroke: "../assets/marker-1.png"
    Component.onCompleted: loadImage(stroke)
    onImageLoaded: requestPaint()
    onVisibleChanged: if (visible) requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (!isImageLoaded(stroke)) return
      for (var i=0;i<Math.min(root.bands.length,root.maximumLineCount);i++) {
        var band=root.bands[i]
        ctx.drawImage(stroke,band.x+14,band.y,band.width,band.height)
      }
      ctx.globalCompositeOperation="source-in"
      ctx.fillStyle=root.markerColor
      ctx.fillRect(0,0,width,height)
    }
  }
}

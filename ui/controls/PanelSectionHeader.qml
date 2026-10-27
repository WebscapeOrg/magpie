import QtQuick
import qs.Ui
import "../settings"
import qs.Commons
import qs.Commons as Commons

Text {
  textFormat: Text.PlainText
  id: root

  property color foreground: Commons.Color.foreground
  property string fontFamily: MailStyle.family
  property real fontSize: MailStyle.caption

  color: MailStyle.muted(foreground, Commons.Color.background)
  font.family: fontFamily
  font.pixelSize: fontSize
  font.bold: true

  // Invariant: reserve font ascent overshoot so clipped lists do not cut off tall Nerd Font
  // outlines.
  topPadding: Math.ceil(fontSize * 0.15)
}

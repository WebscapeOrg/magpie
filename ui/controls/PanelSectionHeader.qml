import QtQuick
import qs.Ui
import "../settings"
import qs.Commons

Text {
  textFormat: Text.PlainText
  id: root

  property color foreground: Color.foreground
  property string fontFamily: MailStyle.family
  property real fontSize: MailStyle.caption

  color: MailStyle.muted(foreground, Color.background)
  font.family: fontFamily
  font.pixelSize: fontSize
  font.bold: true

  // Invariant: reserve font ascent overshoot so clipped lists do not cut off tall Nerd Font
  // outlines.
  topPadding: Math.ceil(fontSize * 0.15)
}

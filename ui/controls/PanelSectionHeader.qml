import QtQuick
import qs.Ui
import "../settings"
import qs.Commons

// Small-caps-style label that introduces a panel section ("DNS provider",
// "Wi-Fi networks", "Output device", "Paired devices"). Sits between a
// PanelSeparator and the content rows.
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

  // Glyphs can paint above the box Text reserves for them: JetBrainsMono Nerd
  // Font's outlines run 10% of the em past its own ascent, and a patched or
  // user-chosen family can be worse. That sliver is invisible in normal flow,
  // but a header sitting at the top of a clipping list — bluetooth's device
  // list, network's station list — loses it to the clip and renders beheaded.
  // Reserve the overshoot here so every panel is covered at once.
  topPadding: Math.ceil(fontSize * 0.15)
}

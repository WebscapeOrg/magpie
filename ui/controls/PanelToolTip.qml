import QtQuick
import qs.Ui
import "../settings"
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons

// Docs: panel-prefixed styling properties avoid collisions with ToolTip’s built-in background and
// font properties.
ToolTip {
  id: root

  property color panelForeground: Commons.Color.tooltip.text
  property color panelBackground: Commons.Color.tooltip.background
  property color panelBorder: Commons.Color.tooltip.border
  property string fontFamily: MailStyle.family
  property real fontSize: MailStyle.bodySmall
  property real maximumWidth: Infinity
  implicitWidth: Math.min(contentItem.implicitWidth, maximumWidth)

  readonly property var panelBorderSpec: Border.localOrSurfaceSpec("tooltip", "border", panelBorder, Commons.Color.tooltip.border, Style.normalBorderWidth)

  delay: 400
  padding: 0

  background: BorderSurface {
    color: root.panelBackground
    borderSpec: root.panelBorderSpec
    radius: Style.cornerRadius
  }

  contentItem: Text {

    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: root.text
    color: root.panelForeground
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    leftPadding: Border.left(root.panelBorderSpec) + Style.spacing.controlPaddingX
    rightPadding: Border.right(root.panelBorderSpec) + Style.spacing.controlPaddingX
    topPadding: Border.top(root.panelBorderSpec) + Style.spacing.controlPaddingY
    bottomPadding: Border.bottom(root.panelBorderSpec) + Style.spacing.controlPaddingY
  }
}

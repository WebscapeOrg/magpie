import QtQuick
import "../settings"
import qs.Commons
import qs.Ui
import "../providers/Registry.js" as Provider

Item {
  id: root

  required property string providerId
  required property string title
  required property string detail
  required property color textColor
  required property color dimColor
  required property string panelFontFamily

  signal websiteRequested()

  readonly property string website: Provider.webHomeUrl(providerId)
  readonly property bool linked: website !== ""
  implicitHeight: heroColumn.implicitHeight

  Column {
    id: heroColumn
    width: parent.width
    spacing: MailStyle.space(8)

    Text {
      width: parent.width
      text: root.title
      textFormat: Text.PlainText
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.heading
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      text: root.detail
      textFormat: Text.PlainText
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      wrapMode: Text.WordWrap
    }

    LinkLabel {
      text: "Open Gmail..."
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      tooltipText: "Open Gmail in your browser"
      onActivated: root.websiteRequested()
    }
  }
}

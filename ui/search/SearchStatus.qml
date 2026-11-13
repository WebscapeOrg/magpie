import QtQuick
import "../controls" as Widgets
import "../settings"
import "Presentation.js" as Presentation

Column {
  id: root

  required property var service
  required property color textColor
  required property color accentColor
  required property color dimColor
  required property string panelFontFamily

  readonly property var status: service && service.searchStatus ? service.searchStatus : ({})
  visible: Presentation.issue(status)
  height: visible ? implicitHeight : 0
  spacing: MailStyle.space(4)

  Text {
    objectName: "search-status-text"
    width: parent.width
    text: Presentation.issueText(root.status)
    textFormat: Text.PlainText
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    wrapMode: Text.Wrap
    Accessible.role: Accessible.StaticText
    Accessible.name: text
  }

  Flow {
    width: parent.width
    visible: root.status.canRetry === true
    spacing: MailStyle.space(6)

    TextMetrics {
      id: retryMetrics
      text: "Retry search"
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
    }

    Widgets.Button {
      id: retryButton
      objectName: "search-retry"
      visible: root.status.canRetry === true
      text: root.width > retryMetrics.width + MailStyle.space(28) ? "Retry search" : "Retry"
      tooltipText: "Retry search"
      Accessible.name: "Retry search"
      focusable: true
      foreground: root.textColor
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      fontSize: MailStyle.caption
      onClicked: root.service.retrySearch()
    }
  }
}

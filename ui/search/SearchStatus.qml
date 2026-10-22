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
  visible: Presentation.active(status)
  height: visible ? implicitHeight : 0
  spacing: MailStyle.space(4)

  Text {
    objectName: "search-status-text"
    width: parent.width
    text: String(root.status.text || "")
    textFormat: Text.PlainText
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    wrapMode: Text.Wrap
    Accessible.role: Accessible.StaticText
    Accessible.name: text
  }

  Text {
    objectName: "search-status-error"
    width: parent.width
    visible: text !== "" && text !== String(root.status.text || "")
    text: String(root.status.error || "")
    textFormat: Text.PlainText
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    wrapMode: Text.Wrap
    Accessible.role: Accessible.StaticText
    Accessible.name: text
  }

  Text {
    objectName: "search-status-scope"
    width: parent.width
    visible: text !== ""
    text: String(root.status.scope || "")
    textFormat: Text.PlainText
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.Wrap
    Accessible.role: Accessible.StaticText
    Accessible.name: text
  }

  Flow {
    width: parent.width
    visible: root.status.canStop === true || root.status.canRetry === true
    spacing: MailStyle.space(6)

    TextMetrics {
      id: stopMetrics
      text: "Stop search"
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
    }
    TextMetrics {
      id: retryMetrics
      text: "Retry Gmail search"
      font: stopMetrics.font
    }
    TextMetrics {
      id: retryShortMetrics
      text: "Retry search"
      font: stopMetrics.font
    }

    Widgets.Button {
      id: stopButton
      objectName: "search-stop"
      visible: root.status.canStop === true
      text: root.width > stopMetrics.width + MailStyle.space(28) ? "Stop search" : "Stop"
      tooltipText: "Stop search"
      Accessible.name: "Stop search"
      focusable: true
      foreground: root.textColor
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      fontSize: MailStyle.caption
      onClicked: root.service.stopSearch()
    }

    Widgets.Button {
      id: retryButton
      objectName: "search-retry"
      visible: root.status.canRetry === true
      text: root.width > retryMetrics.width + MailStyle.space(28) ? "Retry Gmail search"
        : root.width > retryShortMetrics.width + MailStyle.space(28) ? "Retry search" : "Retry"
      tooltipText: "Retry Gmail search"
      Accessible.name: "Retry Gmail search"
      focusable: true
      foreground: root.textColor
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      fontSize: MailStyle.caption
      onClicked: root.service.retrySearch()
    }
  }
}

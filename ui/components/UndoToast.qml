import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui

// A bundled row's Undo: "Archived 2 messages" (Q-020). Once Gmail already has the change, the same
// place says so and offers nothing.
Rectangle {
  id: root

  property string message: ""
  property bool canUndo: true
  required property color textColor
  required property color accentColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  signal undoRequested()

  readonly property real maximumRoom: parent ? parent.width - MailStyle.space(32) : 320
  implicitWidth: Math.min(maximumRoom, Math.ceil(metrics.advanceWidth) + (canUndo ? undoButton.implicitWidth + row.spacing : 0) + MailStyle.space(16))
  implicitHeight: Math.max(row.implicitHeight + MailStyle.space(12), MailStyle.space(42))
  width: implicitWidth
  radius: Style.cornerRadius
  color: Qt.rgba(popupBackgroundColor.r, popupBackgroundColor.g, popupBackgroundColor.b, 1)
  border.width: Style.normalBorderWidth
  border.color: popupBorderColor

  TextMetrics {
    id: metrics
    text: root.message
    font: label.font
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: MailStyle.space(8)
    anchors.rightMargin: MailStyle.space(8)
    spacing: MailStyle.space(12)

    Text {
      id: label
      objectName: "undo-toast-message"
      width: Math.max(0, row.width - (undoButton.visible ? undoButton.width + row.spacing : 0))
      anchors.verticalCenter: parent.verticalCenter
      text: root.message
      textFormat: Text.PlainText
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      wrapMode: Text.WordWrap
    }

    Widgets.Button {
      id: undoButton
      objectName: "undo-toast-button"
      visible: root.canUndo
      anchors.verticalCenter: parent.verticalCenter
      focusable: true
      text: "Undo  alt+z"
      foreground: root.accentColor
      accent: root.accentColor
      bordered: true
      fontFamily: root.panelFontFamily
      fontSize: MailStyle.bodySmall
      onClicked: root.undoRequested()
    }
  }
}

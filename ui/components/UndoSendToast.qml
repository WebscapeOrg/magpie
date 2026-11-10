import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui

Rectangle {
  id: root

  required property int secondsRemaining
  // How many sends are parked. Past one, the countdown is the newest's and
  // Undo says so.
  property int queuedCount: 1
  property bool awaitingConnection: false
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  signal undoRequested()

  implicitWidth: message.implicitWidth + undoButton.implicitWidth + content.spacing + MailStyle.space(16)
  implicitHeight: Math.max(content.implicitHeight + MailStyle.space(12), MailStyle.space(42))
  width: Math.min(implicitWidth, parent ? parent.width - MailStyle.space(32) : implicitWidth)
  radius: Style.cornerRadius
  color: Qt.rgba(popupBackgroundColor.r, popupBackgroundColor.g,
    popupBackgroundColor.b, 1)
  border.width: Style.normalBorderWidth
  border.color: popupBorderColor

  Row {
    id: content
    anchors.centerIn: parent
    width: root.width - MailStyle.space(16)
    spacing: MailStyle.space(12)

    Text {
      id: message
      objectName: "undo-send-message"
      width: Math.max(0, content.width - undoButton.implicitWidth - content.spacing)
      wrapMode: Text.WordWrap
      anchors.verticalCenter: parent.verticalCenter
      text: root.awaitingConnection ? "Saved. Will send when connected." : root.queuedCount > 1
        ? root.queuedCount + " queued \u00b7 newest in " + root.secondsRemaining + "s"
        : "Sending in " + root.secondsRemaining + "s"
      textFormat: Text.PlainText
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
    }

    Widgets.Button {
      id: undoButton
      objectName: "undo-send-button"
      focusable: true
      anchors.verticalCenter: parent.verticalCenter
      text: root.queuedCount > 1 ? "Undo last  alt+z" : "Undo  alt+z"
      foreground: root.accentColor
      accent: root.accentColor
      bordered: true
      fontFamily: root.panelFontFamily
      fontSize: MailStyle.bodySmall
      onClicked: root.undoRequested()
    }
  }
}

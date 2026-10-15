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
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  signal undoRequested()

  implicitWidth: content.implicitWidth + MailStyle.space(16)
  implicitHeight: Math.max(content.implicitHeight + MailStyle.space(12), MailStyle.space(42))
  radius: Style.cornerRadius
  color: Qt.rgba(popupBackgroundColor.r, popupBackgroundColor.g,
    popupBackgroundColor.b, 1)
  border.width: Style.normalBorderWidth
  border.color: popupBorderColor

  Row {
    id: content
    anchors.centerIn: parent
    spacing: MailStyle.space(12)

    Text {
      objectName: "undo-send-message"
      anchors.verticalCenter: parent.verticalCenter
      text: root.queuedCount > 1
        ? root.queuedCount + " queued \u00b7 newest in " + root.secondsRemaining + "s"
        : "Sending in " + root.secondsRemaining + "s"
      textFormat: Text.PlainText
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
    }

    Widgets.Button {
      objectName: "undo-send-button"
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

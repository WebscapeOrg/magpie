import QtQuick
import "../settings"
import qs.Commons
import qs.Ui
import "../components"
import "../message/Direction.js" as Direction

Column {
  id: root
  required property var messages
  required property color textColor
  required property color backgroundColor
  required property color accentColor
  required property color dimColor
  required property string panelFontFamily
  // Invariant: preview subjects use the same content-direction preference as the main window.
  property string contentDirection: Direction.MODE_DEFAULT
  // Invariant: names and dates keep Qt auto-direction unless the user explicitly overrides it.
  readonly property var textAlignment: alignmentFor(Direction.forced(root.contentDirection))

  function alignmentFor(direction) {
    if (!Direction.hasAnswer(direction)) return undefined
    return Direction.isRightToLeft(direction) ? Text.AlignRight : Text.AlignLeft
  }

  width: MailStyle.space(360)
  spacing: MailStyle.space(5)

  signal messageRequested(string accountId, string messageId)

  Text {
    text: "LATEST MAIL"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.bold: true
    textFormat: Text.PlainText
  }

  Repeater {
    model: root.messages
    delegate: Rectangle {
      id: mailRow
      required property var modelData
      width: root.width
      height: MailStyle.space(66)
      radius: Style.cornerRadius
      color: mailMouse.containsMouse
        ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent"

      Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: MailStyle.space(8)
        anchors.rightMargin: MailStyle.space(8)
        spacing: MailStyle.space(2)
        Text {
          width: parent.width
          text: mailRow.modelData.subject || "(no subject)"
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          font.bold: mailRow.modelData.unread === true
          elide: Text.ElideRight
          textFormat: Text.PlainText
          // Invariant: a Latin reply prefix must not determine an RTL subject's direction.
          horizontalAlignment: root.alignmentFor(Direction.forced(root.contentDirection)
            || String(mailRow.modelData.subjectDirection || ""))
        }
        Text {
          width: parent.width
          text: (mailRow.modelData.from ? mailRow.modelData.from.display : "")
            + "  ·  " + mailRow.modelData.sourceLabel
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText
          horizontalAlignment: root.textAlignment
        }
        Text {
          width: parent.width
          text: mailRow.modelData.receivedLabel || ""
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText
          horizontalAlignment: root.textAlignment
        }
      }
      MouseArea {
        id: mailMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.messageRequested(
          String(mailRow.modelData.accountId || ""), String(mailRow.modelData.id || ""))
      }
    }
  }

  Text {
    visible: root.messages.length === 0
    text: "No unread messages"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    textFormat: Text.PlainText
  }

}

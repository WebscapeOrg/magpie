import QtQuick
import "../settings"
import qs.Commons
import qs.Ui
import "../providers/Registry.js" as Provider

Column {
  id: root

  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily

  signal chosen(string providerId)

  spacing: MailStyle.space(16)

  Column {
    width: parent.width
    spacing: MailStyle.space(4)

    Text {
      width: parent.width
      text: "Add a mailbox"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.heading
      font.bold: true
    }

    Text {
      width: parent.width
      text: "Which kind?"
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  Column {
    width: parent.width
    spacing: MailStyle.space(8)

    Repeater {
      model: Provider.ids()

      Rectangle {
        id: card
        required property var modelData

        readonly property bool connectable: Provider.isConnectable(modelData)

        width: root.width
        implicitHeight: Math.max(cardText.implicitHeight, cardMark.height) + MailStyle.space(24)
        radius: Style.cornerRadius
        color: card.connectable && hover.hovered
          ? Style.hoverFillFor(root.textColor, root.accentColor)
          : Style.normalFillFor(root.textColor, root.accentColor)
        border.width: 1
        border.color: Style.hoverBorderFor(root.textColor, root.accentColor)
        opacity: card.connectable ? 1.0 : 0.55

        ProviderLogo {
          id: cardMark
          anchors.left: parent.left
          anchors.leftMargin: MailStyle.space(12)
          anchors.verticalCenter: parent.verticalCenter
          size: MailStyle.space(26)
          logo: Provider.mark(card.modelData)
          fallbackIcon: "unread"
          fallbackColor: root.textColor
        }

        Column {
          id: cardText
          anchors.left: cardMark.right
          anchors.leftMargin: MailStyle.space(12)
          anchors.right: parent.right
          anchors.rightMargin: MailStyle.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: MailStyle.space(3)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: Provider.badge(card.modelData)
            color: root.textColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.bodySmall
            font.bold: true
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: card.connectable
              ? Provider.summary(card.modelData)
              : Provider.unavailableReason(card.modelData)
            color: root.dimColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.caption
            wrapMode: Text.WordWrap
          }
        }

        HoverHandler {
          id: hover
          enabled: card.connectable
        }

        TapHandler {
          enabled: card.connectable
          onTapped: root.chosen(card.modelData)
        }
      }
    }
  }
}

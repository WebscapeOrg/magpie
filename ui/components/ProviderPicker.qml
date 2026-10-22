import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
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

      Widgets.Button {
        id: card
        required property var modelData

        readonly property bool connectable: Provider.isConnectable(modelData)

        width: root.width
        implicitHeight: Math.max(cardText.implicitHeight, cardMark.height) + MailStyle.space(24)
        focusable: true
        enabled: card.connectable
        bordered: true
        foreground: root.textColor
        accent: root.accentColor
        background: Style.normalFillFor(root.textColor, root.accentColor)
        Accessible.name: Provider.badge(card.modelData)
        Accessible.description: card.connectable ? Provider.summary(card.modelData)
          : Provider.unavailableReason(card.modelData)
        onClicked: root.chosen(card.modelData)
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

      }
    }
  }
}

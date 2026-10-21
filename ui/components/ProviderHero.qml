import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui
import "../providers/Registry.js" as Provider
import "../account/Model.js" as Model

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
  readonly property var parts: Model.splitBrand(title, Provider.badge(providerId))

  implicitHeight: Math.max(logo.height, heroText.implicitHeight)

  ProviderLogo {
    id: logo
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.topMargin: MailStyle.space(2)
    logo: Provider.logo(root.providerId)

    HoverHandler {
      id: logoHover
      enabled: root.linked
      cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
      enabled: root.linked
      onTapped: root.websiteRequested()
    }

    Widgets.PanelToolTip {
      text: "Open " + Provider.badge(root.providerId) + " in your browser"
      visible: logoHover.hovered
    }
  }

  Column {
    id: heroText
    anchors.left: logo.right
    anchors.leftMargin: MailStyle.space(14)
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: MailStyle.space(4)

    // Invariant: the sentence already contains the spaces around its linked brand word; Row spacing
    // would double them.
    Row {
      spacing: 0

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.parts.before !== ""
        text: root.parts.before
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.heading
        font.bold: true
      }

      LinkLabel {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.parts.brand !== "" && root.linked
        text: root.parts.brand
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.heading
        font.bold: true
        tooltipText: "Open " + Provider.badge(root.providerId) + " in your browser"
        onActivated: root.websiteRequested()
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.parts.brand !== "" && !root.linked
        text: root.parts.brand
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.heading
        font.bold: true
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.parts.after !== ""
        text: root.parts.after
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.heading
        font.bold: true
      }
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.detail
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      wrapMode: Text.WordWrap
    }
  }
}

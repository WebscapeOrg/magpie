import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui

Item {
  id: root

  required property color textColor
  required property color accentColor
  required property string panelFontFamily
  property bool serverSearching: false

  readonly property bool showServerLabel: width >= MailStyle.space(260)

  signal submitted(string query)
  signal cleared()

  readonly property bool fieldFocused: field.activeFocus
  // Invariant: window shortcuts own Escape; a focused-item Keys handler would never receive it.
  readonly property string queryText: field.text

  implicitHeight: field.implicitHeight

  function focusField() {
    field.forceActiveFocus()
    field.selectAll()
  }

  function clear() {
    field.text = ""
    root.cleared()
  }

  function setQuery(text) {
    field.text = String(text || "")
  }

  Widgets.TextField {
    id: field
    anchors.fill: parent
    foreground: root.textColor
    accent: root.accentColor
    placeholderText: "Search..."
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    rightPadding: horizontalPadding + MailStyle.space(22)
      + (root.serverSearching ? serverState.width + MailStyle.space(7) : 0)
    onAccepted: root.submitted(text.trim())

    background: Rectangle {
      radius: Style.cornerRadius
      color: field.activeFocus || field.hovered
        ? Style.hoverFillFor(root.textColor, root.accentColor)
        : Style.normalFillFor(root.textColor, root.accentColor)
      border.width: 1
      border.color: field.activeFocus
        ? Style.hoverBorderFor(root.textColor, root.accentColor)
        : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.12)
    }
  }

  Item {
    id: serverState
    anchors.right: clearButton.left
    anchors.rightMargin: MailStyle.space(3)
    anchors.verticalCenter: parent.verticalCenter
    visible: root.serverSearching
    width: visible ? serverStateRow.implicitWidth : 0
    height: MailStyle.space(22)

    Row {
      id: serverStateRow
      anchors.centerIn: parent
      spacing: root.showServerLabel ? MailStyle.space(5) : 0

      ActionIcon {
        anchors.verticalCenter: parent.verticalCenter
        name: "refresh"
        iconSize: Style.font.iconSmall
        color: root.accentColor

        RotationAnimator on rotation {
          from: 0
          to: 360
          duration: 900
          loops: Animation.Infinite
          running: root.serverSearching
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showServerLabel
        text: "Searching server"
        textFormat: Text.PlainText
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }
    }
  }

  Widgets.PanelActionButton {
    id: clearButton
    anchors.right: parent.right
    anchors.rightMargin: MailStyle.space(4)
    anchors.verticalCenter: parent.verticalCenter
    visible: field.text !== ""
    tooltipText: "Clear search · esc"
    foreground: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
    hoverColor: root.textColor
    fontSize: MailStyle.body
    onClicked: root.clear()
    Accessible.role: Accessible.Button
    Accessible.name: "Clear search"
    ActionIcon {
      anchors.centerIn: parent
      name: "close"
      color: clearButton._hot ? clearButton.hoverColor : clearButton.foreground
      iconSize: clearButton.fontSize
    }
  }
}

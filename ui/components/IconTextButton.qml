import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Rectangle {
  id: root

  property string iconName: ""
  property string text: ""
  property string tooltipText: ""
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property bool bordered: true
  property bool outline: false
  property bool ghost: false
  property color hoverColor: foreground
  property real iconSize: ghost ? Style.font.icon : Style.font.iconSmall
  property bool selected: false
  property string fontFamily: MailStyle.family
  property real fontSize: MailStyle.bodySmall

  signal clicked()

  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: text || tooltipText
  Accessible.onPressAction: if (root.enabled) root.clicked()
  function acceptsActivation(event) {
    return root.enabled && root.activeFocus
      && (event.modifiers & ~Qt.KeypadModifier) === Qt.NoModifier
      && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)
  }
  Keys.onShortcutOverride: function(event) {
    if (root.acceptsActivation(event)) event.accepted = true
  }
  Keys.onPressed: function(event) {
    if (!root.acceptsActivation(event)) return
    event.accepted = true
    root.clicked()
  }

  readonly property bool hot: (mouse.containsMouse || activeFocus) && enabled

  implicitWidth: row.implicitWidth + Style.spacing.controlPaddingX * 2
  implicitHeight: ghost
    ? Math.max(MailStyle.space(24), iconSize + Style.spacing.sm * 2)
    : Style.spacing.controlHeight
  radius: Style.cornerRadius
  opacity: enabled ? 1.0 : 0.4
  color: mouse.pressed ? Style.pressedFillFor(root.foreground, root.accent)
    : root.activeFocus ? Style.focusFillFor(root.foreground, root.accent)
    : (root.selected ? Style.selectedFillFor(root.foreground, root.accent)
      : (hot ? Style.hoverFillFor(root.foreground, root.accent)
        : (bordered && !ghost && !outline
          ? Style.normalFillFor(root.foreground, root.accent) : "transparent")))
  border.width: (ghost ? root.selected : (bordered || hot || root.selected)) ? Style.normalBorderWidth : 0
  border.color: hot || root.selected
    ? Style.hoverBorderFor(root.foreground, root.accent)
    : Style.normalBorderFor(root.foreground, root.accent)

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.spacing.md

    ActionIcon {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.iconName !== ""
      name: root.iconName
      iconSize: root.iconSize
      color: root.ghost && (root.hot || root.selected) ? root.hoverColor : root.foreground
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.text !== ""
      // Invariant: labels can contain server-controlled host names and must remain plain text.
      textFormat: Text.PlainText
      text: root.text
      color: root.ghost && (root.hot || root.selected) ? root.hoverColor : root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    onClicked: root.clicked()
  }

  Widgets.PanelToolTip {
    visible: root.tooltipText !== "" && (mouse.containsMouse || root.activeFocus)
    text: root.tooltipText
    fontFamily: root.fontFamily
  }
}

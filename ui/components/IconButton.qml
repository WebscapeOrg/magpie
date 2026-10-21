import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  property string iconName: ""
  property string tooltipText: ""
  property color foreground: Commons.Color.foreground
  property color hoverColor: foreground
  property color accent: Commons.Color.accent
  property bool filled: false
  property bool hasCursor: false
  property bool selected: false
  property bool busy: false
  property bool attention: false
  property real iconSize: Style.font.icon
  property real size: Math.max(MailStyle.space(24), iconSize + Style.spacing.sm * 2)
  property real visualInset: MailStyle.space(2)
  property string fontFamily: MailStyle.family

  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: tooltipText
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
  signal clicked()

  readonly property bool hot: (mouse.containsMouse || hasCursor || activeFocus) && enabled

  implicitWidth: size
  implicitHeight: size
  width: size
  height: size
  opacity: enabled || busy ? 1.0 : 0.4

  Rectangle {
    id: halo
    anchors.fill: parent
    anchors.margins: root.visualInset - MailStyle.space(1)
    radius: Style.cornerRadius + MailStyle.space(1)
    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
    border.width: Style.normalBorderWidth
    border.color: root.accent
    visible: root.attention
    opacity: 0

    SequentialAnimation on opacity {
      running: root.attention
      loops: Animation.Infinite
      NumberAnimation { from: 0.15; to: 1.0; duration: 900; easing.type: Easing.InOutSine }
      NumberAnimation { from: 1.0; to: 0.15; duration: 900; easing.type: Easing.InOutSine }
      onRunningChanged: if (!running) halo.opacity = 0
    }
  }

  Rectangle {
    anchors.fill: parent
    anchors.margins: root.visualInset
    radius: Style.cornerRadius
    color: mouse.pressed ? Style.pressedFillFor(root.foreground, root.accent)
      : (root.selected ? Style.selectedFillFor(root.foreground, root.accent)
        : (root.hot ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"))
  }

  ActionIcon {
    id: glyph
    anchors.centerIn: parent
    name: root.iconName
    iconSize: root.iconSize
    color: root.hot || root.selected ? root.hoverColor : root.foreground
    filled: root.filled

    RotationAnimation on rotation {
      running: root.busy
      loops: Animation.Infinite
      from: 0
      to: 360
      duration: 1000
      onRunningChanged: if (!running) glyph.rotation = 0
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

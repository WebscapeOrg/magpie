import QtQuick
import "." as Widgets
import qs.Ui
import "../settings"
import qs.Commons
import qs.Commons as Commons

BorderSurface {
  id: root

  property string iconText: ""
  property string tooltipText: ""
  property color foreground: Commons.Color.foreground
  property color hoverColor: foreground
  property string fontFamily: MailStyle.family
  property real fontSize: Style.font.icon
  property real size: Math.max(MailStyle.space(22), fontSize + Style.spacing.sm * 2)

  property bool focusable: false
  property bool hasCursor: false
  property bool bordered: false

  signal clicked()
  signal hovered(bool isHovered)

  activeFocusOnTab: focusable
  Accessible.role: Accessible.Button
  Accessible.name: tooltipText
  Accessible.onPressAction: if (root.enabled) root.clicked()
  function acceptsActivation(event) {
    return root.enabled && root.activeFocus && root.focusable
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

  implicitWidth: size
  implicitHeight: size
  radius: Style.cornerRadius

  readonly property bool _showFocusRing: focusable && activeFocus
  readonly property bool _hot: (mouse.containsMouse || root.hasCursor) && root.enabled
  readonly property var _borderSpec: _showFocusRing
    ? Border.controlSpec("focus", hoverColor, hoverColor)
    : (_hot && bordered
      ? Border.controlSpec("hover-cursor", hoverColor, hoverColor)
      : (bordered ? Border.controlSpec("normal", foreground, Commons.Color.accent) : Border.none()))

  color: _showFocusRing
    ? Style.focusFillFor(hoverColor, hoverColor)
    : (_hot
      ? Style.hoverFillFor(hoverColor, hoverColor)
      : "transparent")
  borderSpec: _borderSpec

  Behavior on color { ColorAnimation { duration: 60 } }

  Text {

    textFormat: Text.PlainText
    anchors.centerIn: parent
    text: root.iconText
    color: root.enabled
      ? (root._hot ? root.hoverColor : root.foreground)
      : MailStyle.muted(root.foreground, Commons.Color.background)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    enabled: root.enabled
    onContainsMouseChanged: root.hovered(containsMouse)
    onClicked: {
      if (root.focusable) root.forceActiveFocus()
      root.clicked()
    }
  }

  Widgets.PanelToolTip {
    visible: root.tooltipText !== "" && (mouse.containsMouse || root.activeFocus)
    text: root.tooltipText
    fontFamily: root.fontFamily
  }
}

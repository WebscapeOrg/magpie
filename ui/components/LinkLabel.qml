import QtQuick
import "../controls" as Widgets
import qs.Commons

// Invariant: real links stay underlined and use a pointing cursor; color alone must not convey the
// affordance.
Text {
  id: root

  property string tooltipText: ""

  signal activated()

  font.underline: true

  HoverHandler {
    id: hover
    cursorShape: Qt.PointingHandCursor
  }

  Widgets.Button {
    anchors.fill: parent
    focusable: true
    foreground: root.color
    color: "transparent"
    borderSpec: activeFocus ? Border.controlSpec("focus", root.color, root.color) : Border.none()
    Accessible.role: Accessible.Link
    Accessible.name: root.text
    onClicked: root.activated()
  }

  Widgets.PanelToolTip {
    text: root.tooltipText
    visible: hover.hovered && root.tooltipText !== ""
  }
}

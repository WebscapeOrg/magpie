import QtQuick
import "../controls" as Widgets
import qs.Commons
import qs.Ui

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

  TapHandler {
    onTapped: root.activated()
  }

  Widgets.PanelToolTip {
    text: root.tooltipText
    visible: hover.hovered && root.tooltipText !== ""
  }
}

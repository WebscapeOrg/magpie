import QtQuick
import "../settings"
import qs.Commons
import qs.Ui

Item {
  id: root

  required property color textColor
  required property color dimColor
  required property string panelFontFamily
  property string label: "Back"

  signal activated()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IconTextButton {
    id: button
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    iconName: "back"
    text: root.label
    bordered: true
    foreground: root.dimColor
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.bodySmall
    tooltipText: root.label + " · esc"
    onClicked: root.activated()
  }
}

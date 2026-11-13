import QtQuick
import "../controls" as Widgets
import "../settings"
import QtQuick.Controls
import qs.Commons
import qs.Ui

Rectangle {
  id: root

  property string text: ""
  property string actionLabel: ""
  property bool busy: false
  property string busyLabel: ""
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily

  signal activated()

  implicitHeight: MailStyle.space(30)
  radius: Style.cornerRadius
  color: Style.normalFillFor(root.textColor, root.accentColor)
  border.width: 1
  border.color: Style.normalBorderFor(root.textColor, root.accentColor)

  Text {
    anchors.left: parent.left
    anchors.leftMargin: MailStyle.space(10)
    anchors.right: action.visible ? action.left : parent.right
    anchors.rightMargin: MailStyle.space(6)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.text
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    elide: Text.ElideRight
  }

  Widgets.Button {
    id: action
    visible: root.actionLabel !== ""
    enabled: !root.busy
    anchors.right: parent.right
    anchors.rightMargin: MailStyle.space(8)
    anchors.verticalCenter: parent.verticalCenter
    width: implicitWidth
    height: implicitHeight
    text: root.busy && root.busyLabel !== "" ? root.busyLabel : root.actionLabel
    foreground: root.textColor
    bordered: false
    fontSize: MailStyle.caption
    horizontalPadding: MailStyle.space(8)
    verticalPadding: MailStyle.space(2)
    focusable: true
    onClicked: root.activated()
  }
}

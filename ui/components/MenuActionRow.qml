import QtQuick
import "../settings"
import qs.Commons
import qs.Ui

Rectangle {
  id: root

  required property string text
  required property color textColor
  required property string panelFontFamily
  property color tone: textColor
  property var collection: []
  property int cursorIndex: -1
  readonly property bool selected: collection.indexOf(root) === cursorIndex

  signal activated()

  activeFocusOnTab: true
  Accessible.role: Accessible.MenuItem
  Accessible.name: text
  Accessible.onPressAction: if (root.enabled) root.activated()
  Keys.onReturnPressed: if (root.enabled) root.activated()
  Keys.onSpacePressed: if (root.enabled) root.activated()
  implicitHeight: Math.max(Style.spacing.popupRowHeight, label.implicitHeight + MailStyle.space(12))
  radius: Style.cornerRadius
  opacity: enabled ? 1.0 : 0.4
  color: hover.hovered || selected || activeFocus
    ? Qt.rgba(textColor.r, textColor.g, textColor.b, 0.08)
    : "transparent"

  Text {
    id: label
    anchors.left: parent.left
    anchors.leftMargin: MailStyle.space(9)
    anchors.right: parent.right
    anchors.rightMargin: MailStyle.space(9)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.text
    color: root.tone
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    elide: Text.ElideRight
  }

  HoverHandler { id: hover }
  // Invariant: take the exclusive pointer grab on press so an underlying message row cannot consume
  // the release.
  TapHandler {
    gesturePolicy: TapHandler.ReleaseWithinBounds
    onTapped: root.activated()
  }
}

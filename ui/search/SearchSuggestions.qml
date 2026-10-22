pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import "../settings"
import qs.Commons

Rectangle {
  id: root
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property color backgroundColor
  required property color borderColor
  required property string panelFontFamily
  property var suggestions: []
  property int selectedIndex: -1
  property real maximumHeight: MailStyle.space(300)
  signal chosen(int index)

  objectName: "search-suggestions"
  color: backgroundColor
  radius: Style.cornerRadius
  border.color: borderColor
  border.width: 1
  implicitHeight: Math.min(maximumHeight, choices.contentHeight + hint.implicitHeight + MailStyle.space(20))
  height: implicitHeight

  ListView {
    id: choices
    objectName: "search-suggestion-list"
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: hint.top
    anchors.margins: MailStyle.space(6)
    clip: true
    model: root.suggestions
    currentIndex: root.selectedIndex
    Accessible.role: Accessible.List
    Accessible.name: "Search suggestions"
    onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex,ListView.Contain)
    QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
    delegate: QQC.ItemDelegate {
      id: suggestionRow
      required property var modelData
      required property int index
      objectName: "search-suggestion-" + index
      width: choices.width
      focusPolicy: Qt.NoFocus
      highlighted: index === root.selectedIndex
      Accessible.name: modelData.label + ". " + modelData.detail
      Accessible.role: Accessible.ListItem
      Accessible.selected: highlighted
      onClicked: root.chosen(index)
      padding: MailStyle.space(8)
      background: Rectangle {
        radius: Style.cornerRadius
        color: suggestionRow.highlighted ? Style.selectedFillFor(root.textColor,root.accentColor)
          : suggestionRow.hovered ? Style.hoverFillFor(root.textColor,root.accentColor) : "transparent"
        border.width: suggestionRow.highlighted ? 1 : 0
        border.color: root.accentColor
      }
      contentItem: Column {
        spacing: MailStyle.space(2)
        Text {
          width: parent.width
          text: suggestionRow.modelData.label
          textFormat: Text.PlainText
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          wrapMode: Text.Wrap
        }
        Text {
          width: parent.width
          text: suggestionRow.modelData.detail
          textFormat: Text.PlainText
          color: suggestionRow.highlighted ? root.textColor : root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          wrapMode: Text.Wrap
        }
      }
    }
  }
  Text {
    id: hint
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: MailStyle.space(8)
    text: root.selectedIndex >= 0 ? "Tab or Enter completes · Esc dismisses" : "↓ selects · Tab completes · Enter searches"
    textFormat: Text.PlainText
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.Wrap
  }
}

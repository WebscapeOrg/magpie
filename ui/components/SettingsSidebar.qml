import QtQuick
import "../settings"
import qs.Commons
import qs.Ui

Column {
  id: root

  property var sections: []
  property string activeKey: ""
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily

  signal sectionRequested(string key)

  spacing: MailStyle.space(2)

  Repeater {
    model: root.sections

    Rectangle {
      id: entry
      required property var modelData

      readonly property string key: String(modelData.key || "")
      readonly property bool selected: entry.key !== "" && entry.key === root.activeKey

      objectName: "settings-section-" + entry.key
      width: root.width
      implicitHeight: MailStyle.space(28)
      radius: Style.cornerRadius
      color: entry.selected
        ? Style.selectedFillFor(root.textColor, root.accentColor)
        : (hover.hovered ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent")

      Text {
        anchors.left: parent.left
        anchors.leftMargin: MailStyle.space(10)
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(6)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: String(entry.modelData.title || "")
        color: entry.selected ? root.textColor : root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        // Invariant: selected sections use font weight as well as theme-dependent fill.
        font.bold: entry.selected
        elide: Text.ElideRight
      }

      HoverHandler { id: hover }
      TapHandler { onTapped: root.sectionRequested(entry.key) }
    }
  }
}

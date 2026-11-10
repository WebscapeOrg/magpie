import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import "../agent/Agent.js" as Agent

// Invariant: suggestions only prefill a human-submitted event; all model-supplied strings remain
// plain text.
Rectangle {
  id: root

  property var suggestions: []

  required property color textColor
  required property color accentColor
  required property color dimColor
  required property color dimmerColor
  required property string panelFontFamily

  signal addRequested(var suggestion)
  signal dismissRequested(string key)

  readonly property var rows: Array.isArray(suggestions) ? suggestions : []
  property bool expanded: false
  readonly property string lookId: rows.length > 0 ? String(rows[0].jobId || "") : ""
  onLookIdChanged: expanded = false
  visible: rows.length > 0
  implicitHeight: visible ? column.implicitHeight + MailStyle.space(24) : 0
  height: implicitHeight
  radius: Style.cornerRadius
  color: Style.hoverFillFor(root.textColor, root.accentColor)
  border.width: 1
  border.color: root.dimmerColor

  Column {
    id: column
    x: MailStyle.space(14)
    y: MailStyle.space(12)
    width: parent.width - MailStyle.space(28)
    spacing: MailStyle.space(8)

    Widgets.Button {
      objectName: "suggestionHeader"
      focusable: true
      foreground: root.textColor
      accent: root.accentColor
      Accessible.name: heading.text
      Accessible.description: root.expanded ? "Expanded" : "Collapsed"
      onClicked: root.expanded = !root.expanded
      width: parent.width
      implicitHeight: Math.max(heading.implicitHeight, Style.font.icon)

      Row {
        id: headerContent
        anchors.left: parent.left
        anchors.right: fold.left
        anchors.rightMargin: MailStyle.space(6)
        spacing: MailStyle.space(6)
        anchors.verticalCenter: parent.verticalCenter
        ActionIcon {
          id: calendarIcon
          name: "calendar"
          iconSize: Style.font.icon
          color: root.accentColor
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          id: heading
          objectName: "suggestionHeading"
          width: Math.max(0, headerContent.width - calendarIcon.width - headerContent.spacing)
          text: root.rows.length === 1 ? "The agent found an event in this message"
            : "The agent found " + root.rows.length + " events in this message"
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          anchors.verticalCenter: parent.verticalCenter
        }
      }
      ActionIcon {
        id: fold
        objectName: "suggestionFold"
        name: root.expanded ? "chevronDown" : "chevronRight"
        iconSize: Style.font.icon
        color: root.dimColor
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Repeater {
      model: root.expanded ? root.rows : []

      Column {
        required property var modelData
        objectName: "suggestion"
        width: column.width
        spacing: MailStyle.space(2)

        Text {
          objectName: "suggestionTitle"
          width: parent.width
          text: modelData.title
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.body
          font.weight: Font.DemiBold
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
        Text {
          objectName: "suggestionWhen"
          width: parent.width
          text: Agent.suggestionWhen(modelData, Date.now())
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
        Text {
          objectName: "suggestionLocation"
          width: parent.width
          visible: String(modelData.location || "") !== ""
          text: modelData.location
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
        Text {
          objectName: "suggestionNotes"
          width: parent.width
          visible: String(modelData.notes || "") !== ""
          text: modelData.notes
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
        Flow {
          width: parent.width
          spacing: MailStyle.space(8)
          topPadding: MailStyle.space(2)
          IconTextButton {
            objectName: "suggestionAdd"
            iconName: "plus"
            text: "Review in Skylark..."
            foreground: root.textColor
            accent: root.accentColor
            fontFamily: root.panelFontFamily
            fontSize: MailStyle.caption
            onClicked: root.addRequested(modelData)
          }
          IconTextButton {
            objectName: "suggestionDismiss"
            iconName: "close"
            text: "Dismiss"
            foreground: root.dimColor
            accent: root.accentColor
            fontFamily: root.panelFontFamily
            fontSize: MailStyle.caption
            onClicked: root.dismissRequested(String(modelData.key || ""))
          }
        }
      }
    }
  }
}

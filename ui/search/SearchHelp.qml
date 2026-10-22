pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import "../controls" as Widgets
import "../settings"
import qs.Commons

QQC.Popup {
  id: root
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property color backgroundColor
  required property color borderColor
  required property string panelFontFamily
  property var operators: []
  property real maximumHeight: MailStyle.space(600)
  signal exampleChosen(string example)
  signal dismissed()
  objectName: "search-help"
  modal: false
  focus: true
  closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
  padding: MailStyle.space(12)
  implicitHeight: Math.min(maximumHeight,helpColumn.implicitHeight + topPadding + bottomPadding)
  onClosed: root.dismissed()
  onOpened: { helpFlick.contentY = 0; closeButton.forceActiveFocus() }
  function reveal(item) {
    var top = item.mapToItem(helpColumn,0,0).y
    var bottom = top + item.height
    if (top < helpFlick.contentY) helpFlick.contentY = top
    else if (bottom > helpFlick.contentY + helpFlick.height)
      helpFlick.contentY = Math.min(helpFlick.contentHeight - helpFlick.height,bottom - helpFlick.height)
  }
  background: Rectangle {
    color: root.backgroundColor
    radius: Style.cornerRadius
    border.width: 1
    border.color: root.borderColor
  }
  contentItem: Flickable {
    id: helpFlick
    clip: true
    contentHeight: helpColumn.implicitHeight
    boundsBehavior: Flickable.StopAtBounds
    QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
    Column {
      id: helpColumn
      width: parent.width
      spacing: MailStyle.space(10)
      Row {
        width: parent.width
        spacing: MailStyle.space(8)
        Text {
          width: parent.width - closeButton.width - parent.spacing
          text: "Search Gmail"
          textFormat: Text.PlainText
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.subtitle
          wrapMode: Text.Wrap
        }
        Widgets.Button {
          id: closeButton
          objectName: "search-help-close"
          text: "Close"
          focusable: true
          foreground: root.textColor
          accent: root.accentColor
          fontFamily: root.panelFontFamily
          fontSize: MailStyle.caption
          onActiveFocusChanged: if (activeFocus) root.reveal(closeButton)
          onClicked: root.close()
        }
      }
      Text {
        width: parent.width
        text: "Type words or combine filters, then press Enter. Choose an example below to insert it without searching."
        textFormat: Text.PlainText
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        wrapMode: Text.Wrap
      }
      Repeater {
        model: root.operators
        Column {
          id: operatorRow
          required property var modelData
          required property int index
          width: helpColumn.width
          spacing: MailStyle.space(3)
          Text {
            width: parent.width
            visible: modelData.primary === false && index > 0 && root.operators[index - 1].primary !== false
            text: "Relative dates"
            textFormat: Text.PlainText
            color: root.textColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.bodySmall
            font.bold: true
          }
          QQC.ItemDelegate {
            id: exampleButton
            objectName: "search-help-" + operatorRow.modelData.operator
            width: parent.width
            padding: MailStyle.space(6)
            focusPolicy: Qt.StrongFocus
            Accessible.name: "Insert " + operatorRow.modelData.example
            onActiveFocusChanged: if (activeFocus) root.reveal(exampleButton)
            onClicked: root.exampleChosen(String(operatorRow.modelData.example || ""))
            background: Rectangle {
              radius: Style.cornerRadius
              color: exampleButton.activeFocus ? Style.selectedFillFor(root.textColor,root.accentColor)
                : exampleButton.hovered ? Style.hoverFillFor(root.textColor,root.accentColor) : "transparent"
              border.width: exampleButton.activeFocus ? 1 : 0
              border.color: root.accentColor
            }
            contentItem: Column {
              spacing: MailStyle.space(2)
              Text {
                width: parent.width
                text: operatorRow.modelData.example
                textFormat: Text.PlainText
                color: root.textColor
                font.family: root.panelFontFamily
                font.pixelSize: MailStyle.bodySmall
                wrapMode: Text.Wrap
              }
              Text {
                width: parent.width
                text: operatorRow.modelData.description
                textFormat: Text.PlainText
                color: exampleButton.activeFocus ? root.textColor : root.dimColor
                font.family: root.panelFontFamily
                font.pixelSize: MailStyle.caption
                wrapMode: Text.Wrap
              }
            }
          }
        }
      }
      Text {
        width: parent.width
        text: 'Use quotes for phrases or labels with spaces: subject:"project review". A minus excludes a filter: -from:alex@example.com. Combine filters with spaces or AND; use OR and parentheses for alternatives: (from:alex@example.com OR from:sam@example.com) has:attachment.'
        textFormat: Text.PlainText
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        wrapMode: Text.Wrap
      }
      Text {
        width: parent.width
        text: "Dates use midnight PST (UTC−08:00). In saved mail, relative dates use 24-hour days, 30-day months and 365-day years. Gmail checks the submitted search online for its exact results."
        textFormat: Text.PlainText
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.Wrap
      }
      Text {
        width: parent.width
        text: "Other Gmail syntax is searched online. Gmail’s website can also match aliases and whole conversations, so its results may differ."
        textFormat: Text.PlainText
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.Wrap
      }
    }
  }
}

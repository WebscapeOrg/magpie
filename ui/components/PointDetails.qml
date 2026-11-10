import QtQuick
import QtQuick.Controls as QQC
import "../controls" as Widgets
import "../settings"
import "../inbox/PointDetails.js" as Details

Item {
  id: root
  required property color textColor
  required property color dimColor
  property color accentColor: textColor
  required property color backgroundColor
  required property color borderColor
  required property string panelFontFamily
  property string sender: ""
  property var overview: ({})
  readonly property bool opened: popup.opened
  anchors.fill: parent

  function openFor(row, value) {
    sender = String(row && row.from && (row.from.display || row.from.name || row.from.email) || "")
    overview = JSON.parse(JSON.stringify(value || {}))
    popup.open()
  }
  function close() { popup.close() }

  QQC.Popup {
    id: popup
    objectName: "point-details"
    width: Math.max(0, Math.min(root.width - MailStyle.space(24), MailStyle.space(380)))
    height: Math.max(0, Math.min(root.height - MailStyle.space(24), content.implicitHeight + 2 * padding))
    x: (root.width - width) / 2
    y: (root.height - height) / 2
    padding: MailStyle.space(18)
    modal: true
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    onOpened: { words.contentY = 0; done.forceActiveFocus() }
    onClosed: { root.overview = ({}); root.sender = "" }
    background: Rectangle { color: root.backgroundColor; border.color: root.borderColor; border.width: 1; radius: MailStyle.space(10) }
    contentItem: Item {
      id: content
      implicitHeight: column.implicitHeight + MailStyle.space(18) + done.implicitHeight
      Keys.onPressed: function(event) {
        var step = event.key === Qt.Key_Down ? MailStyle.body * 2 : event.key === Qt.Key_Up ? -MailStyle.body * 2 : 0
        if (step) { words.contentY = Math.max(0, Math.min(words.contentHeight - words.height, words.contentY + step)); event.accepted = true }
      }
      Flickable {
        id: words
        objectName: "point-details-scroll"
        WheelScroller { view: words }
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        anchors { top: parent.top; left: parent.left; right: parent.right; bottom: done.top; bottomMargin: MailStyle.space(18) }
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
          id: column
          width: words.width
          spacing: MailStyle.space(18)
          Text { width: parent.width; text: "Point details"; textFormat: Text.PlainText; font.family: root.panelFontFamily; font.pixelSize: MailStyle.body; font.bold: true; color: root.textColor; wrapMode: Text.WordWrap }
          Text { width: parent.width; text: root.sender; visible: text !== ""; textFormat: Text.PlainText; font.family: root.panelFontFamily; font.pixelSize: MailStyle.bodySmall; color: root.textColor; wrapMode: Text.Wrap }
          Repeater {
            model: Details.rows(root.overview)
            Column {
              required property var modelData
              width: column.width
              spacing: MailStyle.space(4)
              Accessible.role: Accessible.StaticText
              Accessible.name: modelData.title + ": " + modelData.value
              Text { width: parent.width; text: modelData.title; textFormat: Text.PlainText; font.family: root.panelFontFamily; font.pixelSize: MailStyle.bodySmall; color: root.dimColor; wrapMode: Text.WordWrap }
              Text { width: parent.width; text: modelData.value; textFormat: Text.PlainText; font.family: root.panelFontFamily; font.pixelSize: MailStyle.body; color: root.textColor; wrapMode: Text.WordWrap }
            }
          }
          Text { width: parent.width; text: Details.note(root.overview); visible: text !== ""; textFormat: Text.PlainText; font.family: root.panelFontFamily; font.pixelSize: MailStyle.bodySmall; color: root.dimColor; wrapMode: Text.WordWrap }
        }
      }
      Widgets.Button {
        id: done
        objectName: "point-details-done"
        anchors { bottom: parent.bottom; right: parent.right }
        text: "Done"
        foreground: root.textColor
        accent: root.accentColor
        fontFamily: root.panelFontFamily
        fontSize: MailStyle.bodySmall
        focusable: true
        onClicked: popup.close()
      }
    }
  }
}

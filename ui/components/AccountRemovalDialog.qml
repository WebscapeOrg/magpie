import QtQuick
import "../controls" as Widgets
import "../settings"
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

Item {
  id: root

  required property color textColor
  required property color dimColor
  required property color dangerColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily
  property var request: null
  readonly property bool opened: dialog.opened

  signal confirmed(var request)

  anchors.fill: parent
  z: 80

  function openFor(value) {
    request = value
    if (request) dialog.open()
  }

  function close() { dialog.close() }

  QQC.Popup {
    id: dialog
    anchors.centerIn: parent
    width: Math.min(MailStyle.space(360), parent.width - MailStyle.space(32))
    padding: MailStyle.space(18)
    modal: true
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape
    onClosed: root.request = null
    onOpened: cancelButton.forceActiveFocus()
    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }
    contentItem: Column {
      spacing: MailStyle.space(14)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "Remove " + String(root.request ? root.request.email : "") + "?"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.heading
        font.bold: true
        wrapMode: Text.Wrap
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "This mailbox will be removed from Magpie."
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        wrapMode: Text.Wrap
      }
      Row {
        anchors.right: parent.right
        spacing: MailStyle.space(8)
        Widgets.Button {
          id: cancelButton
          focusable: true
          KeyNavigation.tab: removeButton
          KeyNavigation.backtab: removeButton
          text: "Cancel"
          foreground: root.textColor
          bordered: false
          onClicked: dialog.close()
        }
        Widgets.Button {
          id: removeButton
          focusable: true
          KeyNavigation.tab: cancelButton
          KeyNavigation.backtab: cancelButton
          text: "Remove"
          foreground: root.dangerColor
          bordered: false
          onClicked: {
            var value = root.request
            dialog.close()
            if (value) root.confirmed(value)
          }
        }
      }
    }
  }
}

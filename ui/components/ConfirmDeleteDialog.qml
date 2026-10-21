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

  readonly property var choices: request && Array.isArray(request.choices) && request.choices.length > 0
    ? request.choices : [{ value: "", label: "Delete" }]

  anchors.fill: parent
  z: 80

  function openFor(value) {
    request = value
    if (request) dialog.open()
  }

  function close() { dialog.close() }
  function confirm(choice) {
    var value = dialog.opened ? request : null
    dialog.close()
    if (!value) return
    var answered = {}
    for (var key in value) answered[key] = value[key]
    answered.choice = choice === undefined ? String(root.choices[root.choices.length - 1].value) : String(choice)
    confirmed(answered)
  }

  function buttonsInOrder() {
    var ordered = [cancelButton]
    for (var entryIndex = 0; entryIndex < choiceButtons.count; entryIndex++) ordered.push(choiceButtons.itemAt(entryIndex))
    return ordered
  }
  function moveFocus(step) {
    var ordered = buttonsInOrder()
    var at = 0
    for (var entryIndex = 0; entryIndex < ordered.length; entryIndex++) if (ordered[entryIndex] && ordered[entryIndex].activeFocus) at = entryIndex
    var next = ordered[(at + step + ordered.length) % ordered.length]
    if (next) next.forceActiveFocus()
  }

  QQC.Popup {
    id: dialog
    anchors.centerIn: parent
    width: Math.min(MailStyle.space(420), parent.width - MailStyle.space(32))
    padding: MailStyle.space(18)
    modal: true
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape
    onOpened: {
      var ordered = root.buttonsInOrder()
      ordered[ordered.length - 1].forceActiveFocus()
    }
    onClosed: root.request = null
    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }
    contentItem: Column {
      spacing: MailStyle.space(14)
      // Invariant: popups consume keys before the window shortcut map.
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          event.accepted = true
          root.moveFocus(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
          return
        }
        if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return
        event.accepted = true
        if (cancelButton.activeFocus) { root.close(); return }
        for (var entryIndex = 0; entryIndex < choiceButtons.count; entryIndex++)
          if (choiceButtons.itemAt(entryIndex).activeFocus) root.confirm(root.choices[entryIndex].value)
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "Delete \"" + String(root.request ? root.request.name : "") + "\"?"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.heading
        font.bold: true
        wrapMode: Text.Wrap
      }
      Text {
        width: parent.width
        visible: text !== ""
        textFormat: Text.PlainText
        text: String(root.request && root.request.message || "")
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        wrapMode: Text.Wrap
      }
      Flow {
        width: parent.width
        spacing: MailStyle.space(8)
        Widgets.Button {
          id: cancelButton
          objectName: "delete-cancel"
          text: "Cancel"
          bordered: true
          foreground: root.textColor
          fontFamily: root.panelFontFamily
          focusable: true
          onClicked: dialog.close()
        }
        Repeater {
          id: choiceButtons
          model: root.choices
          Widgets.Button {
            required property var modelData
            required property int index
            objectName: index === root.choices.length - 1 ? "delete-confirm" : "delete-choice-" + String(modelData.value)
            text: String(modelData.label)
            bordered: true
            foreground: root.dangerColor
            fontFamily: root.panelFontFamily
            focusable: true
            onClicked: root.confirm(modelData.value)
          }
        }
      }
    }
  }
}

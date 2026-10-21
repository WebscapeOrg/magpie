import QtQuick
import QtQuick.Window
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
  required property string currentDraftKey
  readonly property bool opened: dialog.opened
  property string requestedDraftKey: ""
  property var returnFocusItem: null
  property string returnDraftKey: ""

  signal saveRequested(string draftKey)
  signal discardRequested(string draftKey)

  // Invariant: a send failure can replace the composer while this modal is open; its decision
  // belongs to the draft that opened it.
  onCurrentDraftKeyChanged: {
    if (requestedDraftKey !== "" && requestedDraftKey !== currentDraftKey) close()
  }

  anchors.fill: parent
  z: 80

  function open() {
    if (currentDraftKey === "") return
    requestedDraftKey = currentDraftKey
    returnDraftKey = currentDraftKey
    returnFocusItem = root.Window.activeFocusItem
    dialog.open()
  }
  function close() {
    requestedDraftKey = ""
    dialog.close()
  }
  function cancel() { close() }
  function takeDraftKey() {
    var key = dialog.opened && requestedDraftKey === currentDraftKey
      ? requestedDraftKey : ""
    close()
    return key
  }
  function discard() {
    var key = takeDraftKey()
    if (key !== "") discardRequested(key)
  }
  function save() {
    var key = takeDraftKey()
    if (key !== "") saveRequested(key)
  }

  QQC.Popup {
    id: dialog
    anchors.centerIn: parent
    width: Math.min(MailStyle.space(400), parent.width - MailStyle.space(32))
    padding: MailStyle.space(18)
    modal: true
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape
    onOpened: saveButton.forceActiveFocus()
    onClosed: {
      root.requestedDraftKey = ""
      var target = root.returnFocusItem
      var key = root.returnDraftKey
      root.returnFocusItem = null
      root.returnDraftKey = ""
      Qt.callLater(function() {
        if (target && target.visible && target.enabled && key === root.currentDraftKey
            && root.Window.window && root.Window.window.visible)
          target.forceActiveFocus()
      })
    }
    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }
    contentItem: Column {
      spacing: MailStyle.space(14)
      // Invariant: popups consume window shortcuts; local key handling and KeyNavigation contain
      // the focus cycle.
      Keys.onPressed: function(event) {
        if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return
        event.accepted = true
        if (cancelButton.activeFocus) root.cancel()
        else if (discardButton.activeFocus) root.discard()
        else if (saveButton.activeFocus) root.save()
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "Save this draft?"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.heading
        font.bold: true
        wrapMode: Text.Wrap
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "You changed this message. Save your changes before leaving?"
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
          text: "Cancel"
          foreground: root.textColor
          fontFamily: root.panelFontFamily
          focusable: true
          activeFocusOnTab: true
          KeyNavigation.tab: discardButton
          KeyNavigation.backtab: saveButton
          onClicked: root.cancel()
        }
        Widgets.Button {
          id: discardButton
          text: "Discard"
          foreground: root.dangerColor
          fontFamily: root.panelFontFamily
          focusable: true
          activeFocusOnTab: true
          KeyNavigation.tab: saveButton
          KeyNavigation.backtab: cancelButton
          onClicked: root.discard()
        }
        Widgets.Button {
          id: saveButton
          text: "Save draft"
          foreground: root.textColor
          fontFamily: root.panelFontFamily
          focusable: true
          activeFocusOnTab: true
          KeyNavigation.tab: cancelButton
          KeyNavigation.backtab: discardButton
          onClicked: root.save()
        }
      }
    }
  }
}

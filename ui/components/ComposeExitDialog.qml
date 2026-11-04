import QtQuick
import QtQuick.Window

// Docs: asks whether to save a changed draft before leaving it. The confirmation itself is ConfirmPopup,
// shared with the label delete and mailbox removal confirmations.
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

  ConfirmPopup {
    id: dialog
    objectName: "compose-exit-confirmation"
    question: "Save this draft?"
    message: "You changed this message. Save your changes before leaving?"
    cancelName: "compose-exit-cancel"
    choices: [{value: "discard", label: "Discard", objectName: "compose-exit-discard"},
      {value: "save", label: "Save draft", objectName: "compose-exit-save", danger: false}]
    focusIndex: 1
    textColor: root.textColor
    dimColor: root.dimColor
    dangerColor: root.dangerColor
    backgroundColor: root.popupBackgroundColor
    borderColor: root.popupBorderColor
    fontFamily: root.panelFontFamily
    onChosen: function(value) {
      if (value === "save") root.save()
      else if (value === "discard") root.discard()
    }
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
  }
}

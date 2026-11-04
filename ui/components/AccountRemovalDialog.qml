import QtQuick

// Docs: asks before a mailbox is removed. The confirmation itself is ConfirmPopup, shared with the label
// delete and draft exit confirmations.
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

  function openFor(mailboxRequest) {
    request = mailboxRequest
    if (request) dialog.open()
  }

  function close() { dialog.close() }

  ConfirmPopup {
    id: dialog
    objectName: "removal-confirmation"
    question: "Remove " + String(root.request ? root.request.email : "") + "?"
    message: "This mailbox will be removed from Magpie."
    cancelName: "removal-cancel"
    choices: [{value: "remove", label: "Remove", objectName: "removal-confirm"}]
    focusIndex: -1
    textColor: root.textColor
    dimColor: root.dimColor
    dangerColor: root.dangerColor
    backgroundColor: root.popupBackgroundColor
    borderColor: root.popupBorderColor
    fontFamily: root.panelFontFamily
    onChosen: function() {
      var confirmedRequest = dialog.opened ? root.request : null
      dialog.close()
      if (confirmedRequest) root.confirmed(confirmedRequest)
    }
    onClosed: root.request = null
  }
}

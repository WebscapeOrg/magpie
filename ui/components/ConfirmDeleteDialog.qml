import QtQuick

// Docs: asks before a label is deleted. The confirmation itself is ConfirmPopup, shared with the mailbox
// removal and draft exit confirmations.
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

  ConfirmPopup {
    id: dialog
    objectName: "delete-confirmation"
    question: "Delete \"" + String(root.request ? root.request.name : "") + "\"?"
    message: String(root.request && root.request.message || "")
    cancelName: "delete-cancel"
    choices: root.choices.map(function(choice, index) {
      return {value: choice.value, label: choice.label,
        objectName: index === root.choices.length - 1 ? "delete-confirm" : "delete-choice-" + String(choice.value)}
    })
    // Invariant: Cancel has the focus, so Return deletes nothing; Tab reaches the choices (Q-016, as in
    // Magpie Calendar).
    focusIndex: -1
    textColor: root.textColor
    dimColor: root.dimColor
    dangerColor: root.dangerColor
    backgroundColor: root.popupBackgroundColor
    borderColor: root.popupBorderColor
    fontFamily: root.panelFontFamily
    onChosen: function(value) { root.confirm(value) }
    onClosed: root.request = null
  }
}

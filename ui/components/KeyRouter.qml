import QtQuick
import QtQml
import "../keys/Keymap.js" as Keymap

Item {
  id: root

  property string context: "list"
  property bool overlay: false

  signal triggered(string id, string sequence)

  function routeKeyEvent(event) {
    var key = ""
    if (event.key === Qt.Key_Up) key = "Up"
    else if (event.key === Qt.Key_Down) key = "Down"
    else if (event.key === Qt.Key_Return) key = "Return"
    else if (event.key === Qt.Key_Enter) key = "Enter"
    if (key === "") return false
    var sequence = ""
    if (event.modifiers & Qt.ControlModifier) sequence += "Ctrl+"
    if (event.modifiers & Qt.AltModifier) sequence += "Alt+"
    if (event.modifiers & Qt.ShiftModifier) sequence += "Shift+"
    if (event.modifiers & Qt.MetaModifier) sequence += "Meta+"
    sequence += key
    var entries = Keymap.sequencesFor(root.context)
    for (var entryIndex = 0; entryIndex < entries.length; entryIndex++) {
      var entry = entries[entryIndex]
      if (entry.sequence !== sequence || !Keymap.isSequenceEnabled(entry.binding,
          sequence, root.context, root.overlay)) continue
      event.accepted = true
      root.triggered(entry.id, sequence)
      return true
    }
    return false
  }

  Instantiator {
    model: Keymap.sequencesFor(root.context)

    delegate: Shortcut {
      required property var modelData
      sequence: modelData.sequence
      // Invariant: mailbox shortcuts remain window-scoped; only the standalone close chord is
      // application-wide.
      context: Qt.WindowShortcut
      enabled: Keymap.isSequenceEnabled(modelData.binding, modelData.sequence,
        root.context, root.overlay)
      onActivated: root.triggered(modelData.id, modelData.sequence)
    }
  }
}

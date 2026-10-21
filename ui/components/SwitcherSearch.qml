import QtQuick
import "../controls" as Widgets
import qs.Commons
import qs.Ui

Widgets.TextField {
  id: root

  signal moved(int delta)
  signal chosen()
  signal numbered(int number)
  property var numbers: []

  objectName: "switcher-search"
  placeholderText: "Type to find"

  function reset() { text = "" }
  function takeFocus() { forceActiveFocus() }

  Keys.onPressed: function(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    if (event.key === Qt.Key_Down || (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_N))) {
      root.moved(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Up || (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_P))) {
      root.moved(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.chosen()
      event.accepted = true
    } else if (!ctrl && root.text === "" && event.key >= Qt.Key_0 && event.key <= Qt.Key_9) {
      var number = event.key === Qt.Key_0 ? 10 : event.key - Qt.Key_0
      if ((root.numbers || []).indexOf(number) < 0) return
      root.numbered(number)
      event.accepted = true
    }
  }
}

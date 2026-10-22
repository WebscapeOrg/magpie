import QtQuick
import QtTest
import "../../components" as Components

Item {
  width: 500
  height: 420
  Components.LabelMovePicker {
    id: picker
    anchors.fill: parent
    textColor: Qt.rgba(0.95, 0.95, 0.95, 1)
    dimColor: Qt.rgba(0.7, 0.7, 0.7, 1)
    accentColor: Qt.rgba(0.9, 0.65, 0.4, 1)
    popupBackgroundColor: Qt.rgba(0.12, 0.12, 0.12, 1)
    popupBorderColor: Qt.rgba(0.5, 0.5, 0.5, 1)
    panelFontFamily: "monospace"
  }
  SignalSpy { id: chosen; target: picker; signalName: "targetChosen" }
  TestCase {
    name: "LabelMovePicker"
    when: windowShown
    function init() {
      chosen.clear()
      var targets = []
      for (var targetIndex = 0; targetIndex < 30; targetIndex++) {
        targets.push({name: "Folder " + targetIndex, path: "Folder/" + targetIndex})
      }
      picker.openFor("moving-label", targets)
      tryCompare(picker, "opened", true)
      wait(30)
    }
    function cleanup() { picker.close() }
    function verifyCursorVisible() {
      var scroll = findChild(picker, "label-move-scroll")
      var row = findChild(picker, "label-move-targets").itemAt(picker.cursorIndex)
      var top = row.mapToItem(scroll, 0, 0).y
      verify(top >= 0 && top + row.height <= scroll.height + 0.1,
        "The keyboard-selected folder must remain inside the viewport")
    }
    function test_keyboard_navigation_scrolls_to_the_selected_target() {
      for (var step = 0; step < 20; step++) keyClick(Qt.Key_Down)
      compare(picker.cursorIndex, 20)
      verifyCursorVisible()
      keyClick(Qt.Key_Return)
      compare(chosen.count, 1)
      compare(chosen.signalArguments[0][0], "moving-label")
      compare(chosen.signalArguments[0][1], "Folder/20")
    }
    function test_wrapping_up_reveals_the_last_target() {
      keyClick(Qt.Key_Up)
      compare(picker.cursorIndex, 29)
      verifyCursorVisible()
      keyClick(Qt.Key_Down)
      compare(picker.cursorIndex, 0)
      verifyCursorVisible()
    }
    function test_reopening_resets_scroll_and_preserves_cancel() {
      keyClick(Qt.Key_Up)
      keyClick(Qt.Key_Escape)
      tryCompare(picker, "opened", false)
      compare(chosen.count, 0)
      picker.openFor("second-label", picker.targets)
      tryCompare(picker, "opened", true)
      wait(30)
      compare(picker.cursorIndex, 0)
      verifyCursorVisible()
    }
  }
}

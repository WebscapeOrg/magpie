import QtQuick 2.15
import QtQuick.Controls 2.15 as QQC
import QtTest 1.3

// Invariant: an open Qt Popup intercepts keys before window shortcuts, regardless of focus.
Item {
  id: host
  width: 300; height: 200

  property string windowShortcut: ""
  property string localHandler: ""

  Shortcut { sequence: "j"; onActivated: host.windowShortcut = "j" }
  Shortcut { sequence: "Alt+A"; onActivated: host.windowShortcut = "alt-a" }

  QQC.Popup {
    id: focusedPopup
    width: 100; height: 80
    modal: false
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    contentItem: Item {
      focus: true
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_J) { host.localHandler = "j"; event.accepted = true }
      }
    }
  }

  QQC.Popup {
    id: unfocusedPopup
    width: 100; height: 80
    modal: false
    focus: false
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
  }

  TestCase {
    name: "PopupKeys"
    when: windowShown

    function init() {
      host.windowShortcut = ""
      host.localHandler = ""
      focusedPopup.close()
      unfocusedPopup.close()
      wait(30)
    }

    function test_the_window_owns_the_keys_while_no_popup_is_up() {
      keyClick(Qt.Key_J)
      compare(host.windowShortcut, "j")
      keyClick(Qt.Key_A, Qt.AltModifier)
      compare(host.windowShortcut, "alt-a")
    }

    function test_an_open_popup_takes_every_key_before_the_shortcut_map() {
      focusedPopup.open()
      wait(60)
      verify(focusedPopup.opened)
      keyClick(Qt.Key_J)
      compare(host.windowShortcut, "", "a bare key does not reach the window")
      keyClick(Qt.Key_A, Qt.AltModifier)
      compare(host.windowShortcut, "", "and neither does a modified one")
    }

    function test_focus_false_changes_nothing() {
      unfocusedPopup.open()
      wait(60)
      verify(unfocusedPopup.opened)
      keyClick(Qt.Key_J)
      compare(host.windowShortcut, "",
        "so there is no version of this a KeyRouter binding could drive")
    }

    function test_a_keys_handler_on_the_content_item_is_what_works() {
      focusedPopup.open()
      wait(60)
      keyClick(Qt.Key_J)
      compare(host.localHandler, "j")
      compare(host.windowShortcut, "")
    }

    function test_and_the_window_gets_them_back_when_it_closes() {
      focusedPopup.open()
      wait(60)
      focusedPopup.close()
      wait(60)
      keyClick(Qt.Key_J)
      compare(host.windowShortcut, "j")
    }
  }
}

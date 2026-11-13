import QtQuick 2.15
import QtTest 1.3

// Invariant: Qt can keep a hidden child as activeFocusItem; unused components must release focus.
Item {
  id: host
  width: 300; height: 200

  property string escapeWentTo: ""

  FocusScope {
    id: scope
    anchors.fill: parent
    focus: true

    Keys.onEscapePressed: function(event) {
      host.escapeWentTo = "scope"
      event.accepted = true
    }

    Item {
      id: compose
      anchors.fill: parent
      property bool opened: false
      visible: opened
      focus: opened
      Keys.onEscapePressed: function(event) {
        host.escapeWentTo = "compose"
        event.accepted = true
      }
    }
  }

  TestCase {
    name: "FocusOwnership"
    when: windowShown

    function test_a_closed_compose_does_not_hold_focus() {
      compare(compose.opened, false)
      compare(compose.activeFocus, false,
        "a closed compose must not own the focus")
    }

    function test_escape_reaches_the_scope_when_compose_is_closed() {
      host.escapeWentTo = ""
      keyClick(Qt.Key_Escape)
      compare(host.escapeWentTo, "scope")
    }

    function test_an_open_compose_does_hold_focus() {
      compose.opened = true
      wait(50)
      compare(compose.activeFocus, true,
        "an open compose is exactly when it should own the focus")
      host.escapeWentTo = ""
      keyClick(Qt.Key_Escape)
      compare(host.escapeWentTo, "compose")
      compose.opened = false
      wait(50)
    }
  }
}

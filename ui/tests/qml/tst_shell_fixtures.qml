import QtQuick
import QtTest
import qs.Ui as Widgets

Item {
  id: root
  width: 400
  height: 200
  property var hoveredStates: []

  Widgets.Button {
    id: button
    x: 20
    y: 20
    width: 160
    height: 40
    text: "Test action"
    focusable: true
    onHovered: function(value) { root.hoveredStates = root.hoveredStates.concat([value]) }
  }

  Widgets.TextField {
    id: passwordField
    x: 20
    y: 100
    width: 250
    height: 40
    password: true
    text: "synthetic-password"
  }

  TestCase {
    name: "ShellFixtures"
    when: windowShown

    function init() {
      mouseMove(root, 390, 190)
      passwordField.forceActiveFocus()
      root.hoveredStates = []
      passwordField.password = true
    }

    function test_button_hover_reaches_the_cursor_owner() {
      mouseMove(button, 30, 20)
      tryCompare(button, "hot", true)
      compare(root.hoveredStates.length, 1)
      compare(root.hoveredStates[0], true)
      mouseMove(root, 390, 190)
      tryCompare(button, "hot", false)
      compare(root.hoveredStates.length, 2)
      compare(root.hoveredStates[1], false)
    }

    function test_clicking_a_focusable_button_moves_keyboard_focus() {
      verify(passwordField.activeFocus)
      mouseClick(button, 30, 20)
      tryVerify(function() { return button.activeFocus })
      verify(!passwordField.activeFocus)
    }

    function test_password_display_hides_the_value_until_revealed() {
      compare(passwordField.text, "synthetic-password")
      verify(passwordField.displayText !== passwordField.text)
      compare(passwordField.displayText.length, passwordField.text.length)
      passwordField.password = false
      compare(passwordField.displayText, passwordField.text)
    }
  }
}

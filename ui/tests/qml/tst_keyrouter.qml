import QtQuick 2.15
import QtQuick.Window 2.15
import QtQuick.Controls 2.15 as QQC
import QtTest 1.3
import "../../components" as Omamail
import "../../controls" as Widgets

Item {
  id: host
  width: 300; height: 200

  property string lastId: ""
  property string lastSequence: ""
  property string context: "list"
  property bool overlay: false

  Omamail.KeyRouter {
    context: host.context
    overlay: host.overlay
    onTriggered: function(id, sequence) {
      host.lastId = id
      host.lastSequence = sequence
    }
  }

  readonly property Item focusItem: host.Window.activeFocusItem

  Omamail.IconButton { id: iconButton; tooltipText: "Test action" }
  Omamail.IconTextButton { id: iconTextButton; text: "Test action" }
  Widgets.Button { id: textButton; text: "Test action"; focusable: true }
  Widgets.PanelActionButton { id: panelButton; tooltipText: "Test action"; focusable: true }
  SignalSpy { id: buttonClicks; signalName: "clicked" }

  FocusScope {
    id: scope
    anchors.fill: parent
    focus: true

    Item { id: keyboardHome; width: 1; height: 1 }

    Item {
      id: compose
      anchors.fill: parent
      property bool opened: false
      visible: opened
      QQC.TextField { id: composeField; width: 80 }
    }

    function applyContextFocus() {
      if (host.context === "compose") composeField.forceActiveFocus()
      else keyboardHome.forceActiveFocus()
    }
  }

  TestCase {
    name: "KeyRouter"
    when: windowShown

    function init() {
      host.context = "list"
      host.overlay = false
      host.lastId = ""
      host.lastSequence = ""
      compose.opened = false
      scope.applyContextFocus()
      wait(30)
    }

    function test_a_bare_letter_fires_in_its_context() {
      keyClick(Qt.Key_E)
      compare(host.lastId, "archive")
    }

    function test_focused_buttons_activate_before_mailbox_shortcuts_data() {
      return [{tag: "icon", button: iconButton}, {tag: "text", button: textButton},
              {tag: "panel", button: panelButton}, {tag: "icon-text", button: iconTextButton}]
    }

    function test_focused_buttons_activate_before_mailbox_shortcuts(data) {
      var button = data.button
      buttonClicks.target = button
      buttonClicks.clear()
      button.forceActiveFocus()
      verify(button.activeFocus)
      compare(button.Accessible.role, Accessible.Button)
      compare(button.Accessible.name, "Test action")
      keyClick(Qt.Key_Return)
      keyClick(Qt.Key_Enter, Qt.KeypadModifier)
      keyClick(Qt.Key_Space)
      compare(buttonClicks.count, 3)
      compare(host.lastId, "", "activation must not open or select a mailbox row")
      keyClick(Qt.Key_Comma, Qt.ControlModifier)
      compare(host.lastId, "settings", "modified application shortcuts remain available")
      compare(buttonClicks.count, 3)
      host.lastId = ""
      keyClick(Qt.Key_Escape)
      compare(host.lastId, "back", "Escape still follows normal navigation")
      compare(buttonClicks.count, 3)
      button.Accessible.pressAction()
      compare(buttonClicks.count, 4)
      try {
        button.enabled = false
        button.Accessible.pressAction()
        compare(buttonClicks.count, 4, "disabled controls refuse accessible press actions")
      } finally {
        button.enabled = true
      }
    }

    function test_space_toggles_selection_in_the_list() {
      keyClick(Qt.Key_Space)
      compare(host.lastId, "toggleCheck")
    }

    function test_space_stays_text_in_a_draft() {
      host.context = "compose"
      compose.opened = true
      composeField.text = ""
      scope.applyContextFocus()
      wait(20)
      keyClick(Qt.Key_Space)
      compare(host.lastId, "")
      compare(composeField.text, " ")
    }

    function test_space_toggles_selection_while_reading() {
      host.context = "reader"
      wait(20)
      keyClick(Qt.Key_Space)
      compare(host.lastId, "toggleCheck")
    }

    function test_the_same_letter_is_dead_on_a_form() {
      host.context = "page"
      wait(20)
      keyClick(Qt.Key_E)
      compare(host.lastId, "", "e is not archive on a settings form")
    }

    function test_a_bare_letter_is_dead_in_a_draft() {
      host.context = "compose"
      wait(20)
      keyClick(Qt.Key_E)
      compare(host.lastId, "", "e is a letter in a sentence, not archive")
    }

    function test_a_bare_letter_is_dead_in_a_query() {
      host.context = "search"
      wait(20)
      keyClick(Qt.Key_E)
      compare(host.lastId, "", "e is a letter in a query")
    }

    function test_old_help_key_is_dead_in_a_draft() {
      host.context = "compose"
      wait(20)
      keyClick(Qt.Key_K, Qt.ControlModifier)
      compare(host.lastId, "", "Ctrl+K is no longer Help")
    }

    function test_alt_z_undoes_send_while_composing() {
      host.context = "compose"
      wait(20)
      keyClick(Qt.Key_Z, Qt.ControlModifier)
      compare(host.lastId, "", "Ctrl+Z remains text undo while composing")
      keyClick(Qt.Key_Z, Qt.AltModifier)
      compare(host.lastId, "undoSend",
        "Alt+Z must reach the queued send while composing")

      host.lastId = ""
      host.context = "reader"
      scope.applyContextFocus()
      wait(20)
      keyClick(Qt.Key_Z, Qt.AltModifier)
      compare(host.lastId, "undoSend")
      host.lastId = ""
      keyClick(Qt.Key_J, Qt.ShiftModifier)
      compare(host.lastId, "scrollDown",
        "the undo window must not stand Shift+J reader scrolling")
    }

    function test_escape_is_the_way_out_of_every_context() {
      var contexts = ["list", "reader", "search", "compose", "page", "calendar"]
      for (var index = 0; index < contexts.length; index++) {
        host.context = contexts[index]
        host.lastId = ""
        wait(20)
        keyClick(Qt.Key_Escape)
        compare(host.lastId, "back", "Escape must leave " + contexts[index])
      }
    }

    function test_an_overlay_stands_the_mailbox_down() {
      host.overlay = true
      wait(20)
      keyClick(Qt.Key_E)
      compare(host.lastId, "", "nothing acts on mail behind the shortcut sheet")
    }

    function test_but_the_sheets_own_key_still_closes_it() {
      host.overlay = true
      wait(20)
      keyClick(Qt.Key_Question)
      compare(host.lastId, "help")
    }

    // Invariant: overlay movement must remain routable so App can scroll a sheet taller than the window.
    function test_moving_survives_an_overlay_so_it_can_walk_one() {
      host.overlay = true
      wait(20)
      keyClick(Qt.Key_J)
      compare(host.lastId, "cursorDown")
    }

    function test_open_works_from_the_reader_too() {
      host.context = "reader"
      wait(20)
      keyClick(Qt.Key_O)
      compare(host.lastId, "open")
      host.lastId = ""
      keyClick(Qt.Key_Return)
      compare(host.lastId, "open")
    }

    function test_answering_works_from_the_list_and_the_reader() {
      keyClick(Qt.Key_R)
      compare(host.lastId, "reply", "from the list")
      host.context = "reader"
      host.lastId = ""
      wait(20)
      keyClick(Qt.Key_R)
      compare(host.lastId, "reply", "and from the reader")
    }

    // Invariant: direct Ctrl+digit bindings avoid the platform deadline on unfinished key sequences.
    function test_a_digit_names_the_mailbox_it_opens() {
      keyClick(Qt.Key_3, Qt.ControlModifier)
      compare(host.lastId, "goMailbox")
      compare(host.lastSequence, "Ctrl+3")
    }

    function test_ctrl_zero_is_not_a_mailbox() {
      keyClick(Qt.Key_0, Qt.ControlModifier)
      compare(host.lastId, "", "Ctrl+0 resets the zoom, so the rail stops at nine")
    }

    function test_a_digit_is_dead_in_a_draft() {
      host.context = "compose"
      wait(20)
      keyClick(Qt.Key_3, Qt.ControlModifier)
      compare(host.lastId, "", "typing a number into a reply is not going anywhere")
    }

    function test_alt_digit_names_the_account_it_opens() {
      keyClick(Qt.Key_3, Qt.AltModifier)
      compare(host.lastId, "goAccount")
      compare(host.lastSequence, "Alt+3")
    }

    function test_account_digits_are_dead_in_a_draft() {
      host.context = "compose"
      wait(20)
      keyClick(Qt.Key_3, Qt.AltModifier)
      compare(host.lastId, "", "a recipient may contain a number")
    }

    function test_mail_and_calendar_have_mnemonic_shortcuts() {
      keyClick(Qt.Key_C, Qt.ControlModifier | Qt.ShiftModifier)
      compare(host.lastId, "calendarView")
      host.context = "calendar"
      host.lastId = ""
      wait(20)
      keyClick(Qt.Key_M, Qt.ControlModifier | Qt.ShiftModifier)
      compare(host.lastId, "mailView")
    }

    // Invariant: a matching week-view shortcut would make the platform Close chord ambiguous and swallow it.
    function test_calendar_week_is_not_the_close_chord() {
      host.context = "calendar"
      wait(20)
      keyClick(Qt.Key_W)
      compare(host.lastId, "calendarWeek")
      host.lastId = ""
      keyClick(Qt.Key_W, Qt.ControlModifier)
      compare(host.lastId, "", "Ctrl/Cmd+W is Close, not week view")
    }

    function test_the_switcher_opens_on_one_press() {
      keyClick(Qt.Key_A, Qt.AltModifier)
      compare(host.lastId, "switchAccount")
    }

    function test_the_bare_letter_still_means_reply_all() {
      keyClick(Qt.Key_A)
      compare(host.lastId, "replyAll", "Alt+A did not take the letter with it")
    }

    function test_the_switcher_key_is_dead_in_a_draft() {
      host.context = "compose"
      wait(20)
      keyClick(Qt.Key_A, Qt.AltModifier)
      compare(host.lastId, "", "switching is a mailbox action, not a draft one")
    }

    function test_a_reader_only_key_is_dead_in_the_list() {
      keyClick(Qt.Key_0, Qt.ControlModifier)
      compare(host.lastId, "", "nothing to zoom from the list")
      host.context = "reader"
      host.lastId = ""
      wait(20)
      keyClick(Qt.Key_0, Qt.ControlModifier)
      compare(host.lastId, "zoomReset")
    }

    // Invariant: restoring a FocusScope reselects its departed field; park focus on a plain Item.
    function test_leaving_a_draft_takes_the_keyboard_with_it() {
      host.context = "compose"
      compose.opened = true
      scope.applyContextFocus()
      wait(30)
      compare(host.focusItem, composeField, "the draft is what is typed into")

      compose.opened = false
      host.context = "list"
      scope.applyContextFocus()
      wait(30)
      verify(host.focusItem !== composeField,
        "a dismissed field must not keep the keyboard")
      compare(host.focusItem, keyboardHome, "which parks on the home item")

      host.lastId = ""
      keyClick(Qt.Key_J)
      compare(host.lastId, "cursorDown",
        "and j reaches the mailbox again, which is the whole point")
    }
  }
}

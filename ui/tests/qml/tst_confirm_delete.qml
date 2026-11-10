import QtQuick
import QtTest
import "../../components" as Omamail
import "../../settings"
import "../../settings/Display.js" as Display

// Docs: the label delete, mailbox removal and draft exit confirmations are the shared ConfirmPopup: Cancel
// first, the choices after it, and the buttons in view at every size.
Item {
  id: page
  width: 640
  height: 480
  Omamail.ConfirmDeleteDialog {
    id: dialog
    textColor: Qt.rgba(1,1,1,1)
    dimColor: textColor
    dangerColor: textColor
    popupBackgroundColor: Qt.rgba(0,0,0,1)
    popupBorderColor: textColor
    panelFontFamily: "monospace"
  }
  SignalSpy { id: confirmed; target: dialog; signalName: "confirmed" }
  SignalSpy { id: saved; target: exit; signalName: "saveRequested" }
  SignalSpy { id: discarded; target: exit; signalName: "discardRequested" }
  Omamail.AccountRemovalDialog {
    id: removal
    textColor: Qt.rgba(1, 1, 1, 1)
    dimColor: Qt.rgba(0.7, 0.7, 0.7, 1)
    dangerColor: Qt.rgba(1, 0.3, 0.3, 1)
    popupBackgroundColor: Qt.rgba(0, 0, 0, 1)
    popupBorderColor: Qt.rgba(0.5, 0.5, 0.5, 1)
    panelFontFamily: "sans-serif"
  }
  Omamail.ComposeExitDialog {
    id: exit
    currentDraftKey: "synthetic-draft"
    textColor: Qt.rgba(1, 1, 1, 1)
    dimColor: Qt.rgba(0.7, 0.7, 0.7, 1)
    dangerColor: Qt.rgba(1, 0.3, 0.3, 1)
    popupBackgroundColor: Qt.rgba(0, 0, 0, 1)
    popupBorderColor: Qt.rgba(0.5, 0.5, 0.5, 1)
    panelFontFamily: "sans-serif"
  }
  TestCase {
    name: "ConfirmDeleteKeyboard"
    when: windowShown
    function init() {
      confirmed.clear()
      dialog.openFor({kind:"event",name:"Synthetic meeting",event:{googleId:"one"}})
      tryCompare(dialog,"opened",true)
    }
    function cleanup() { dialog.close() }
    // Invariant: Q-016. The question opens on Cancel, so Return deletes nothing.
    function test_return_on_opening_cancels() {
      keyClick(Qt.Key_Return)
      tryCompare(dialog,"opened",false)
      compare(confirmed.count,0)
    }
    function test_tab_then_return_deletes() {
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Return)
      compare(confirmed.count,1)
      compare(confirmed.signalArguments[0][0].event.googleId,"one")
    }
    function test_tab_cycles_and_keypad_enter_confirms() {
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Enter)
      compare(confirmed.count,1)
    }
    function test_tab_then_backtab_then_enter_cancels() {
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Backtab,Qt.ShiftModifier)
      keyClick(Qt.Key_Enter)
      tryCompare(dialog,"opened",false)
      compare(confirmed.count,0)
    }
    function test_choices_start_on_cancel_and_tab_reaches_each_in_turn() {
      dialog.close()
      tryCompare(dialog,"opened",false)
      dialog.openFor({kind:"event",name:"Review",event:{googleId:"two"},
        choices:[{value:"none",label:"Delete without email"},{value:"all",label:"Delete and notify guests"}]})
      tryCompare(dialog,"opened",true)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Return)
      compare(confirmed.count,1)
      compare(confirmed.signalArguments[0][0].choice,"none")
      compare(confirmed.signalArguments[0][0].event.googleId,"two")
      confirmed.clear()
      dialog.openFor({kind:"event",name:"Review",event:{googleId:"two"},
        choices:[{value:"none",label:"Delete without email"},{value:"all",label:"Delete and notify guests"}]})
      tryCompare(dialog,"opened",true)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Return)
      compare(confirmed.signalArguments[0][0].choice,"all")
    }
    function test_return_with_choices_on_opening_cancels() {
      dialog.close()
      tryCompare(dialog,"opened",false)
      dialog.openFor({kind:"event",name:"Review",
        choices:[{value:"series",label:"Delete series"},{value:"all",label:"Delete occurrence"}]})
      tryCompare(dialog,"opened",true)
      keyClick(Qt.Key_Return)
      tryCompare(dialog,"opened",false)
      compare(confirmed.count,0)
    }
    function test_escape_cancels() {
      keyClick(Qt.Key_Escape)
      tryCompare(dialog,"opened",false)
      compare(confirmed.count,0)
    }
  }

  TestCase {
    name: "ConfirmFit"
    when: windowShown
    function init() {
      confirmed.clear()
      saved.clear()
      discarded.clear()
    }
    function cleanup() {
      for (var holder of [dialog, removal, exit]) holder.close()
      tryCompare(dialog, "opened", false)
      tryCompare(removal, "opened", false)
      tryCompare(exit, "opened", false)
      MailStyle.preferences = Display.normalize({})
      resize(640, 480)
    }
    function resize(width, height) {
      page.width = width
      page.height = height
      tryCompare(page.Window.window, "width", width)
      tryCompare(page.Window.window, "height", height)
      wait(20)
    }
    // Docs: the request App.qml sends when a label is deleted.
    readonly property var label: ({kind: "label", labelId: "Label_1", name: "Clients/Northwind/Quarterly reviews", accountId: "synthetic",
      message: "The label and every label beneath it are removed from the server. The messages keep their other labels."})
    function openFor(request) {
      dialog.openFor(request)
      tryCompare(dialog, "opened", true)
      wait(20)
    }
    function popup(holder, name) { return findChild(holder || dialog, name || "delete-confirmation") }
    // The choice buttons come from a Repeater, which findChild does not search, so walk the items.
    function named(item, name) {
      if (!item) return null
      if (item.objectName === name) return item
      var found = null
      for (var child of item.children || []) if (!found) found = named(child, name)
      if (!found && item.contentItem && item.contentItem !== item) found = named(item.contentItem, name)
      return found
    }
    // Docs: Mail sends one choice; three long ones show the buttons scrolling with the words.
    readonly property var occurrence: ({kind: "event", name: "Quarterly planning with the design and engineering leads", event: {googleId: "three"},
      message: "Delete this occurrence, or every occurrence in the series.",
      choices: [{value: "series", label: "Delete series"}, {value: "none", label: "Delete occurrence without email"},
        {value: "all", label: "Delete occurrence and notify guests"}]})
    readonly property var order: ["delete-cancel", "delete-choice-series", "delete-choice-none", "delete-confirm"]
    function box(holderPopup) { return (holderPopup || popup()).contentItem.parent }
    function insideTheWindow(holderPopup) {
      var shown = holderPopup || popup()
      var window = page.Window.window
      var top = box(shown).mapToItem(null, 0, 0)
      var gap = shown.edge - 1
      verify(top.y >= gap && top.y + box(shown).height <= window.height - gap, "inside the window, clear of its edges: " + top.y + " + " + box(shown).height)
      verify(top.x >= gap && top.x + box(shown).width <= window.width - gap, "inside the window across: " + top.x + " + " + box(shown).width)
    }
    function wholeLabel(button, name) {
      var label = named(button, "button-label")
      var labelAt = label.mapToItem(button, 0, 0)
      verify(labelAt.x >= 0 && labelAt.x + label.width <= button.width + 0.5 && labelAt.y >= 0 && labelAt.y + label.height <= button.height + 0.5, name + "'s words fit its box")
      verify(!label.truncated && label.contentWidth <= label.width + 0.5, name + "'s words are whole and inside its box: " + label.contentWidth + " in " + label.width)
    }
    function inOrder(shown, names) {
      var flow = findChild(shown, "confirm-buttons")
      var previous = null
      for (var name of names) {
        var at = named(shown, name).mapToItem(flow, 0, 0)
        if (previous) verify(at.y > previous.y + 0.5 || (Math.abs(at.y - previous.y) < 0.5 && at.x > previous.x), name + " follows the button before it")
        previous = at
      }
    }
    function questionShows(shown) {
      var words = findChild(shown, "confirm-words")
      var question = findChild(shown, "confirm-question")
      var line = question.contentHeight / question.lineCount
      var questionAt = question.mapToItem(words, 0, 0)
      verify(questionAt.y >= -0.5 && questionAt.y + line <= words.height + 0.5, "the question shows when it opens: " + questionAt.y + " in " + words.height)
      verify(words.height >= line * 2, "the words keep room for two lines: " + words.height)
    }
    // Invariant: at 36 pt, with a long name and three long choices, the confirmation stays inside the window
    // and opens on its question with Cancel focused; each button Tab reaches is scrolled whole into view
    // inside the confirmation, in order.
    function test_three_long_choices_at_the_largest_size_keep_the_question_and_every_button_in_view() {
      failOnWarning(/Binding loop/)
      MailStyle.preferences = Display.normalize({interfaceSize: 36})
      openFor(occurrence)
      insideTheWindow()
      var words = findChild(popup(), "confirm-words")
      var wordsAt = words.mapToItem(box(), 0, 0)
      verify(wordsAt.y >= 0 && wordsAt.y + words.height <= box().height + 0.5, "the words sit inside the confirmation")
      questionShows(popup())
      verify(named(popup(), "delete-cancel").activeFocus, "Cancel has the focus")
      // Tab out to the last choice, Shift+Tab back to Cancel, then Tab out again, so each button is checked
      // as the focus reaches it from either side.
      var steps = [[null, 0], [Qt.Key_Tab, 1], [Qt.Key_Tab, 2], [Qt.Key_Tab, 3], [Qt.Key_Backtab, 2], [Qt.Key_Backtab, 1],
        [Qt.Key_Backtab, 0], [Qt.Key_Tab, 1], [Qt.Key_Tab, 2], [Qt.Key_Tab, 3]]
      for (var step of steps) {
        if (step[0] !== null) keyClick(step[0], step[0] === Qt.Key_Backtab ? Qt.ShiftModifier : Qt.NoModifier)
        var name = order[step[1]]
        var button = named(popup(), name)
        verify(button.activeFocus, name + " has the focus")
        wait(20)
        var at = button.mapToItem(box(), 0, 0)
        verify(at.x >= 0 && at.x + button.width <= box().width + 0.5, name + " fits across")
        wholeLabel(button, name)
        // The focused button may wait below the question when the confirmation opens; every other step
        // scrolls to it.
        if (step[0] === null) continue
        verify(at.y >= -0.5 && at.y + button.height <= box().height + 0.5, name + " is inside the confirmation: " + at.y + " + " + button.height + " in " + box().height)
        var inWords = button.mapToItem(words, 0, 0)
        verify(inWords.y >= -0.5 && inWords.y + button.height <= words.height + 0.5, name + " is scrolled whole into view: " + inWords.y + " in " + words.height)
      }
      verify(popup().stacked, "four buttons this large need more than half the room, so they scroll with the words")
      inOrder(popup(), order)
      keyClick(Qt.Key_Return)
      tryCompare(dialog, "opened", false)
      compare(confirmed.signalArguments[0][0].choice, "all")
    }
    // Invariant: while the buttons take at most half the room (here at the usual 17 pt) they stay in view
    // below the words, and only the words scroll.
    function test_buttons_that_fit_stay_below_the_words() {
      failOnWarning(/Binding loop/)
      openFor(occurrence)
      insideTheWindow()
      verify(!popup().stacked, "the buttons are not stacked")
      var words = findChild(popup(), "confirm-words")
      for (var name of order) {
        var button = named(popup(), name)
        var at = button.mapToItem(box(), 0, 0)
        verify(at.y >= words.mapToItem(box(), 0, 0).y + words.height && at.y + button.height <= box().height + 0.5, name + " is in view below the words")
        wholeLabel(button, name)
      }
      inOrder(popup(), order)
    }
    // Invariant: a keyboard user can read the line on what follows when the words do not fit, without the
    // focus leaving the button it is on.
    function test_words_that_do_not_fit_scroll_from_the_keyboard() {
      MailStyle.preferences = Display.normalize({interfaceSize: 32})
      openFor(label)
      var words = findChild(popup(), "confirm-words")
      var message = findChild(popup(), "confirm-message")
      verify(words.contentHeight > words.height + 1, "the words do not fit: " + words.contentHeight + " in " + words.height)
      compare(words.contentY, 0)
      keyClick(Qt.Key_Down)
      verify(words.contentY > 0, "Down scrolls the words")
      keyClick(Qt.Key_End)
      var end = message.mapToItem(words, 0, message.height)
      verify(end.y <= words.height + 0.5, "End shows the last line: " + end.y + " in " + words.height)
      keyClick(Qt.Key_Home)
      compare(words.contentY, 0)
      keyClick(Qt.Key_PageDown)
      verify(words.contentY > 0, "PageDown scrolls the words")
      keyClick(Qt.Key_PageUp)
      compare(words.contentY, 0)
      verify(named(popup(), "delete-cancel").activeFocus, "the focus stays on the button")
      compare(confirmed.count, 0)
    }
    // Invariant: only Return or Enter alone acts; with Shift, Ctrl or Alt it does nothing, so a habit from the
    // composer cannot delete a label or leave a draft.
    function test_return_with_a_modifier_does_nothing() {
      var modifiers = [Qt.ShiftModifier, Qt.ControlModifier, Qt.AltModifier]
      openFor(label)
      keyClick(Qt.Key_Tab)
      verify(named(popup(), "delete-confirm").activeFocus, "Delete has the focus")
      for (var modifier of modifiers) {
        keyClick(Qt.Key_Return, modifier)
        keyClick(Qt.Key_Enter, modifier | Qt.KeypadModifier)
      }
      compare(dialog.opened, true)
      compare(confirmed.count, 0)
      dialog.close()
      tryCompare(dialog, "opened", false)
      exit.open()
      tryCompare(exit, "opened", true)
      wait(20)
      for (modifier of modifiers) keyClick(Qt.Key_Return, modifier)
      compare(exit.opened, true)
      compare(saved.count, 0)
      compare(discarded.count, 0)
    }
    // Invariant: when the window's size changes while the confirmation is open, the question shows until the
    // focus is moved, and then the button it was moved to stays in view.
    function test_resizing_keeps_the_question_or_the_chosen_button_in_view() {
      failOnWarning(/Binding loop/)
      MailStyle.preferences = Display.normalize({interfaceSize: 28})
      resize(1024, 768)
      openFor(occurrence)
      verify(!popup().stacked, "the buttons fit below the words at first")
      resize(640, 480)
      verify(popup().stacked, "and scroll with them in the smaller window")
      insideTheWindow()
      questionShows(popup())
      keyClick(Qt.Key_Backtab, Qt.ShiftModifier)
      keyClick(Qt.Key_Backtab, Qt.ShiftModifier)
      var words = findChild(popup(), "confirm-words")
      var chosen = named(popup(), "delete-choice-none")
      verify(chosen.activeFocus)
      resize(1024, 768)
      verify(!popup().stacked)
      compare(words.contentY, 0)
      questionShows(popup())
      resize(640, 480)
      verify(popup().stacked)
      var inWords = chosen.mapToItem(words, 0, 0)
      verify(inWords.y >= -0.5 && inWords.y + chosen.height <= words.height + 0.5, "the chosen button is in view: " + inWords.y + " in " + words.height)
      verify(chosen.activeFocus)
    }
    // Invariant: a confirmation opened again after the last one ended on another button opens on its question,
    // and keeps it in view when the window then changes size, since the focus has not been moved.
    function test_opening_again_after_ending_on_another_button_shows_the_question() {
      var short = Object.assign({}, label, {name: "Clients/Acme"})
      MailStyle.preferences = Display.normalize({interfaceSize: 36})
      resize(480, 360)
      openFor(short)
      keyClick(Qt.Key_Tab)
      verify(named(popup(), "delete-confirm").activeFocus)
      keyClick(Qt.Key_Escape)
      tryCompare(dialog, "opened", false)
      resize(360, 240)
      openFor(short)
      verify(popup().stacked, "the buttons scroll with the words in the small window")
      verify(named(popup(), "delete-cancel").activeFocus)
      questionShows(popup())
      resize(360, 250)
      verify(popup().stacked)
      questionShows(popup())
      compare(findChild(popup(), "confirm-words").contentY, 0)
    }
    // Invariant: a change of text size while the confirmation is open keeps the button the focus was moved to
    // in view.
    function test_a_text_size_change_keeps_the_chosen_button_in_view() {
      MailStyle.preferences = Display.normalize({interfaceSize: 28})
      openFor(occurrence)
      verify(popup().stacked, "the buttons scroll with the words")
      keyClick(Qt.Key_Backtab, Qt.ShiftModifier)
      keyClick(Qt.Key_Backtab, Qt.ShiftModifier)
      var chosen = named(popup(), "delete-choice-none")
      verify(chosen.activeFocus)
      var words = findChild(popup(), "confirm-words")
      MailStyle.preferences = Display.normalize({interfaceSize: 36})
      wait(80)
      verify(popup().stacked)
      var inWords = chosen.mapToItem(words, 0, 0)
      verify(inWords.y >= -0.5 && inWords.y + chosen.height <= words.height + 0.5, "the chosen button is in view: " + inWords.y + " in " + words.height)
      verify(chosen.activeFocus)
    }
    // Invariant: a button taller than the room a very small window leaves shows from its first line.
    function test_a_button_taller_than_the_room_shows_from_its_first_line() {
      MailStyle.preferences = Display.normalize({interfaceSize: 36})
      resize(360, 240)
      openFor(occurrence)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Tab)
      var words = findChild(popup(), "confirm-words")
      var tall = named(popup(), "delete-confirm")
      verify(tall.activeFocus)
      verify(tall.height > words.height, "the button is taller than the room: " + tall.height + " in " + words.height)
      compare(tall.mapToItem(words, 0, 0).y, 0)
    }
    // Invariant: the mailbox removal and draft exit confirmations are the same confirmation, so a long
    // address at the largest size stays inside the window with its question and buttons whole.
    function test_removal_and_draft_exit_fit_at_the_largest_size() {
      failOnWarning(/Binding loop/)
      MailStyle.preferences = Display.normalize({interfaceSize: 36})
      removal.openFor({id: "synthetic", email: "a.very.long.mailbox.address.for.testing@subdomain.example.test"})
      tryCompare(removal, "opened", true)
      wait(20)
      var shown = popup(removal, "removal-confirmation")
      insideTheWindow(shown)
      questionShows(shown)
      verify(named(shown, "removal-cancel").activeFocus, "Cancel has the focus")
      for (var name of ["removal-cancel", "removal-confirm"]) wholeLabel(named(shown, name), name)
      inOrder(shown, ["removal-cancel", "removal-confirm"])
      removal.close()
      tryCompare(removal, "opened", false)
      exit.open()
      tryCompare(exit, "opened", true)
      wait(20)
      shown = popup(exit, "compose-exit-confirmation")
      insideTheWindow(shown)
      questionShows(shown)
      verify(named(shown, "compose-exit-save").activeFocus, "Save draft has the focus")
      for (name of ["compose-exit-cancel", "compose-exit-discard", "compose-exit-save"]) wholeLabel(named(shown, name), name)
      inOrder(shown, ["compose-exit-cancel", "compose-exit-discard", "compose-exit-save"])
    }
  }
}

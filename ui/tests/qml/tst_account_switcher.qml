import QtQuick 2.15
import QtQuick.Window
import QtTest 1.3
import "../../components" as Omamail

// Invariant: the combined row shifts account indexes; the popup consumes keys before KeyRouter.
Item {
  id: host
  width: 600
  height: 400

  readonly property var threeMailboxes: [
    { id: "a@example.org", email: "a@example.org", label: "Personal",
      unread: 2, active: true, signedIn: true, busy: false, error: "" },
    { id: "b@example.net", email: "b@example.net", label: "Work",
      unread: 0, active: false, signedIn: true, busy: false, error: "" },
    { id: "c@example.com", email: "c@example.com", label: "Other",
      unread: 5, active: false, signedIn: true, busy: false, error: "" }
  ]

  readonly property var oneMailbox: [
    { id: "a@example.org", email: "a@example.org", label: "Personal",
      unread: 2, active: true, signedIn: true, busy: false, error: "" }
  ]

  Omamail.AccountSwitcher {
    id: switcher
    anchors.fill: parent
    textColor: Qt.rgba(1, 1, 1, 1)
    accentColor: Qt.rgba(1, 0.5, 0, 1)
    urgentColor: Qt.rgba(1, 0.2, 0.2, 1)
    dimColor: Qt.rgba(0.67, 0.67, 0.67, 1)
    popupBackgroundColor: Qt.rgba(0.13, 0.13, 0.13, 1)
    popupBorderColor: Qt.rgba(0.47, 0.47, 0.47, 1)
    panelFontFamily: "monospace"
    accounts: threeMailboxes
  }

  SignalSpy {
    id: chosenSpy
    target: switcher
    signalName: "accountChosen"
  }

  SignalSpy {
    id: unifiedSpy
    target: switcher
    signalName: "unifiedChosen"
  }

  TestCase {
    name: "AccountSwitcher"
    when: windowShown

    // Invariant: popup content exists only after opening the menu.
    function accountRows(item) {
      var found = []
      var node = item === undefined ? switcher.menuRows : item
      if (!node) return found
      if (node.objectName === "account-row") found.push(node)
      var children = node.children || []
      for (var index = 0; index < children.length; index++)
        found = found.concat(accountRows(children[index]))
      return found
    }

    function init() {
      switcher.accounts = threeMailboxes
      switcher.unifiedActive = false
      switcher.close()
      chosenSpy.clear()
      unifiedSpy.clear()
    }

    function cleanup() {
      switcher.close()
    }

    function test_the_combined_row_is_offered_only_when_there_is_more_than_one() {
      compare(switcher.unifiedOffered, true)
      compare(switcher.rowOffset, 1)
      compare(switcher.rowCount, 4, "three mailboxes and the row for all of them")

      switcher.accounts = oneMailbox
      compare(switcher.unifiedOffered, false,
        "one mailbox has nothing to combine")
      compare(switcher.rowOffset, 0)
      compare(switcher.rowCount, 1)

      switcher.accounts = []
      compare(switcher.unifiedOffered, false)
      compare(switcher.rowCount, 0)
    }

    function test_the_cursor_walks_the_combined_row_with_the_rest() {
      switcher.openCentered()
      compare(switcher.cursorIndex, 1)

      switcher.moveCursor(-1)
      compare(switcher.cursorIndex, 0, "up from the first mailbox is the combined row")

      switcher.moveCursor(-1)
      compare(switcher.cursorIndex, 3, "and up from there wraps to the last mailbox")

      switcher.moveCursor(1)
      compare(switcher.cursorIndex, 0, "which wraps back onto the combined row")
    }

    function test_opening_rests_on_the_combined_row_when_that_is_what_is_in_use() {
      switcher.unifiedActive = true
      switcher.openCentered()
      compare(switcher.cursorIndex, 0)
    }

    function test_with_one_mailbox_the_cursor_never_leaves_it() {
      switcher.accounts = oneMailbox
      switcher.openCentered()
      compare(switcher.cursorIndex, 0)
      switcher.moveCursor(1)
      compare(switcher.cursorIndex, 0, "one row wraps onto itself")
    }

    function test_choosing_a_mailbox_reports_its_own_index_not_its_row() {
      switcher.openCentered()
      switcher.cursorIndex = 1
      switcher.chooseCursor()

      compare(unifiedSpy.count, 0)
      compare(chosenSpy.count, 1)
      compare(chosenSpy.signalArguments[0][0], 0,
        "the first mailbox is account 0 even though it is row 1")

      chosenSpy.clear()
      switcher.openCentered()
      switcher.cursorIndex = 3
      switcher.chooseCursor()
      compare(chosenSpy.signalArguments[0][0], 2, "the last mailbox is account 2")
    }

    function test_choosing_the_combined_row_asks_for_every_mailbox() {
      switcher.openCentered()
      switcher.cursorIndex = 0
      switcher.chooseCursor()

      compare(chosenSpy.count, 0, "no single mailbox was chosen")
      compare(unifiedSpy.count, 1)
    }

    function test_with_one_mailbox_row_zero_is_account_zero() {
      switcher.accounts = oneMailbox
      switcher.openCentered()
      switcher.cursorIndex = 0
      switcher.chooseCursor()

      compare(unifiedSpy.count, 0, "one mailbox is never the combined view")
      compare(chosenSpy.count, 1)
      compare(chosenSpy.signalArguments[0][0], 0)
    }

    function test_a_cursor_off_the_end_chooses_nothing() {
      switcher.openCentered()
      switcher.cursorIndex = 99
      switcher.chooseCursor()
      compare(chosenSpy.count, 0)
      compare(unifiedSpy.count, 0)
    }

    // Invariant: unified viewing leaves a sending account active underneath; only the combined row is in use.
    function test_only_one_row_is_drawn_as_the_one_in_use() {
      switcher.openCentered()
      var rows = accountRows()
      compare(rows.length, 3)
      compare(rows[0].inUse, true, "the active account is in use on its own")
      compare(rows[1].inUse, false)

      switcher.unifiedActive = true
      compare(rows[0].inUse, false,
        "the account stays active underneath but is no longer what is read")
      compare(rows[1].inUse, false)
      compare(rows[2].inUse, false)
    }

    function test_the_open_menu_answers_its_own_keys() {
      switcher.openCentered()
      compare(switcher.opened, true)
      compare(switcher.cursorIndex, 1)

      keyClick(Qt.Key_Down)
      compare(switcher.cursorIndex, 2, "Down moves down inside the popup")

      keyClick(Qt.Key_K, Qt.ControlModifier)
      compare(switcher.cursorIndex, 1, "and so does Ctrl+K, for vim hands; a bare k is a letter now")

      keyClick(Qt.Key_Up)
      compare(switcher.cursorIndex, 0, "and the arrows reach the combined row too")

      keyClick(Qt.Key_Return)
      compare(unifiedSpy.count, 1, "Enter takes the row the cursor is on")
      compare(switcher.opened, false, "and closes the menu")
    }

    // Invariant: digits remain searchable mailbox text because these rows have no numeric shortcuts.
    function test_digits_and_blanks_are_typing() {
      switcher.openCentered()
      compare(switcher.cursorIndex, 1, "the mailbox in use")
      keyClick(Qt.Key_2)
      compare(switcher.query, "2")
      compare(chosenSpy.count, 0)
      compare(unifiedSpy.count, 0)
      keyClick(Qt.Key_Backspace)
      compare(switcher.query, "")
      compare(switcher.cursorIndex, 1, "back on the mailbox in use, not the combined row")
      keyClick(Qt.Key_Space)
      compare(switcher.unifiedOffered, true, "a space is nothing typed")
      compare(switcher.cursorIndex, 1)
      keyClick(Qt.Key_Return)
      compare(unifiedSpy.count, 0)
      compare(chosenSpy.count, 1)
      compare(chosenSpy.signalArguments[0][0], 0)
    }

    function test_many_mailboxes_keep_the_cursor_and_management_actions_in_view() {
      var mailboxes = []
      for (var mailboxIndex = 0; mailboxIndex < 20; mailboxIndex++)
        mailboxes.push({ id: String(mailboxIndex), email: "mailbox-" + mailboxIndex + "@example.test",
          active: mailboxIndex === 19, signedIn: true })
      switcher.accounts = mailboxes
      switcher.openCentered()
      tryCompare(switcher, "opened", true)
      wait(20)
      var rows = accountRows()
      compare(rows.length, 20)
      var lastRow = rows[19]
      var lastPosition = lastRow.mapToItem(host, 0, 0)
      verify(lastPosition.y >= 0, "active account is above the window")
      verify(lastPosition.y + lastRow.height <= host.height, "active account is below the window")
      keyClick(Qt.Key_Down)
      compare(switcher.cursorIndex, 0)
      keyClick(Qt.Key_Down)
      compare(switcher.cursorIndex, 1)
      var firstPosition = rows[0].mapToItem(host, 0, 0)
      verify(firstPosition.y >= 0 && firstPosition.y + rows[0].height <= host.height,
        "wrapped keyboard cursor is outside the window")
      keyClick(Qt.Key_Tab)
      var focused = host.Window.window.activeFocusItem
      compare(focused.text, "Add a mailbox...")
      var actionPosition = focused.mapToItem(host, 0, 0)
      verify(actionPosition.y >= 0 && actionPosition.y + focused.height <= host.height,
        "focused management action is outside the window")
    }

    function test_typing_finds_a_mailbox_by_name_or_address() {
      switcher.openCentered()
      compare(switcher.rowCount, 4)
      keyClick(Qt.Key_W); keyClick(Qt.Key_O); keyClick(Qt.Key_R)
      compare(switcher.query, "wor")
      compare(switcher.unifiedOffered, false, "no combined row while typing")
      compare(switcher.rowCount, 1)
      compare(switcher.cursorIndex, 0)
      keyClick(Qt.Key_Return)
      compare(chosenSpy.count, 1)
      compare(chosenSpy.signalArguments[0][0], 1, "Work is the second mailbox")
      compare(switcher.opened, false)

      switcher.openCentered()
      compare(switcher.query, "", "a fresh opening starts clean")
      keyClick(Qt.Key_N); keyClick(Qt.Key_E); keyClick(Qt.Key_T)
      compare(switcher.rowCount, 1, "an address is searched too")
      keyClick(Qt.Key_Return)
      compare(chosenSpy.signalArguments[1][0], 1)
    }
  }
}

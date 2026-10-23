import QtQuick 2.15
import QtTest 1.3
import qs.Commons as Commons
import "../../components" as Mail

// Invariant: nested tap handlers can both receive a tap; folding must not emit navigation.
Item {
  width: 400
  height: 600

  property var labels: [
    { id: "Work", name: "Work", rawName: "Work", delimiter: "/", unread: 0 },
    { id: "Work/2026", name: "Work/2026", rawName: "Work/2026", delimiter: "/", unread: 3 }
  ]
  property var mailService: ({
    labels: labels, mailboxes: [{ key: "inbox", label: "Inbox", icon: "inbox" }],
    collapsedFolders: [], rawQuery: "", mailboxKey: "inbox", searchQuery: "", providerId: "gmail"
  })

  Mail.MailboxSidebar {
    id: sidebar
    width: 220
    height: 600
    service: mailService
    textColor: Commons.Color.foreground
    accentColor: Commons.Color.accent
    dimColor: Commons.Color.foreground
    panelFontFamily: "monospace"
    slots: [{ kind: "mailbox", key: "inbox" }]
  }

  SignalSpy { id: folded; target: sidebar; signalName: "folderToggled" }
  SignalSpy { id: opened; target: sidebar; signalName: "labelSelected" }
  SignalSpy { id: mailbox; target: sidebar; signalName: "mailboxSelected" }

  TestCase {
    name: "SidebarFold"
    when: windowShown

    function visibleNamed(item, name, matches) {
      if (item.objectName === name && item.visible) matches.push(item)
      var children = item.children || []
      for (var index = 0; index < children.length; index++) visibleNamed(children[index], name, matches)
      return matches
    }

    function textItem(item, value) {
      if (item.text === value && item.textFormat !== undefined) return item
      var children = item.children || []
      for (var index = 0; index < children.length; index++) {
        var found = textItem(children[index], value)
        if (found) return found
      }
      return null
    }

    function init() {
      folded.clear(); opened.clear(); mailbox.clear()
      sidebar.numbersVisible = false
      sidebar.collapsed = false
    }

    function test_the_chevron_folds_without_opening() {
      var folds = visibleNamed(sidebar, "fold", [])
      compare(folds.length, 1, "only the parent carries a chevron")
      var fold = folds[0]
      mouseClick(fold, fold.width / 2, fold.height / 2)
      compare(folded.count, 1, "the fold was asked for")
      compare(folded.signalArguments[0][0], "Work")
      compare(opened.count, 0, "and nothing opened")
      compare(mailbox.count, 0)
    }

    function test_the_name_opens_without_folding() {
      var name = textItem(sidebar, "Work")
      verify(name !== null)
      mouseClick(name, 2, name.height / 2)
      compare(opened.count, 1, "the label opened")
      compare(opened.signalArguments[0][0], "Work")
      compare(folded.count, 0, "and nothing folded")
    }

    function test_a_child_row_opens_by_its_id() {
      var name = textItem(sidebar, "2026")
      verify(name !== null, "the child is drawn by its leaf name")
      mouseClick(name, 2, name.height / 2)
      compare(opened.count, 1)
      compare(opened.signalArguments[0][0], "Work/2026", "opened by the server's id, not the leaf")
      compare(folded.count, 0)
    }

    function test_shortcut_number_is_an_informational_chip() {
      sidebar.collapsed = true
      sidebar.numbersVisible = true
      var chip = visibleNamed(sidebar, "mailbox-shortcut-chip", [])[0]
      verify(chip, "the numbered mailbox draws its shortcut hint")
      verify(chip.x >= chip.parent.width / 2, "hint stays in the right corner")
      verify(chip.y < chip.parent.height / 4, "hint stays at the top")
      verify(chip.height < chip.parent.height / 2, "hint is smaller than the row icon")
      verify(visibleNamed(sidebar, "mailbox-entry-icon", [])[0].visible, "modifier preserves mailbox icon")
      verify(chip.color.a < Commons.Style.selectedFillFor(Commons.Color.foreground, Commons.Color.accent).a,
        "a shortcut hint must not use the much heavier selected-state fill")
    }
  }
}

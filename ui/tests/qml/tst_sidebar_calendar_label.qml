import QtQuick 2.15
import QtTest 1.3
import qs.Commons as Commons
import "../../components" as Mail
import "../../settings"
import "../../settings/Display.js" as Display

// Invariant: the open rail names the calendar without cutting it short at any text size, and its
// tooltip gives the app's whole name.
Item {
  width: 600
  height: 600

  property var mailService: ({
    labels: [], mailboxes: [{ key: "inbox", label: "Inbox", icon: "inbox" }],
    collapsedFolders: [], rawQuery: "", mailboxKey: "inbox", searchQuery: "", providerId: "gmail"
  })

  Mail.MailboxSidebar {
    id: sidebar
    width: MailStyle.space(148)
    height: 600
    service: mailService
    textColor: Commons.Color.foreground
    accentColor: Commons.Color.accent
    dimColor: Commons.Color.foreground
    panelFontFamily: "monospace"
    slots: [{ kind: "mailbox", key: "inbox" }]
  }

  TestCase {
    name: "SidebarCalendarLabel"
    when: windowShown

    function find(item, test) {
      if (test(item)) return item
      var children = item.data || item.children || []
      for (var index = 0; index < children.length; index++) {
        var found = find(children[index], test)
        if (found) return found
      }
      return null
    }

    function cleanup() { MailStyle.preferences = Display.normalize({}) }

    function test_the_calendar_is_named_in_full_at_every_text_size() {
      var label = find(sidebar, function(item) { return item.text === "Calendar..." && item.textFormat !== undefined })
      verify(label, "the rail names the calendar")
      var sizes = [9, 11, 13, 17, 20, 24]
      for (var index = 0; index < sizes.length; index++) {
        MailStyle.preferences = Display.normalize({ interfaceSize: sizes[index] })
        wait(20)
        verify(label.visible)
        verify(!label.truncated, "the name is whole at " + sizes[index] + " points")
      }
    }

    function test_the_tooltip_gives_the_app_its_whole_name() {
      var tip = find(sidebar, function(item) {
        return item.objectName === "label-tooltip" && String(item.text).indexOf("Calendar") >= 0
      })
      verify(tip, "the calendar row has a tooltip")
      compare(tip.text, "Magpie Calendar...")
    }
  }
}

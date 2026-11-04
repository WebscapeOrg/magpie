import QtQuick
import QtTest
import qs.Commons
import "../../components" as Omamail
import "../../settings"
import "../../settings/Display.js" as Display

// Invariant: a menu that scrolls shows its bar at rest, beside its entries and inside its frame, as Magpie
// Calendar's menu does; a menu that fits shows no bar and keeps its usual padding, at every text size.
Item {
  id: page
  width: 420
  height: 520

  Omamail.AppMenu {
    id: appMenu
    anchors.fill: parent
    textColor: Qt.rgba(0.1, 0.1, 0.1, 1)
    popupBackgroundColor: Qt.rgba(0.95, 0.95, 0.95, 1)
    popupBorderColor: Qt.rgba(0.6, 0.6, 0.6, 1)
    panelFontFamily: "monospace"
    signedIn: true
    canOpenWebInbox: true
    accountCount: 2
    canQuit: true
  }

  TestCase {
    name: "AppMenuScroll"
    when: windowShown

    function findItem(item, test) {
      if (!item) return null
      if (test(item)) return item
      for (var index = 0; index < item.children.length; index++) {
        var found = findItem(item.children[index], test)
        if (found) return found
      }
      return null
    }
    function resize(height) {
      var window = page.Window.window
      window.height = height
      page.height = height
    }
    function textSize(size, scale) {
      Style.spacingScale = scale
      MailStyle.preferences = Display.normalize({interfaceSize: size})
    }
    function init() { failOnWarning(/Binding loop/) }
    function cleanup() {
      appMenu.close()
      textSize(17, 1)
      resize(520)
    }

    function open() {
      appMenu.openAt(10, 10)
      tryCompare(appMenu, "opened", true)
      wait(30)
      return findChild(appMenu, "app-menu-popup")
    }
    function barOf(menu) {
      return findItem(menu.contentItem.parent, function(item) { return item.objectName === "app-menu-scroll" })
    }
    // The window height at which the menu just fits: its entries, its padding and the margin it keeps.
    function fittingHeight() {
      var menu = open()
      var height = menu.contentItem.contentHeight + menu.topPadding + menu.bottomPadding + MailStyle.space(16)
      appMenu.close()
      tryCompare(appMenu, "opened", false)
      return height
    }
    function check(menu, scrolls, tag) {
      var list = menu.contentItem
      var bar = barOf(menu)
      verify(bar !== null, "the menu has its scroll bar")
      compare(list.contentHeight > list.height + 1, scrolls, tag + ": the entries are cut off exactly when it should scroll: "
        + list.contentHeight + " in " + list.height)
      compare(bar.visible, scrolls, tag + ": the bar is on exactly when the menu scrolls")
      if (!scrolls) {
        compare(menu.rightPadding, menu.leftPadding, tag + ": a menu that fits keeps its usual padding")
        return
      }
      verify(bar.contentItem.visible && bar.contentItem.opacity > 0 && bar.size < 1,
        tag + ": the bar shows there is more before anything moves")
      verify(bar.x >= list.x + list.width + 1,
        tag + ": the bar is beside the entries with a gap: " + bar.x + " from " + (list.x + list.width))
      verify(bar.x + bar.width <= menu.width - 1 + 0.5,
        tag + ": the bar is inside the menu's frame: " + (bar.x + bar.width) + " in " + menu.width)
      verify(bar.y >= list.y - 0.5 && bar.y + bar.height <= list.y + list.height + 0.5,
        tag + ": the bar runs beside the entries: " + bar.y + " + " + bar.height + " beside " + list.y + " + " + list.height)
    }

    // A menu that just fits, or has room to spare, shows no bar; one a few pixels short, or far short, shows it,
    // at every text size and at the shell's 7/6 spacing.
    function test_the_bar_shows_exactly_when_the_menu_scrolls_data() {
      var rows = []
      for (var size of [8, 12, 15, 17, 20, 25, 28, 33, 36]) {
        for (var scale of [1, 7 / 6]) {
          var name = size + " pt at " + (scale === 1 ? "1" : "7/6")
          rows.push({tag: name + ", room to spare", size: size, scale: scale, extra: 120, scrolls: false})
          rows.push({tag: name + ", just fits", size: size, scale: scale, extra: 0, scrolls: false})
          rows.push({tag: name + ", a few pixels short", size: size, scale: scale, extra: -4, scrolls: true})
          rows.push({tag: name + ", far short", size: size, scale: scale, extra: -300, scrolls: true})
        }
      }
      return rows
    }
    function test_the_bar_shows_exactly_when_the_menu_scrolls(data) {
      textSize(data.size, data.scale)
      resize(1600)
      resize(fittingHeight() + data.extra)
      check(open(), data.scrolls, data.tag)
    }

    // A change of text size while the menu is open lays it out again without a binding loop, and the bar
    // follows whether it now scrolls.
    function test_a_text_size_change_while_open_keeps_the_bar_right_data() {
      return [{tag: "tall window", height: 1600}, {tag: "short window", height: 300}]
    }
    function test_a_text_size_change_while_open_keeps_the_bar_right(data) {
      resize(data.height)
      var menu = open()
      for (var size of [12, 36, 8, 20, 15, 17]) {
        textSize(size, 1)
        wait(20)
        var needed = menu.contentItem.contentHeight + menu.topPadding + menu.bottomPadding
        check(menu, needed > menu.height + 1, data.tag + " at " + size + " pt")
      }
    }

    // Back from the help page in a menu that scrolls shows the Help entry the cursor returns to, so Return
    // never acts on an entry out of view, whether Help was chosen with the keys or the mouse.
    function test_back_from_help_shows_the_entry_the_cursor_is_on_data() {
      return [{tag: "keys, small window", short: 300, how: "keys"}, {tag: "keys, mid window", short: 260, how: "keys"},
              {tag: "mouse, small window", short: 300, how: "mouse"}, {tag: "mouse, mid window", short: 260, how: "mouse"},
              {tag: "called, mid window", short: 260, how: "called"}]
    }
    function test_back_from_help_shows_the_entry_the_cursor_is_on(data) {
      resize(data.short === 300 ? 300 : fittingHeight() - data.short)
      var menu = open()
      var list = menu.contentItem
      var help = findChild(appMenu, "app-menu-help")
      if (data.how === "called") {
        appMenu.showHelp()
      } else if (data.how === "mouse") {
        list.contentY = list.contentHeight - list.height
        wait(20)
        var spot = help.mapToItem(page, help.width / 2, help.height / 2)
        mouseClick(page, spot.x, spot.y)
      } else {
        for (var step = 0; step < appMenu.menuRows.length && appMenu.menuRows[appMenu.cursorIndex] !== help; step++)
          keyClick(Qt.Key_Down)
        compare(appMenu.menuRows[appMenu.cursorIndex], help)
        keyClick(Qt.Key_Right)
      }
      tryCompare(appMenu, "helpPage", true)
      keyClick(Qt.Key_Left)
      compare(appMenu.helpPage, false)
      wait(30)
      compare(appMenu.menuRows[appMenu.cursorIndex], help)
      var at = help.mapToItem(list, 0, 0)
      verify(at.y >= -0.5 && at.y + help.height <= list.height + 0.5,
        "the Help entry is in view: " + at.y + " + " + help.height + " in " + list.height)
    }

    // A menu opens at its first entry, wherever the last one was scrolled to.
    function test_a_menu_opens_at_its_first_entry() {
      resize(300)
      var menu = open()
      var list = menu.contentItem
      list.contentY = list.contentHeight - list.height
      appMenu.close()
      tryCompare(appMenu, "opened", false)
      menu = open()
      compare(menu.contentItem.contentY, 0)
    }

    // The bar is drawn: its handle is a different colour from the menu's background beside it.
    function test_the_bar_is_painted() {
      resize(300)
      var menu = open()
      var bar = barOf(menu)
      verify(bar.visible)
      wait(250)
      var surface = menu.contentItem.parent
      var image = grabImage(surface)
      var middle = bar.contentItem.mapToItem(surface, bar.contentItem.width / 2, bar.contentItem.height / 2)
      var handle = image.pixel(Math.round(middle.x), Math.round(middle.y))
      var beside = image.pixel(Math.round(bar.x - 2), Math.round(middle.y))
      verify(!Qt.colorEqual(handle, beside), "the handle paints over the menu's background: " + handle + " beside " + beside)
    }
  }
}

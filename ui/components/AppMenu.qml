import QtQuick
import "../controls" as Widgets
import "../settings"
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Menu.js" as Menu

Item {
  id: root

  required property color textColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily
  property bool signedIn: false
  property bool canOpenWebInbox: false
  // Invariant: the account switcher remains reachable through this menu when the sidebar is hidden.
  property int accountCount: 1
  property bool showTrigger: false
  // Invariant: only the standalone host may offer Quit; a plugin must not terminate its shell.
  property bool canQuit: false
  property bool singlePane: true
  property bool hasAgent: true
  property bool overviewsPaused: false
  signal overviewPauseRequested()
  signal refreshImagesRequested()
  signal snoozedRequested()
  signal layoutRequested()
  signal refreshRequested()
  signal aiRequested()
  signal overviewRetryRequested()
  readonly property bool opened: menu.opened

  property real anchorX: 0
  property real anchorY: 0
  property int cursorIndex: -1
  property bool helpPage: false
  readonly property var menuRows: helpPage ? [helpBackRow, searchHelpRow, shortcutsRow]
    : [snoozedRow, layoutRow, refreshRow, aiToolsRow, refreshImagesRow, pauseOverviewRow, overviewRow, inboxRow, calendarRow, markRow, webRow,
      switchRow, settingsRow, helpRow, projectRow, authorRow, quitRow]

  function openAt(sceneX, sceneY) {
    var local = root.mapFromGlobal(sceneX, sceneY)
    anchorX = local.x
    anchorY = local.y
    menu.open()
    place()
  }

  // Invariant: popup content is created lazily; position again after its first height is known.
  function place() {
    if (!menu.visible) return
    var tall = menu.height > 0 ? menu.height : menu.implicitHeight
    var placed = Menu.position(anchorX, anchorY, menu.width, tall, root.width, root.height)
    menu.x = placed.x
    menu.y = placed.y
  }

  function moveCursor(step) {
    cursorIndex = Menu.nextSelectable(menuRows, cursorIndex, step)
    revealCursor()
  }
  function revealCursor() {
    if (cursorIndex < 0) return
    var row = menuRows[cursorIndex]
    var top = row.mapToItem(menuItems, 0, 0).y
    if (top < menuScroll.contentY) menuScroll.contentY = top
    else if (top + row.height > menuScroll.contentY + menuScroll.height) menuScroll.contentY = top + row.height - menuScroll.height
  }
  function runCursor() { if (cursorIndex >= 0) menuRows[cursorIndex].activated() }

  function close() { menu.close() }
  function showHelp() {
    helpPage = true
    cursorIndex = 1
    menuScroll.contentY = 0
    menuItems.forceActiveFocus()
  }
  function showMain() {
    helpPage = false
    cursorIndex = menuRows.indexOf(helpRow)
    menuItems.forceActiveFocus()
    Qt.callLater(revealCursor)
  }

  signal markAllReadRequested()
  signal openWebRequested()
  signal shortcutsRequested()
  signal searchHelpRequested()
  signal inboxRequested()
  signal calendarRequested()
  signal setupRequested()
  signal switchAccountRequested()
  signal projectRequested()
  signal authorRequested()
  signal quitRequested()

  anchors.fill: root.showTrigger ? undefined : parent
  implicitWidth: root.showTrigger ? MailStyle.space(24) : 0
  implicitHeight: root.showTrigger ? MailStyle.space(24) : 0
  z: 40

  Widgets.Button {
    id: menuButton
    visible: root.showTrigger
    anchors.fill: parent
    foreground: root.textColor
    bordered: false
    onClicked: menu.opened ? menu.close() : menu.open()
    Accessible.role: Accessible.Button
    Accessible.name: "Menu"
    ActionIcon {
      anchors.centerIn: parent
      name: "more"
      color: menuButton.foreground
      iconSize: Style.font.icon
    }
  }

  QQC.Popup {
    id: menu
    width: Math.min(root.width, MailStyle.space(260))
    implicitHeight: Math.min(menuItems.implicitHeight + MailStyle.space(8), root.height - MailStyle.space(16))
    padding: MailStyle.space(4)
    modal: false
    focus: true
    closePolicy: QQC.Popup.CloseOnPressOutside | (root.helpPage ? 0 : QQC.Popup.CloseOnEscape)
    onHeightChanged: root.place()
    onOpened: {
      // Invariant: opening the menu must not imply that Inbox is the current view.
      root.helpPage = false
      root.cursorIndex = -1
      root.place()
    }
    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }
    contentItem: Flickable {
      id: menuScroll
      contentHeight: menuItems.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
      Column {
      id: menuItems
      width: menuScroll.width
      spacing: MailStyle.space(2)

      Row {
        width: parent.width
        height: MailStyle.space(44)
        spacing: MailStyle.space(8)
        leftPadding: MailStyle.space(10)
        MagpieLogo {
          anchors.verticalCenter: parent.verticalCenter
          width: MailStyle.space(26)
          height: width
          foreground: root.textColor
          accent: root.textColor
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.helpPage ? "Help" : "Magpie"
          textFormat: Text.PlainText
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.title
        }
      }
      MenuSeparatorLine { width: parent.width; lineColor: root.textColor }

      focus: true
      Keys.onShortcutOverride: function(event) {
        if (event.modifiers !== Qt.NoModifier) return
        if ([Qt.Key_J, Qt.Key_Down, Qt.Key_K, Qt.Key_Up, Qt.Key_Return,
            Qt.Key_Enter, Qt.Key_Space, Qt.Key_O].indexOf(event.key) >= 0
            || (root.helpPage && (event.key === Qt.Key_Left || event.key === Qt.Key_Escape))
            || (!root.helpPage && event.key === Qt.Key_Right
              && root.menuRows[root.cursorIndex] === helpRow)) event.accepted = true
      }
      Keys.onPressed: function(event) {
        if (event.modifiers !== Qt.NoModifier) return
        if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
          root.moveCursor(1); event.accepted = true
        } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
          root.moveCursor(-1); event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Space || event.key === Qt.Key_O) {
          root.runCursor(); event.accepted = true
        } else if (root.helpPage && (event.key === Qt.Key_Left || event.key === Qt.Key_Escape)) {
          root.showMain(); event.accepted = true
        } else if (!root.helpPage && event.key === Qt.Key_Right
            && root.menuRows[root.cursorIndex] === helpRow) {
          root.showHelp(); event.accepted = true
        }
      }

      Column {
      visible: !root.helpPage
      width: parent.width
      spacing: MailStyle.space(2)
      MenuRow {
        id: snoozedRow
        text: "Snoozed mail..."
        onActivated: { menu.close(); root.snoozedRequested() }
      }
      MenuRow {
        id: layoutRow
        objectName: "layout-toggle"
        text: root.singlePane ? "Split view" : "Single pane"
        onActivated: { menu.close(); root.layoutRequested() }
      }
      MenuRow {
        id: refreshRow
        objectName: "refresh-button"
        text: "Check mail"
        enabled: root.signedIn
        onActivated: { menu.close(); root.refreshRequested() }
      }
      MenuRow {
        id: aiToolsRow
        objectName: "app-menu-ai"
        text: "AI tools..."
        visible: root.hasAgent
        onActivated: { menu.close(); root.aiRequested() }
      }
      MenuRow {
        id: refreshImagesRow
        text: "Refresh sender images"
        enabled: root.signedIn
        onActivated: { menu.close(); root.refreshImagesRequested() }
      }
      MenuRow {
        id: pauseOverviewRow
        text: root.overviewsPaused ? "Resume AI overviews" : "Pause new AI overviews"
        visible: root.hasAgent
        onActivated: { menu.close(); root.overviewPauseRequested() }
      }
      MenuRow {
        id: overviewRow
        text: "Retry AI overviews"
        visible: root.hasAgent
        onActivated: { menu.close(); root.overviewRetryRequested() }
      }
      MenuRow {
        id: inboxRow
        text: "Inbox"
        onActivated: { menu.close(); root.inboxRequested() }
      }
      MenuRow {
        id: calendarRow
        text: "Skylark..."
        onActivated: { menu.close(); root.calendarRequested() }
      }
      MenuSeparatorLine {
        width: menu.width - menu.leftPadding - menu.rightPadding
        lineColor: root.textColor
      }

      MenuRow {
        id: markRow
        text: "Mark these read"
        enabled: root.signedIn
        onActivated: { menu.close(); root.markAllReadRequested() }
      }
      MenuRow {
        id: webRow
        text: "Open web inbox..."
        visible: root.canOpenWebInbox
        enabled: root.signedIn
        onActivated: { menu.close(); root.openWebRequested() }
      }

      MenuRow {
        id: switchRow
        text: "Switch account..."
        visible: root.accountCount > 1
        onActivated: { menu.close(); root.switchAccountRequested() }
      }
      MenuRow {
        id: settingsRow
        objectName: "app-menu-settings"
        text: "Settings..."
        onActivated: { menu.close(); root.setupRequested() }
      }
      MenuSeparatorLine {
        width: menu.width - menu.leftPadding - menu.rightPadding
        lineColor: root.textColor
      }

      MenuRow {
        id: helpRow
        objectName: "app-menu-help"
        text: "Help..."
        onActivated: root.showHelp()
      }
      MenuRow {
        id: projectRow
        text: "GitHub..."
        onActivated: { menu.close(); root.projectRequested() }
      }
      MenuRow {
        id: authorRow
        text: "Twitter..."
        onActivated: { menu.close(); root.authorRequested() }
      }
      MenuSeparatorLine {
        visible: root.canQuit
        width: menu.width - menu.leftPadding - menu.rightPadding
        lineColor: root.textColor
      }
      MenuRow {
        id: quitRow
        objectName: "app-menu-quit"
        text: "Quit"
        visible: root.canQuit
        onActivated: { menu.close(); root.quitRequested() }
      }
      }
      Column {
        visible: root.helpPage
        width: parent.width
        spacing: MailStyle.space(2)
        MenuRow {
          id: helpBackRow
          objectName: "app-menu-help-back"
          text: "Back"
          onActivated: root.showMain()
        }
        MenuSeparatorLine { width: parent.width; lineColor: root.textColor }
        MenuRow {
          id: searchHelpRow
          objectName: "app-menu-search-help"
          text: "Search..."
          onActivated: { menu.close(); root.searchHelpRequested() }
        }
        MenuRow {
          id: shortcutsRow
          objectName: "app-menu-keyboard-help"
          text: "Keyboard..."
          onActivated: { menu.close(); root.shortcutsRequested() }
        }
      }
      }
    }
  }

  component MenuRow: MenuActionRow {
    id: actionRow
    width: menu.width - menu.leftPadding - menu.rightPadding
    textColor: root.textColor
    panelFontFamily: root.panelFontFamily
    collection: root.menuRows
    cursorIndex: root.cursorIndex
    Keys.onShortcutOverride: function(event) {
      if (event.modifiers === Qt.NoModifier && (event.key === Qt.Key_Return
          || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)) event.accepted = true
    }
    Keys.onEnterPressed: if (enabled) actionRow.activated()
  }
}

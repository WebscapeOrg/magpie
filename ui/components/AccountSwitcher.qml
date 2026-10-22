import QtQuick
import "../controls" as Widgets
import "../settings"
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "../account/Model.js" as Model
import "Menu.js" as Menu

Item {
  id: root

  required property color textColor
  required property color accentColor
  required property color urgentColor
  required property color dimColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  property var accounts: []
  property string query: ""
  readonly property var shownAccounts: Model.filterRows(accounts, query)
  onQueryChanged: if (query.trim() === "") restCursorOnActive(); else cursorIndex = 0

  readonly property bool opened: menu.opened

  // Docs: popup delegates are in the overlay, so expose their content item for geometry tests.
  readonly property alias menuRows: rows

  // Invariant: keyboard position must not follow passive hover; Qt replays hover when content moves
  // beneath a stationary pointer.
  property int cursorIndex: 0
  onCursorIndexChanged: revealCursor()

  property bool unifiedActive: false

  readonly property int accountRowCount: root.shownAccounts.length
  readonly property bool unifiedOffered: (root.accounts ? root.accounts.length : 0) > 1 && root.query.trim() === ""
  readonly property int rowOffset: unifiedOffered ? 1 : 0
  readonly property int rowCount: accountRowCount + rowOffset

  signal accountChosen(int index)
  signal unifiedChosen()
  signal addAccountRequested()
  signal manageRequested()

  anchors.fill: parent
  z: 45

  property real anchorX: 0
  property real anchorY: 0

  function openAt(sceneX, sceneY) {
    var local = root.mapFromGlobal(sceneX, sceneY)
    anchorX = local.x
    anchorY = local.y
    menu.open()
    place()
  }

  // Invariant: popup content is lazy; re-place it after the first height calculation and subsequent
  // filtering.
  function place() {
    if (!menu.visible) return
    var popupHeight = menu.height > 0 ? menu.height : menu.implicitHeight
    var position = Menu.position(anchorX, anchorY, menu.width, popupHeight, root.width, root.height)
    menu.x = position.x
    menu.y = position.y
  }

  function openCentered() {
    anchorX = Math.max(0, (root.width - menu.width) / 2)
    anchorY = Math.max(0, (root.height - menu.implicitHeight) / 2)
    menu.open()
    place()
  }

  function close() { menu.close() }

  function moveCursor(delta) {
    if (root.rowCount === 0) return
    cursorIndex = Model.wrappedIndex(cursorIndex, delta, root.rowCount)
  }

  function revealCursor() {
    var cursorRow = root.unifiedOffered && root.cursorIndex === 0
      ? unifiedRow : accountRepeater.itemAt(root.cursorIndex - root.rowOffset)
    if (!cursorRow) return
    var rowHeight = cursorRow.height
    var cursorTop = cursorRow.y
    var viewportTop = accountsViewport.contentY
    if (cursorTop < viewportTop) accountsViewport.contentY = cursorTop
    else if (cursorTop + rowHeight > viewportTop + accountsViewport.height)
      accountsViewport.contentY = cursorTop + rowHeight - accountsViewport.height
    accountsViewport.contentY = Math.max(0, Math.min(accountsViewport.contentY,
      accountsViewport.contentHeight - accountsViewport.height))
  }

  function chooseCursor() {
    if (cursorIndex < 0 || cursorIndex >= root.rowCount) return
    menu.close()
    if (root.unifiedOffered && cursorIndex === 0) {
      root.unifiedChosen()
      return
    }
    root.accountChosen(root.shownAccounts[cursorIndex - root.rowOffset].sourceIndex)
  }

  function restCursorOnActive() {
    if (root.unifiedActive && root.unifiedOffered) {
      cursorIndex = 0
      return
    }
    // Invariant: query-change handlers run before shownAccounts necessarily updates; derive the new
    // filtered rows directly.
    var accounts = Model.filterRows(root.accounts, root.query)
    var offset = (root.accounts ? root.accounts.length : 0) > 1 && root.query.trim() === "" ? 1 : 0
    for (var entryIndex = 0; entryIndex < accounts.length; entryIndex++) {
      if (accounts[entryIndex].active) { cursorIndex = entryIndex + offset; return }
    }
    cursorIndex = 0
  }

  QQC.Popup {
    id: menu
    width: Math.min(MailStyle.space(250), root.width)
    implicitHeight: rows.implicitHeight + MailStyle.space(8)
    padding: MailStyle.space(4)
    modal: false
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    onHeightChanged: root.place()
    onOpened: {
      search.reset()
      root.restCursorOnActive()
      root.place()
      search.takeFocus()
      root.revealCursor()
    }
    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }

    // Invariant: QQC.Popup consumes window shortcuts; its focused search field must handle
    // navigation locally (tst_account_switcher).
    contentItem: Column {
      id: rows
      spacing: MailStyle.space(2)
      // Invariant: keys from popup padding still forward to its search field.
      Keys.forwardTo: [search]

      SwitcherSearch {
        id: search
        width: menu.width - menu.leftPadding - menu.rightPadding
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "Type a name or address"
        onTextChanged: root.query = text
        onMoved: function(delta) { root.moveCursor(delta) }
        onChosen: root.chooseCursor()
      }

      Flickable {
        id: accountsViewport
        width: parent.width
        height: Math.min(accountRows.implicitHeight, Math.max(0,
          root.height - search.height - managementRows.height - rows.spacing * 2
            - menu.topPadding - menu.bottomPadding))
        contentWidth: width
        contentHeight: accountRows.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        onHeightChanged: root.revealCursor()
        onContentHeightChanged: root.revealCursor()
        WheelScroller { view: accountsViewport }
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        Column {
          id: accountRows
          width: parent.width
          spacing: rows.spacing

          Rectangle {
            id: unifiedRow
            visible: root.unifiedOffered

            readonly property bool hasCursor: root.cursorIndex === 0

            width: menu.width - menu.leftPadding - menu.rightPadding
            implicitHeight: visible ? MailStyle.space(40) : 0
            radius: Style.cornerRadius
            color: root.unifiedActive
              ? Style.selectedFillFor(root.textColor, root.accentColor)
              : (unifiedHover.hovered || hasCursor
                ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent")
            border.width: hasCursor ? Style.normalBorderWidth : 0
            border.color: Style.hoverBorderFor(root.textColor, root.accentColor)

            Rectangle {
              id: unifiedAvatar
              anchors.left: parent.left
              anchors.leftMargin: MailStyle.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: MailStyle.space(22)
              height: width
              radius: width / 2
              color: Style.selectedFillFor(root.textColor, root.accentColor)

              ActionIcon {
                anchors.centerIn: parent
                name: "inbox"
                color: root.textColor
                iconSize: MailStyle.caption
              }
            }

            Column {
              anchors.left: unifiedAvatar.right
              anchors.leftMargin: MailStyle.space(9)
              anchors.right: parent.right
              anchors.rightMargin: MailStyle.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: MailStyle.space(1)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: Model.UNIFIED_LABEL
                color: root.textColor
                font.family: root.panelFontFamily
                font.pixelSize: MailStyle.bodySmall
                font.bold: root.unifiedActive
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.accountRowCount + " mailboxes in one list"
                color: root.dimColor
                font.family: root.panelFontFamily
                font.pixelSize: MailStyle.caption
                elide: Text.ElideRight
              }
            }

            HoverHandler { id: unifiedHover }
            TapHandler {
              onTapped: {
                menu.close()
                root.unifiedChosen()
              }
            }
          }

          Repeater {
            id: accountRepeater
            model: root.shownAccounts

            Rectangle {
              id: row
              objectName: "account-row"
              required property var modelData
              required property int index

              readonly property bool hasCursor: root.cursorIndex === row.index + root.rowOffset

              readonly property bool named: modelData.name !== undefined
                && String(modelData.name) !== ""

              readonly property string primaryText: {
                if (row.named) return String(modelData.name)
                return modelData.email !== "" ? modelData.email : "New account"
              }

              readonly property string secondaryText: {
                if (modelData.error !== undefined && modelData.error !== "")
                  return String(modelData.error)
                if (!modelData.signedIn) return "Signed out"
                if (modelData.busy) return "Checking"
                return row.named ? String(modelData.email || "") : ""
              }

              // Invariant: unified view retains an active sending account; only the unified row is
              // selected for reading.
              readonly property bool inUse: modelData.active && !root.unifiedActive

              width: menu.width - menu.leftPadding - menu.rightPadding
              implicitHeight: MailStyle.space(40)
              radius: Style.cornerRadius
              color: row.inUse
                ? Style.selectedFillFor(root.textColor, root.accentColor)
                : (rowHover.hovered || hasCursor
                  ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent")
              // Invariant: draw the keyboard cursor with a border so it remains distinct on the
              // selected account.
              border.width: hasCursor ? Style.normalBorderWidth : 0
              border.color: Style.hoverBorderFor(root.textColor, root.accentColor)

              Rectangle {
                id: rowAvatar
                anchors.left: parent.left
                anchors.leftMargin: MailStyle.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: MailStyle.space(22)
                height: width
                radius: width / 2
                color: Style.selectedFillFor(root.textColor, root.accentColor)

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: {
                    if (row.named) return String(row.modelData.name).charAt(0).toUpperCase()
                    return row.modelData.email === ""
                      ? "+" : row.modelData.email.charAt(0).toUpperCase()
                  }
                  color: root.textColor
                  font.family: root.panelFontFamily
                  font.pixelSize: MailStyle.caption
                  font.bold: true
                }
              }

              Column {
                anchors.left: rowAvatar.right
                anchors.leftMargin: MailStyle.space(9)
                anchors.right: parent.right
                anchors.rightMargin: MailStyle.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: MailStyle.space(1)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: row.primaryText
                  color: root.textColor
                  font.family: root.panelFontFamily
                  font.pixelSize: MailStyle.bodySmall
                  font.bold: row.inUse
                  elide: Text.ElideMiddle
                }

                Text {
                  width: parent.width
                  visible: text !== ""
                  textFormat: Text.PlainText
                  text: row.secondaryText
                  color: row.modelData.error !== undefined && row.modelData.error !== ""
                    ? root.urgentColor : root.dimColor
                  font.family: root.panelFontFamily
                  font.pixelSize: MailStyle.caption
                  elide: Text.ElideRight
                }
              }

              HoverHandler { id: rowHover }
              TapHandler {
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: {
                  menu.close()
                  root.accountChosen(row.modelData.sourceIndex)
                }
              }
            }
          }
        }
      }

      Column {
        id: managementRows
        width: parent.width
        spacing: rows.spacing

        Item {
          width: menu.width - menu.leftPadding - menu.rightPadding
          implicitHeight: MailStyle.space(7)

          PanelSeparator {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            foreground: root.textColor
          }
        }

        MenuRow {
          text: "Add a mailbox..."
          onActivated: {
            menu.close()
            root.addAccountRequested()
          }
        }

        MenuRow {
          text: "Manage accounts..."
          onActivated: {
            menu.close()
            root.manageRequested()
          }
        }
      }
    }
  }

  component MenuRow: Widgets.Button {
    signal activated()
    width: menu.width - menu.leftPadding - menu.rightPadding
    implicitHeight: Style.spacing.popupRowHeight
    focusable: true
    leftAlign: true
    horizontalPadding: MailStyle.space(9)
    foreground: root.textColor
    accent: root.accentColor
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.bodySmall
    onClicked: activated()
  }
}

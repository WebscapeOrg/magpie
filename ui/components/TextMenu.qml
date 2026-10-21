import QtQuick
import "../settings"
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Menu.js" as Menu

// Invariant: the host owns the platform clipboard, so Copy is emitted rather than delegated to the
// text item.
Item {
  id: root

  required property color textColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  property bool editable: false
  property var target: null
  property string link: ""
  property int cursorIndex: -1
  readonly property bool opened: menu.opened
  readonly property bool hasSelection: !!target && String(target.selectedText || "") !== ""
  readonly property var menuRows: [cutRow, copyRow, pasteRow, selectAllRow, openLinkRow, copyLinkRow]

  readonly property alias cutRow: cutRow
  readonly property alias copyRow: copyRow
  readonly property alias pasteRow: pasteRow
  readonly property alias selectAllRow: selectAllRow
  readonly property alias openLinkRow: openLinkRow
  readonly property alias copyLinkRow: copyLinkRow

  signal copyRequested(string text)
  // Invariant: the owner’s Paste path imports clipboard images before falling back to text.
  signal pasteRequested(var target)
  signal openLinkRequested(string url)

  anchors.fill: parent
  z: 50

  property real anchorX: 0
  property real anchorY: 0

  function openAt(item, sceneX, sceneY, url) {
    if (!item) return
    target = item
    link = String(url || "")
    var local = root.mapFromGlobal(sceneX, sceneY)
    anchorX = local.x
    anchorY = local.y
    menu.open()
  }

  function place() {
    if (!menu.visible) return
    var tall = menu.height > 0 ? menu.height : menu.implicitHeight
    var placed = Menu.position(anchorX, anchorY, menu.width, tall, root.width, root.height)
    menu.x = placed.x
    menu.y = placed.y
  }

  function moveCursor(step) { cursorIndex = Menu.nextSelectable(menuRows, cursorIndex, step) }
  function runCursor() { if (cursorIndex >= 0) menuRows[cursorIndex].activated() }
  function close() { menu.close() }

  function copySelection() {
    var text = hasSelection ? String(target.selectedText) : ""
    menu.close()
    if (text !== "") root.copyRequested(text)
  }

  function cutSelection() {
    if (!hasSelection) { menu.close(); return }
    var item = target
    var text = String(item.selectedText)
    var from = item.selectionStart
    var to = item.selectionEnd
    menu.close()
    root.copyRequested(text)
    item.remove(from, to)
  }

  QQC.Popup {
    id: menu
    width: MailStyle.space(180)
    implicitHeight: rows.implicitHeight + MailStyle.space(8)
    padding: MailStyle.space(4)
    modal: false
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    onHeightChanged: root.place()
    onOpened: {
      root.cursorIndex = Menu.firstSelectable(root.menuRows)
      root.place()
    }
    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }

    contentItem: Column {
      id: rows
      spacing: MailStyle.space(2)

      focus: true
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
          root.moveCursor(1); event.accepted = true
        } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
          root.moveCursor(-1); event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_O) {
          root.runCursor(); event.accepted = true
        }
      }

      MenuRow {
        id: cutRow
        visible: root.editable
        enabled: root.hasSelection
        text: "Cut"
        onActivated: root.cutSelection()
      }
      MenuRow {
        id: copyRow
        enabled: root.hasSelection
        text: "Copy"
        onActivated: root.copySelection()
      }
      MenuRow {
        id: pasteRow
        visible: root.editable
        text: "Paste"
        onActivated: { var item = root.target; menu.close(); root.pasteRequested(item) }
      }
      MenuRow {
        id: selectAllRow
        visible: root.editable
        text: "Select all"
        onActivated: { var item = root.target; menu.close(); if (item) item.selectAll() }
      }

      MenuSeparatorLine {
        visible: root.link !== ""
        width: menu.width - menu.leftPadding - menu.rightPadding
        lineColor: root.textColor
      }
      MenuRow {
        id: openLinkRow
        visible: root.link !== ""
        text: "Open link..."
        onActivated: { var url = root.link; menu.close(); root.openLinkRequested(url) }
      }
      MenuRow {
        id: copyLinkRow
        visible: root.link !== ""
        text: "Copy URL"
        onActivated: { var url = root.link; menu.close(); root.copyRequested(url) }
      }
    }
  }

  component MenuRow: MenuActionRow {
    width: menu.width - menu.leftPadding - menu.rightPadding
    textColor: root.textColor
    panelFontFamily: root.panelFontFamily
    collection: root.menuRows
    cursorIndex: root.cursorIndex
  }
}

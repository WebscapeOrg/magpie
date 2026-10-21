import QtQuick
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

  // Invariant: copy the subject selected when the menu opened, not a later message’s subject.
  property string subject: ""
  property int cursorIndex: -1
  readonly property bool opened: menu.opened
  readonly property var menuRows: [copyRow]
  readonly property alias copyRow: copyRow
  // Docs: popup geometry is exposed for placement regressions.
  readonly property alias popup: menu

  signal copyRequested(string subject)

  anchors.fill: parent
  z: 50

  property real anchorX: 0
  property real anchorY: 0

  function openAt(text, sceneX, sceneY) {
    subject = String(text || "")
    // Invariant: reject whitespace-only subjects but preserve the original spacing of copyable
    // subjects.
    if (subject.trim() === "") return
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
        id: copyRow
        text: "Copy subject"
        onActivated: { var subject = root.subject; menu.close(); root.copyRequested(subject) }
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

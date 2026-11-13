import QtQuick
import QtQuick.Controls as QQC
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Commons as Commons

// Docs: the one confirmation Magpie asks before something it cannot undo or before leaving work behind:
// deleting a label (ConfirmDeleteDialog), removing a mailbox (AccountRemovalDialog) and leaving a changed
// draft (ComposeExitDialog). It sits in the middle of the window with the question, a line on what follows,
// Cancel, and the choices after it. Magpie Calendar's ConfirmPopup is the same confirmation.
QQC.Popup {
  id: root

  property string question: ""
  property string message: ""
  // Docs: each choice is {value, label, objectName, danger}; the choices follow Cancel, in the danger colour
  // unless danger is false.
  property var choices: []
  property string cancelName: "confirm-cancel"
  // Docs: which button has the focus when the confirmation opens: -1 for Cancel, else the choice at that index.
  property int focusIndex: -1
  property color textColor: Commons.Color.foreground
  property color dimColor: Commons.Color.foreground
  property color dangerColor: Commons.Color.foreground
  property color backgroundColor: Commons.Color.background
  property color borderColor: Style.normalBorderColor
  property string fontFamily: MailStyle.family

  signal chosen(var value)

  readonly property Item window: QQC.Overlay.overlay
  // Invariant: the space around and inside the confirmation grows with the font size but never takes more
  // than a twentieth of the window on each side, so large text keeps the room it needs in a small window.
  readonly property real edge: window ? Math.min(MailStyle.space(16), Math.round(Math.min(window.width, window.height) / 20)) : 0

  // Invariant: the choice is passed on while the confirmation is still open, so a holder that reads its own
  // state on the way (ConfirmDeleteDialog's request, ComposeExitDialog's draft) still has it.
  function choose(value) {
    root.chosen(value)
    root.close()
  }

  function buttonsInOrder() {
    var ordered = [cancelButton]
    for (var entryIndex = 0; entryIndex < choiceButtons.count; entryIndex++) ordered.push(choiceButtons.itemAt(entryIndex))
    return ordered
  }

  anchors.centerIn: QQC.Overlay.overlay
  width: window ? Math.min(MailStyle.space(420), window.width - 2 * edge) : 0
  height: window ? Math.min(implicitHeight, window.height - 2 * edge) : 0
  padding: Math.min(MailStyle.space(18), Math.round(width / 16))
  modal: true
  focus: true
  closePolicy: QQC.Popup.CloseOnEscape
  // Invariant: the question shows first, even when the buttons are stacked below it out of view.
  property Item lastFocused: null
  property bool navigated: false
  onAboutToShow: {
    lastFocused = null
    navigated = false
  }
  // Invariant: the button focused as the confirmation opens counts as where the focus starts, even when Qt
  // first gave the focus back to the button an earlier opening ended on, so reopening never counts as moving.
  onOpened: {
    var ordered = buttonsInOrder()
    var first = ordered[root.focusIndex + 1] || cancelButton
    first.forceActiveFocus()
    root.lastFocused = first
    root.navigated = false
    words.contentY = 0
  }
  // Invariant: a button the focus moves to while the buttons scroll with the words is scrolled into view.
  // The one focused as the confirmation opens is not, so it opens on the question, nor one that takes the
  // focus back, as a button does when the buttons move in with the words.
  function focused(item) {
    if (root.lastFocused && item !== root.lastFocused) {
      root.navigated = true
      root.show(item)
    }
    root.lastFocused = item
  }
  // Invariant: a button taller than the room shows from its first line.
  function show(item) {
    if (!root.stacked) return
    var at = item.mapToItem(words.contentItem, 0, 0)
    var bottom = Math.max(0, words.contentHeight - words.height)
    if (at.y < words.contentY || item.height > words.height) words.contentY = Math.min(at.y, bottom)
    else if (at.y + item.height > words.contentY + words.height) words.contentY = Math.min(at.y + item.height - words.height, bottom)
  }
  // Invariant: when the window's size changes while the confirmation is open, a button the focus was moved
  // to stays in view while the buttons scroll with the words; otherwise the question shows when the buttons
  // move in or out, and the words stay where they were scrolled to when only the room changes.
  function keepInView(toQuestion) {
    if (!root.opened) return
    if (root.stacked && root.navigated && root.lastFocused) root.show(root.lastFocused)
    else if (toQuestion) words.contentY = 0
    else words.contentY = Math.max(0, Math.min(words.contentY, words.contentHeight - words.height))
  }
  function keepInViewRestacked() { root.keepInView(true) }
  function keepInViewResized() { root.keepInView(false) }
  onStackedChanged: Qt.callLater(root.keepInViewRestacked)
  background: Rectangle {
    radius: Style.cornerRadius
    color: root.backgroundColor
    border.width: 1
    border.color: root.borderColor
  }
  readonly property real gap: MailStyle.space(14)
  // Invariant: the buttons stay in view below the words, and only the words scroll, while the buttons take
  // at most half the room; when they need more (several long choices at the largest size in a small
  // window) the buttons scroll with the words, so the question always keeps room on screen.
  readonly property real room: window ? window.height - 2 * edge - topPadding - bottomPadding : 0
  readonly property real minimumWordsHeight: 2 * questionText.contentHeight / Math.max(1, questionText.lineCount)
  readonly property bool stacked: buttons.implicitHeight > room / 2
    || buttons.implicitHeight + gap + minimumWordsHeight > room
  contentItem: Item {
    id: area
    implicitHeight: wordsColumn.implicitHeight + root.gap + buttons.implicitHeight
    // Invariant: the words scroll from the keyboard too, so the line on what follows can be read without a
    // mouse. The buttons keep Return, Space and Tab.
    Keys.onPressed: function(event) {
      var bottom = Math.max(0, words.contentHeight - words.height)
      var line = MailStyle.body * 1.5
      var target = event.key === Qt.Key_Up ? words.contentY - line
        : event.key === Qt.Key_Down ? words.contentY + line
        : event.key === Qt.Key_PageUp ? words.contentY - words.height * 0.9
        : event.key === Qt.Key_PageDown ? words.contentY + words.height * 0.9
        : event.key === Qt.Key_Home ? 0
        : event.key === Qt.Key_End ? bottom
        : NaN
      if (isNaN(target)) return
      event.accepted = true
      words.contentY = Math.max(0, Math.min(target, bottom))
    }
    Flickable {
      id: words
      objectName: "confirm-words"
      width: parent.width
      height: root.stacked ? parent.height : Math.max(0, parent.height - buttons.height - root.gap)
      contentHeight: wordsColumn.implicitHeight + (root.stacked ? root.gap + buttons.implicitHeight : 0)
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      onHeightChanged: Qt.callLater(root.keepInViewResized)
      // Invariant: a change of text size lays the buttons out again after the words' height changes, so
      // the button the focus was moved to is kept in view once they are (as in Magpie Calendar).
      onContentHeightChanged: Qt.callLater(root.keepInViewResized)
      // Invariant: the scroll bar shows only when the words do not fit, and sits in the padding beside them.
      QQC.ScrollBar.vertical: QQC.ScrollBar {
        parent: words.parent
        anchors.top: words.top
        anchors.bottom: words.bottom
        anchors.left: words.right
        anchors.leftMargin: Math.max(0, (root.rightPadding - width) / 2)
        policy: words.contentHeight > words.height + 1 ? QQC.ScrollBar.AlwaysOn : QQC.ScrollBar.AlwaysOff
      }
      Column {
        id: wordsColumn
        width: words.width
        spacing: MailStyle.space(14)
        Text {
          id: questionText
          objectName: "confirm-question"
          width: parent.width
          text: root.question
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.textColor
          font.family: root.fontFamily
          font.pixelSize: MailStyle.heading
          font.bold: true
        }
        Text {
          objectName: "confirm-message"
          width: parent.width
          visible: text !== ""
          text: root.message
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.dimColor
          font.family: root.fontFamily
          font.pixelSize: MailStyle.bodySmall
        }
      }
    }
    Flow {
      id: buttons
      objectName: "confirm-buttons"
      parent: root.stacked ? words.contentItem : area
      width: area.width
      y: root.stacked ? wordsColumn.implicitHeight + root.gap : area.height - height
      spacing: MailStyle.space(8)
      Widgets.Button {
        id: cancelButton
        objectName: root.cancelName
        maximumWidth: buttons.width
        focusable: true
        text: "Cancel"
        foreground: root.textColor
        bordered: true
        fontFamily: root.fontFamily
        onActiveFocusChanged: if (cancelButton.activeFocus) root.focused(cancelButton)
        onClicked: root.close()
      }
      Repeater {
        id: choiceButtons
        model: root.choices
        Widgets.Button {
          id: choiceButton
          required property var modelData
          objectName: String(modelData.objectName || "")
          maximumWidth: buttons.width
          focusable: true
          text: String(modelData.label)
          foreground: modelData.danger === false ? root.textColor : root.dangerColor
          bordered: true
          fontFamily: root.fontFamily
          onActiveFocusChanged: if (choiceButton.activeFocus) root.focused(choiceButton)
          onClicked: root.choose(choiceButton.modelData.value)
        }
      }
    }
  }
}

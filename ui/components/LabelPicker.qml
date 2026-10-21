import QtQuick
import "../controls" as Widgets
import "../settings"
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "../account/Model.js" as Model

Item {
  id: root

  required property color textColor
  required property color accentColor
  required property color dimColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  property var labels: []
  property string currentLabelId: ""

  property string searchQuery: ""

  readonly property bool opened: menu.opened
  readonly property var matchingLabels: Model.movableLabels(
    root.labels, root.searchQuery, root.currentLabelId)

  property int cursorIndex: 0

  signal labelChosen(string labelId)

  anchors.fill: parent
  z: 50

  function open() {
    searchField.text = ""
    root.searchQuery = ""
    root.cursorIndex = 0
    menu.open()
    place()
    searchField.forceActiveFocus()
  }

  // Invariant: popup content is lazy; re-center after its initial height and after filtering
  // changes it.
  function place() {
    if (!menu.visible) return
    var menuHeight = menu.height > 0 ? menu.height : menu.implicitHeight
    menu.x = Math.max(MailStyle.space(8), (root.width - menu.width) / 2)
    menu.y = Math.max(MailStyle.space(8), (root.height - menuHeight) / 3)
  }

  function moveCursor(delta) {
    var matchCount = root.matchingLabels.length
    if (matchCount === 0) return
    cursorIndex = Model.wrappedIndex(cursorIndex, delta, matchCount)
  }

  function chooseCursor() {
    var matchCount = root.matchingLabels.length
    if (root.cursorIndex < 0 || root.cursorIndex >= matchCount) return
    var chosenLabel = root.matchingLabels[root.cursorIndex]
    menu.close()
    root.labelChosen(String(chosenLabel.id || ""))
  }

  QQC.Popup {
    id: menu
    width: Math.min(MailStyle.space(340), root.width - MailStyle.space(24))
    implicitHeight: card.implicitHeight + MailStyle.space(16)
    padding: MailStyle.space(8)
    modal: false
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    onHeightChanged: root.place()
    onOpened: root.place()

    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }

    contentItem: Column {
      id: card
      spacing: MailStyle.space(8)

      Row {
        width: parent.width
        spacing: MailStyle.space(8)

        Text {
          text: "Move to"
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: "(" + root.matchingLabels.length + ")"
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      // Invariant: QQC.Popup consumes window shortcuts; the filter handles navigation before
      // text-cursor keys while preserving printable input.
      Widgets.TextField {
        id: searchField
        width: parent.width
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "Filter folders or labels..."
        onTextChanged: {
          root.searchQuery = text
          root.cursorIndex = 0
        }
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Down) {
            root.moveCursor(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveCursor(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.chooseCursor()
            event.accepted = true
          }
          // Invariant: CloseOnEscape is the sole Escape owner for this popup.
        }
      }

      ListView {
        id: labelList

        WheelScroller { view: labelList }
        width: parent.width
        implicitHeight: Math.min(contentHeight, MailStyle.space(280))
        clip: true
        model: root.matchingLabels
        currentIndex: root.cursorIndex
        highlightMoveDuration: 0
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        delegate: Rectangle {
          id: labelRow
          required property var modelData
          required property int index
          objectName: "label-picker-row-" + index
          readonly property bool hasCursor: root.cursorIndex === labelRow.index

          width: labelList.width
          implicitHeight: MailStyle.space(34)
          radius: Style.cornerRadius
          color: labelRow.hasCursor || rowHover.hovered
            ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent"
          border.width: labelRow.hasCursor ? Style.normalBorderWidth : 0
          border.color: Style.hoverBorderFor(root.textColor, root.accentColor)

          Text {
            anchors.left: parent.left
            anchors.leftMargin: MailStyle.space(10) + Math.min(8, Number(labelRow.modelData.depth) || 0) * MailStyle.space(12)
            anchors.right: parent.right
            anchors.rightMargin: MailStyle.space(10)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: String(labelRow.modelData.leaf || labelRow.modelData.name || "")
            color: root.textColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.bodySmall
            elide: Text.ElideRight
          }

          HoverHandler { id: rowHover }

          MouseArea {
            anchors.fill: parent
            // Invariant: a pointer click only selects a destination; Return or a double-click
            // commits the move.
            onClicked: {
              root.cursorIndex = labelRow.index
            }
            onDoubleClicked: {
              root.cursorIndex = labelRow.index
              root.chooseCursor()
            }
          }
        }
      }

      Text {
        width: parent.width
        visible: root.matchingLabels.length === 0
        textFormat: Text.PlainText
        text: root.searchQuery === ""
          ? "No folders or labels to move into"
          : "No folder or label matches that"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }
    }
  }
}

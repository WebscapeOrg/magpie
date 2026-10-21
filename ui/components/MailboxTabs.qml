import QtQuick
import "../controls" as Widgets
import "../settings"
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

Flickable {
  id: root

  required property color textColor
  required property color accentColor
  required property string panelFontFamily
  property string current: "inbox"
  // Invariant: only resolved mailboxes from the current account may become destinations.
  property var allMailboxes: []
  property int unread: 0
  property int cursorIndex: -1

  signal selected(string key)
  signal chipHovered(int index, bool isHovered)

  // Invariant: overflow scrolls rather than hiding destinations, including folders excluded from
  // search.
  readonly property var mailboxes: Array.isArray(root.allMailboxes) ? root.allMailboxes : []

  width: parent ? parent.width : 0
  implicitHeight: track.height + (interactive ? scrollBar.height : 0)
  contentWidth: track.width
  contentHeight: track.height
  clip: true
  boundsBehavior: Flickable.StopAtBounds
  flickableDirection: Flickable.HorizontalFlick
  interactive: contentWidth > width

  QQC.ScrollBar.horizontal: QQC.ScrollBar {
    id: scrollBar
    policy: root.interactive ? QQC.ScrollBar.AlwaysOn : QQC.ScrollBar.AlwaysOff
    background: Item {}
    contentItem: Rectangle {
      implicitWidth: 6
      implicitHeight: 6
      radius: 3
      color: Qt.alpha(root.textColor, scrollBar.pressed ? 0.7 : 0.3)
    }
  }

  function revealCurrent() {
    for (var i = 0; i < mailboxes.length; i++) {
      if (mailboxes[i].key !== current) continue
      var chip = segments.itemAt(i)
      if (!chip) return
      var left = track.x + chip.x
      var right = left + chip.width
      if (left < contentX) contentX = left
      else if (right > contentX + width) contentX = Math.max(0, right - width)
      return
    }
  }
  onCurrentChanged: Qt.callLater(revealCurrent)
  onWidthChanged: Qt.callLater(revealCurrent)

  Rectangle {
    id: track
    x: Math.max(0, (root.width - width) / 2)
    width: chips.implicitWidth
    height: chips.implicitHeight
    radius: Style.cornerRadius
    color: "transparent"
    border.width: 1
    border.color: Style.normalBorderFor(root.textColor, root.accentColor)

    Row {
      id: chips
      spacing: 0

      Repeater {
        id: segments
        model: root.mailboxes
        onItemAdded: Qt.callLater(root.revealCurrent)

        Item {
          id: segment
          required property var modelData
          required property int index

          implicitWidth: chip.implicitWidth
          implicitHeight: chip.implicitHeight

          Rectangle {
            visible: segment.index > 0
            width: 1
            height: parent.height
            color: track.border.color
          }

          Widgets.Button {
            id: chip
            anchors.fill: parent
            text: segment.modelData.key === "unread" && root.unread > 0
              ? segment.modelData.label + " " + root.unread
              : segment.modelData.label
            foreground: root.textColor
            bordered: false
            selected: root.current === segment.modelData.key
            hasCursor: root.cursorIndex === segment.index
            fontSize: MailStyle.bodySmall
            onClicked: root.selected(segment.modelData.key)
            onHovered: function(isHovered) { root.chipHovered(segment.index, isHovered) }
          }
        }
      }
    }
  }
}

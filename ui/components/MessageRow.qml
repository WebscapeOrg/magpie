import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui
import "../message/Direction.js" as Direction
import "../account/Model.js" as Model
import "../keys/Keymap.js" as Keymap

// Invariant: unread state uses weight and a dot because theme accent alone may be
// indistinguishable.
Rectangle {
  id: root

  required property var summary
  required property color textColor
  required property color accentColor
  required property color dimColor
  property color urgentColor: accentColor
  required property string panelFontFamily
  property bool canArchive: true
  property bool attachmentIndicatorEnabled: true
  property bool conversations: false
  property bool hasCursor: false
  property bool selected: false
  property bool checked: false
  property bool selectionActive: false
  property bool ctrlHeld: false
  readonly property bool selectionMode: selectionActive || checked || ctrlHeld
  property string contentDirection: Direction.MODE_DEFAULT

  signal activated()
  signal checkToggled()
  signal checkRangeRequested()
  property bool snoozeOpen: false
  property string avatarData: ""
  property string overview: ""
  property string overviewState: ""
  property string overviewReason: ""
  signal unreadRequested()
  signal snoozeRequested(real sceneX, real sceneY)
  signal starToggled()
  signal agentRequested(real sceneX, real sceneY)
  signal archiveRequested()
  signal trashRequested()
  signal menuRequested(real sceneX, real sceneY)

  // Invariant: a passive HoverHandler keeps the action lane open while the pointer enters child
  // buttons; MouseArea hover would flicker as buttons move.
  readonly property bool hot: rowHover.hovered || hasCursor

  HoverHandler { id: rowHover }

  readonly property int threadCount: Model.badgeCount(root.summary)

  // Invariant: Latin reply prefixes must not determine subject direction; sender and snippet still
  // use their own first strong character.
  readonly property var subjectAlignment: alignmentFor(
    Direction.forced(root.contentDirection) || String(root.summary.subjectDirection || ""))
  readonly property var textAlignment: alignmentFor(
    Direction.forced(root.contentDirection))

  // Invariant: undefined alignment preserves Qt’s content-derived direction.
  function alignmentFor(direction) {
    if (!Direction.hasAnswer(direction)) return undefined
    return Direction.isRightToLeft(direction) ? Text.AlignRight : Text.AlignLeft
  }

  width: parent ? parent.width : 0
  implicitHeight: body.implicitHeight + MailStyle.space(14)
  radius: Style.cornerRadius
  color: selected || hasCursor || checked
    ? Style.selectedFillFor(textColor, accentColor)
    : (hot ? Style.hoverFillFor(textColor, accentColor) : "transparent")

  MouseArea {
    id: mouse
    anchors.fill: parent
    // Performance: HoverHandler owns hover; duplicate MouseArea hover re-enters every row during
    // native window movement.
    hoverEnabled: false
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    onWheel: function(wheel) { wheel.accepted = false }
    onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        var scene = mapToGlobal(event.x, event.y)
        root.menuRequested(scene.x, scene.y)
      } else if (event.button === Qt.MiddleButton) {
        root.archiveRequested()
      } else if (event.modifiers & Qt.ShiftModifier) {
        root.checkRangeRequested()
      } else if (event.modifiers & Qt.ControlModifier) {
        root.checkToggled()
      } else {
        root.activated()
      }
    }
  }

  SenderAvatar {
    id: avatar
    objectName: "message-avatar"
    anchors.left: parent.left
    anchors.leftMargin: MailStyle.space(14)
    y: body.y
    width: sender.implicitHeight + subject.implicitHeight + body.spacing
    height: width
    sender: root.summary.from || ({})
    imageData: root.avatarData
    foreground: root.textColor
    accent: root.accentColor
    fontFamily: root.panelFontFamily
  }

  Column {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: MailStyle.space(14) + avatar.width + MailStyle.space(10)
    anchors.rightMargin: MailStyle.space(6) + (MailStyle.space(24) - Style.font.iconSmall) / 2
    anchors.verticalCenter: parent.verticalCenter
    spacing: MailStyle.space(2)

    Item {
      width: parent.width
      implicitHeight: Math.max(sender.implicitHeight, time.implicitHeight)

      Text {
        id: sender
        objectName: "message-sender"
        anchors.left: parent.left
        anchors.right: count.visible ? count.left : time.left
        anchors.rightMargin: count.visible ? MailStyle.space(4) : MailStyle.space(8)
        textFormat: Text.PlainText
        text: root.summary.from ? root.summary.from.display : ""
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.listSize
        elide: Text.ElideRight
        horizontalAlignment: root.textAlignment
      }

      Text {
        id: count
        objectName: "message-conversation-count"
        anchors.right: time.left
        anchors.rightMargin: MailStyle.space(8)
        anchors.baseline: sender.baseline
        visible: root.conversations && root.threadCount > 0
        textFormat: Text.PlainText
        text: root.threadCount
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.listSize
        font.bold: root.summary.unread === true
      }

      Text {
        id: time
        objectName: "message-time"
        anchors.right: parent.right
        anchors.baseline: sender.baseline
        textFormat: Text.PlainText
        text: String(root.summary.time || "")
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.listSize
      }
    }

    Text {
      id: subject
      objectName: "message-subject"
      width: Math.max(0, parent.width - (actions.visible ? actions.width + MailStyle.space(4) : 0))
      // Invariant: sender-controlled labels must never activate Qt’s rich-text loader.
      textFormat: Text.PlainText
      text: String(root.summary.subject || "")
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.listSize
      font.bold: root.summary.unread === true
      elide: Text.ElideRight
      horizontalAlignment: root.subjectAlignment
    }

    Item {
      width: Math.max(0, Math.min(subject.width, parent.width - time.width - MailStyle.space(16)))
      implicitHeight: description.implicitHeight

      ActionIcon {
        id: attachmentIndicator
        objectName: "message-attachment-indicator"
        visible: root.attachmentIndicatorEnabled && root.summary.hasAttachments === true
        anchors.left: parent.left
        y: description.y + (description.height - height) / 2
        name: "attachment"
        iconSize: Math.min(MailStyle.listSize, description.implicitHeight)
        color: root.dimColor
        Accessible.role: Accessible.Graphic
        Accessible.name: "Has attachments"
      }

      Text {
        id: description
        objectName: "message-description"
        anchors.left: attachmentIndicator.visible ? attachmentIndicator.right : parent.left
        anchors.leftMargin: attachmentIndicator.visible ? MailStyle.space(6) : 0
        anchors.right: parent.right
        visible: true
        textFormat: Text.PlainText
        text: root.overview || (root.overviewState === "failed" ? "Overview unavailable · " + (root.overviewReason || "previous attempt saved no reason; retry from Menu") : root.overviewState === "paused" ? "Overviews paused" : root.overviewState === "running" ? "Creating overview" : root.overviewState === "unavailable" ? "Overview unavailable · " + (root.overviewReason || "mail backend is disconnected") : "Overview queued")
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.listSize
        elide: Text.ElideRight
        Widgets.PanelToolTip { objectName: "overview-tooltip"; maximumWidth: root.width; visible: overviewHover.hovered && (description.truncated || root.overviewState === "failed"); text: description.text; fontFamily: root.panelFontFamily }
        HoverHandler { id: overviewHover }
        maximumLineCount: 1
        horizontalAlignment: root.textAlignment
      }
    }
  }

  Row {
    id: actions
    objectName: "message-actions"
    anchors.right: parent.right
    anchors.rightMargin: MailStyle.space(6)
    y: body.y + subject.y + (body.height - subject.y - height) / 2
    spacing: Math.max(MailStyle.space(24), Style.font.iconSmall * 2.5 + MailStyle.space(8)) * 0.15
    visible: root.hot || root.selectionMode || root.snoozeOpen

    IconButton {
      objectName: "message-mark-unread"
      visible: !root.selectionMode
      iconName: "unread"
      tooltipText: "Mark unread · Shift+U"
      foreground: root.dimColor
      hoverColor: root.textColor
      iconSize: Style.font.iconSmall * 2.5
      size: Math.max(MailStyle.space(24), iconSize + MailStyle.space(8))
      fontFamily: root.panelFontFamily
      onClicked: root.unreadRequested()
    }
    IconButton {
      objectName: "message-snooze"
      visible: !root.selectionMode
      iconName: "snooze"
      tooltipText: "Snooze until..."
      foreground: root.dimColor
      hoverColor: root.textColor
      iconSize: Style.font.iconSmall * 2.5
      size: Math.max(MailStyle.space(24), iconSize + MailStyle.space(8))
      selected: root.snoozeOpen
      fontFamily: root.panelFontFamily
      onClicked: { var scene = mapToGlobal(0, height); root.snoozeRequested(scene.x, scene.y) }
    }

    IconButton {
      // Invariant: an account without an archive destination must not expose an action that cannot
      // move the message.
      visible: root.hot && root.canArchive && !root.selectionMode
      iconName: "archive"
      tooltipText: "Archive · e"
      foreground: root.dimColor
      hoverColor: root.textColor
      iconSize: Style.font.iconSmall * 2.5
      size: Math.max(MailStyle.space(24), iconSize + MailStyle.space(8))
      fontFamily: root.panelFontFamily
      onClicked: root.archiveRequested()
    }

    IconButton {
      visible: root.hot && !root.selectionMode
      objectName: "message-trash"
      iconName: "trash"
      tooltipText: "Move to trash · d"
      foreground: root.dimColor
      hoverColor: root.textColor
      iconSize: Style.font.iconSmall * 2.5
      size: Math.max(MailStyle.space(24), iconSize + MailStyle.space(8))
      fontFamily: root.panelFontFamily
      onClicked: root.trashRequested()
    }

    Item {
      id: checkControl
      objectName: "message-check"
      width: MailStyle.space(24)
      height: width
      visible: root.selectionMode
      Accessible.role: Accessible.CheckBox
      Accessible.name: "Select message"
      Accessible.checkable: true
      Accessible.checked: root.checked
      Accessible.onPressAction: root.checkToggled()

      BorderSurface {
        id: checkBox
        anchors.centerIn: parent
        width: MailStyle.space(12)
        height: width
        radius: 0
        color: checkMouse.pressed ? Style.pressedFillFor(root.textColor, root.accentColor)
          : (root.checked ? Style.selectedFillFor(root.textColor, root.accentColor)
            : (checkMouse.containsMouse ? Style.hoverFillFor(root.textColor, root.accentColor)
              : "transparent"))
        borderSpec: root.checked
          ? Border.controlSpec("selected", root.textColor, root.accentColor)
          : Border.controlSpec("normal", root.textColor, root.accentColor)

        ActionIcon {
          anchors.centerIn: parent
          visible: root.checked
          name: "check"
          iconSize: Math.round(checkBox.height * 0.85)
          color: Style.selectedStateColor(root.textColor, root.accentColor)
        }
      }

      MouseArea {
        id: checkMouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: function(event) {
          if (event.modifiers & Qt.ShiftModifier) root.checkRangeRequested()
          else root.checkToggled()
        }
      }

      Widgets.PanelToolTip {
        visible: checkMouse.containsMouse
        text: (root.checked ? "Deselect" : "Select") + " · "
          + Keymap.keycapLabel(Keymap.displayFor(Keymap.byId("toggleCheck")))
          + " · ctrl+click toggles; shift+click selects or clears a range"
        fontFamily: root.panelFontFamily
      }
    }
  }
}

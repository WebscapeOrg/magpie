import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui
import "../message/Direction.js" as Direction
import "../account/Model.js" as Model
import "../keys/Keymap.js" as Keymap

// One message in the list. Unread is carried by weight and by the dot on the
// left, never by colour alone — the accent is a theme value that some themes
// put close to the foreground.
Rectangle {
  id: root

  required property var summary
  required property color textColor
  required property color accentColor
  required property color dimColor
  property color urgentColor: accentColor
  required property string panelFontFamily
  property bool canArchive: true
  // Whether this row stands for a conversation rather than for one message.
  // Grouping is a panel rule gated on the provider's `conversations`
  // capability; a row is told, and asks nobody.
  property bool conversations: false
  property bool hasCursor: false
  property bool selected: false
  // Ticked for a bulk action. Not `selected`: that is the message the reader
  // shows, and the two are different things for the same reason the cursor is.
  property bool checked: false
  // What the agent is doing with this message, if anything: "", "running",
  // "question", "done", "failed" or "cancelled". State, so it shows whether
  // or not the row is hot, like the star.
  property string agentState: ""
  // The agent's last line while it works on this message, for the tooltip.
  property string agentProgress: ""
  property bool agentAttention: false
  property bool selectionActive: false
  property bool ctrlHeld: false
  readonly property bool selectionMode: selectionActive || checked || ctrlHeld
  // How the direction of this message's own text is arrived at. Passed down
  // like every other fact a row draws, because a row decides nothing.
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

  // Hovered by a handler rather than by the MouseArea's `containsMouse`: a
  // button on the row has a MouseArea of its own, and the pointer moving onto
  // one took the row's hover away — the extra buttons hid, the lane closed,
  // the button slid out from under the pointer, the row was hovered again,
  // and the lane flickered open and shut. A HoverHandler is passive and stays
  // hovered whatever the pointer is over inside the row.
  readonly property bool hot: rowHover.hovered || hasCursor

  HoverHandler { id: rowHover }

  // How many messages the conversation holds, for the badge — and zero for a
  // row that draws none, which `Model.badgeCount` decides: a provider that does
  // not group its listing, a conversation of one, a summary cached before rows
  // carried a block at all.
  readonly property int threadCount: Model.badgeCount(root.summary)

  // The subject is asked on its own account: a reply prefix is Latin whatever
  // the thread is written in, so `Re: مرحبا` reads left-to-right to anything
  // that takes the first strong character at face value — which is every
  // message in a thread after the first.
  //
  // The sender and the snippet are not. Qt resolves both correctly from their
  // own text, so on Auto there is nothing to add; only a direction the reader
  // has actually chosen has to be carried to them.
  readonly property var subjectAlignment: alignmentFor(
    Direction.forced(root.contentDirection) || String(root.summary.subjectDirection || ""))
  readonly property var textAlignment: alignmentFor(
    Direction.forced(root.contentDirection))

  // `undefined` leaves a Text following the direction of its own text, which is
  // what should happen wherever there is no answer to give it.
  function alignmentFor(direction) {
    if (!Direction.hasAnswer(direction)) return undefined
    return Direction.isRightToLeft(direction) ? Text.AlignRight : Text.AlignLeft
  }

  width: parent ? parent.width : 0
  implicitHeight: body.implicitHeight + MailStyle.space(14)
  radius: Style.cornerRadius
  // The checkbox identifies bulk selection independently of the reader fill.
  color: selected || hasCursor || checked
    ? Style.selectedFillFor(textColor, accentColor)
    : (hot ? Style.hoverFillFor(textColor, accentColor) : "transparent")

  MouseArea {
    id: mouse
    anchors.fill: parent
    // HoverHandler already owns `hot`. hoverEnabled here re-enters every row
    // when the window moves under a still pointer, which is extra scene work
    // during a system drag.
    hoverEnabled: false
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    onWheel: function(wheel) { wheel.accepted = false }
    onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        var scene = mapToGlobal(event.x, event.y)
        root.menuRequested(scene.x, scene.y)
      } else if (event.button === Qt.MiddleButton) {
        // Middle-click archives: the one triage action worth having without
        // moving the pointer to a button.
        root.archiveRequested()
      } else if (event.modifiers & Qt.ShiftModifier) {
        // Shift selects or clears the range from the cursor to here;
        // Ctrl toggles this row on its own.
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
    // Align text with the action glyph, rather than its padded hit target.
    anchors.rightMargin: MailStyle.space(6) + (MailStyle.space(24) - Style.font.iconSmall) / 2
    anchors.verticalCenter: parent.verticalCenter
    spacing: MailStyle.space(2)

    // The sender and optional conversation count share the first line with
    // the date, which keeps the full row edge while actions appear below.
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

      // How long the conversation is, beside who wrote it — where Gmail puts
      // it, and the one place on the row that is about the thread rather than
      // about the message the server returned for it.
      //
      // Drawn only where the model gave it a number: two or more, on a provider
      // that groups its listing.
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
        font.bold: root.summary.unread
      }

      Text {
        id: time
        objectName: "message-time"
        anchors.right: parent.right
        anchors.baseline: sender.baseline
        textFormat: Text.PlainText
        text: root.summary.time
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.listSize
      }
    }

    Text {
      id: subject
      objectName: "message-subject"
      width: Math.max(0, parent.width - (actions.visible ? actions.width + MailStyle.space(4) : 0))
      // Sender-controlled text must never activate Qt's rich-text loader.
      textFormat: Text.PlainText
      text: root.summary.subject
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.listSize
      font.bold: root.summary.unread
      elide: Text.ElideRight
      horizontalAlignment: root.subjectAlignment
    }

    Text {
      id: description
      objectName: "message-description"
      width: Math.max(0, Math.min(subject.width, parent.width - time.width - MailStyle.space(16)))
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

  // Row actions appear on hover or under the keyboard cursor. A starred
  // message keeps its star visible either way, because that is state rather
  // than an affordance.
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
      // No archive button where the account has nowhere to archive to. On IMAP
      // that is a move to a folder, and a server without one would have this
      // quietly do nothing.
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

    // The selection target stays on the same right edge, even while the
    // other actions make room for a selection being built across rows.
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

import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui
import "../message/Direction.js" as Direction
import "../account/Model.js" as Model
import "../keys/Keymap.js" as Keymap

Rectangle {
  id: root

  required property var summary
  property string ownerAccountId: ""
  property string interactionScope: ""
  readonly property string messageIdentity: JSON.stringify([summary.accountId || ownerAccountId, summary.id || "", interactionScope])
  property int identityRevision: 0
  onMessageIdentityChanged: identityRevision++
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
  readonly property color secondaryTextColor: selected || hasCursor || checked ? textColor : dimColor
  property string contentDirection: Direction.MODE_DEFAULT

  signal pointDetailsRequested()
  signal activated()
  signal checkToggled()
  signal checkRangeRequested()
  property bool snoozeOpen: false
  property string avatarData: ""
  property string overview: ""
  // In the Inbox, a message whose Point Magpie is writing shows moving lines where the Point goes,
  // and the Point fades in when it is ready.
  property bool writing: false
  property int pendingCount: 0
  property color backgroundColor: "transparent"
  property bool motionEnabled: true
  property bool departing: false
  transform: Translate {
    y: root.departing && root.motionEnabled ? -MailStyle.space(18) : 0
    Behavior on y { NumberAnimation { duration: root.motionEnabled ? 220 : 0; easing.type: Easing.OutCubic } }
  }
  readonly property int stackDepth: Math.min(3, Math.max(0, pendingCount))
  readonly property real stackInset: Math.max(0, stackDepth - 1) * MailStyle.space(6)
  readonly property real cardGutter: stackDepth ? MailStyle.space(8) : 0
  property string writingId: ""
  onWritingChanged: {
    if (!writing && writingId === String(summary.id || "")) pointFade.restart()
    writingId = writing ? String(summary.id || "") : ""
  }
  signal unreadRequested()
  signal snoozeRequested(real sceneX, real sceneY)
  signal starToggled()
  signal agentRequested(real sceneX, real sceneY)
  signal archiveRequested()
  signal trashRequested()
  signal menuRequested(real sceneX, real sceneY)
  signal bundleApproveRequested()
  signal bundleDismissRequested()

  // Invariant: a passive HoverHandler keeps the action lane open while the pointer enters child
  // buttons; MouseArea hover would flicker as buttons move.
  readonly property bool hot: rowHover.hovered || hasCursor

  HoverHandler { id: rowHover }

  readonly property int threadCount: Model.badgeCount(root.summary)
  // One Point for several mails (Q-019): how many mails the row holds, and whether the engine asks
  // to bundle the mail behind it. Both come from the Inbox's own row; every other view leaves them unset.
  readonly property int bundleCount: Number(root.summary.bundleCount || 0)
  readonly property bool bundleProposal: root.summary.bundleProposal === true
  // On a narrow row the question's two buttons and the tools cannot share the line; the buttons win,
  // and the tools stay in the row's menu.
  readonly property bool proposalCrowded: bundleProposal && !writing && bundleLane.parent.width
    < actions.implicitWidth + MailStyle.space(4) + bundleApprove.implicitWidth + bundleDismiss.implicitWidth + MailStyle.space(10)
  readonly property real avatarTopInset: Math.max(0, sender.baselineOffset + senderMetrics.tightBoundingRect.y)

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
  readonly property string subjectText: root.overview || String(root.summary.subject || "")
  readonly property real listTextSize: Math.max(8, MailStyle.preferences.listSize - 3) * 96 / 72
  // The unread marker paints a little beyond the text; clipping a hovered row must leave it whole.
  readonly property real markerBleed: MailStyle.space(12)
  readonly property real actionLaneHeight: Math.max(MailStyle.space(24), Style.font.iconSmall * 2.5 + MailStyle.space(8))
  // Invariant: the row is the same height with its tools showing or hidden, so moving the pointer
  // over the list never moves the rows below.
  implicitHeight: Math.max(body.implicitHeight, actionLaneHeight, avatar.height + avatarTopInset) + MailStyle.space(14) + stackInset + cardGutter
  radius: Style.cornerRadius
  readonly property color rowFill: selected || hasCursor || checked
    ? Style.selectedFillFor(textColor, accentColor)
    : (hot ? Style.hoverFillFor(textColor, accentColor) : "transparent")

  color: stackDepth ? "transparent" : rowFill
  Repeater {
    model: root.stackDepth
    Rectangle {
      required property int index
      objectName: "point-card-" + index
      z: -1
      x: root.cardGutter + index * MailStyle.space(6)
      y: index * MailStyle.space(6)
      width: Math.max(0, root.width - root.stackInset - 2 * root.cardGutter)
      height: root.height - root.stackInset - root.cardGutter
      radius: Math.max(Style.cornerRadius, MailStyle.space(10))
      color: root.backgroundColor
      border.width: 1
      border.color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.2)
      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: index === root.stackDepth - 1 ? root.rowFill : "transparent"
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    // Performance: HoverHandler owns hover; duplicate MouseArea hover re-enters every row during
    // native window movement.
    hoverEnabled: false
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    onWheel: function(wheel) { wheel.accepted = false }
    property int pressedRevision: -1
    property bool held: false
    onPressed: { pressedRevision = root.identityRevision; held = false }
    onPressAndHold: function(event) {
      if (event.button !== Qt.LeftButton || pressedRevision !== root.identityRevision) return
      held = true
      root.pointDetailsRequested()
    }
    onCanceled: pressedRevision = -1
    onClicked: function(event) {
      if (held || pressedRevision !== root.identityRevision) return
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
    anchors.leftMargin: MailStyle.space(14) + root.stackInset + root.cardGutter
    y: body.y + root.avatarTopInset
    width: MailStyle.space(36)
    height: width
    sender: root.summary.from || ({})
    imageData: root.avatarData
    foreground: root.textColor
    accent: root.accentColor
    fontFamily: root.panelFontFamily
  }

  TextMetrics {
    id: senderMetrics
    font: sender.font
    text: "H"
  }

  Column {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: MailStyle.space(14) + avatar.width + MailStyle.space(10) + root.stackInset + root.cardGutter
    anchors.rightMargin: MailStyle.space(6) + (MailStyle.space(24) - Style.font.iconSmall) / 2 + root.cardGutter
    y: MailStyle.space(7) + root.stackInset
    spacing: MailStyle.space(2)

    Item {
      width: parent.width
      implicitHeight: Math.max(sender.implicitHeight, time.implicitHeight)

      Text {
        id: sender
        objectName: "message-sender"
        anchors.left: parent.left
        anchors.right: count.visible ? count.left : attachmentIndicator.visible ? attachmentIndicator.left : time.left
        anchors.rightMargin: (count.visible ? MailStyle.space(4) : MailStyle.space(8))
          + (bundleBadge.visible ? bundleBadge.width + MailStyle.space(8) : 0)
        textFormat: Text.PlainText
        text: root.summary.from ? root.summary.from.display : ""
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.listSize
        font.bold: false
        elide: Text.ElideRight
        horizontalAlignment: root.textAlignment
      }

      // The small rounded count after the sender's name. It sits within the sender's line, so a
      // bundled row is the same height as any other.
      Rectangle {
        id: bundleBadge
        objectName: "message-bundle-count"
        visible: root.bundleCount > 1
        readonly property bool rightToLeft: sender.effectiveHorizontalAlignment === Text.AlignRight
        x: rightToLeft ? sender.x + sender.width + MailStyle.space(6) : sender.x + sender.paintedWidth + MailStyle.space(6)
        anchors.verticalCenter: sender.verticalCenter
        height: bundleBadgeText.implicitHeight + MailStyle.space(2)
        width: Math.max(height, bundleBadgeText.implicitWidth + MailStyle.space(8))
        radius: height / 2
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.1)
        Accessible.role: Accessible.StaticText
        Accessible.name: root.bundleCount + " mails in this Point"

        Text {
          id: bundleBadgeText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.bundleCount
          color: root.secondaryTextColor
          font.family: root.panelFontFamily
          font.pixelSize: Math.min(MailStyle.caption, MailStyle.listSize * 0.8)
        }
      }

      Text {
        id: count
        objectName: "message-conversation-count"
        anchors.right: attachmentIndicator.visible ? attachmentIndicator.left : time.left
        anchors.rightMargin: MailStyle.space(8)
        anchors.baseline: sender.baseline
        visible: root.conversations && root.threadCount > 0
        textFormat: Text.PlainText
        text: root.threadCount
        color: root.secondaryTextColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.listSize
        font.bold: false
      }

      ActionIcon {
        id: attachmentIndicator
        objectName: "message-attachment-indicator"
        visible: root.attachmentIndicatorEnabled && root.summary.hasAttachments === true
        anchors.right: time.left
        anchors.rightMargin: MailStyle.space(8)
        y: (sender.height - height) / 2
        name: "attachment"
        iconSize: MailStyle.listSize
        color: root.secondaryTextColor
        Accessible.role: Accessible.Graphic
        Accessible.name: "Has attachments"
      }

      Text {
        id: time
        objectName: "message-time"
        anchors.right: parent.right
        anchors.verticalCenter: sender.verticalCenter
        textFormat: Text.PlainText
        text: String(root.summary.time || "")
        color: root.secondaryTextColor
        font.family: root.panelFontFamily
        font.pixelSize: subject.font.pixelSize
      }
    }

    Column {
      id: pointPlaceholder
      objectName: "point-placeholder"
      visible: root.writing
      width: subject.width
      topPadding: MailStyle.space(3)
      bottomPadding: MailStyle.space(3)
      spacing: MailStyle.space(6)
      property real phase: -0.6
      NumberAnimation on phase {
        running: pointPlaceholder.visible && root.visible && root.motionEnabled
        from: -0.6; to: 1.0; duration: 1800
        loops: Animation.Infinite
      }
      Accessible.role: Accessible.StaticText
      Accessible.name: "Point being written. " + String(root.summary.subject || "")
      Accessible.description: root.pendingCount ? root.pendingCount + " messages waiting for their Point" : ""
      Repeater {
        model: [1.0, 0.62]
        Rectangle {
          required property real modelData
          width: Math.max(1, pointPlaceholder.width * modelData)
          height: MailStyle.space(9)
          radius: height / 2
          clip: true
          color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.12)
          Rectangle {
            visible: root.motionEnabled
            x: parent.width * pointPlaceholder.phase
            y: 1
            width: parent.width * 0.6
            height: parent.height - 2
            radius: height / 2
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0; color: "transparent" }
              GradientStop { position: 0.5; color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.65) }
              GradientStop { position: 1; color: "transparent" }
            }
          }
        }
      }
    }

    Item {
      id: subjectLane
      width: parent.width
      visible: !root.writing
      implicitHeight: actions.visible ? subjectAtRest.implicitHeight : subject.implicitHeight

      Item {
        x: -root.markerBleed
        width: parent.width + 2 * root.markerBleed
        height: parent.height
        clip: actions.visible

        MarkedText {
          id: subject
          x: root.markerBleed
          NumberAnimation on opacity { id: pointFade; running: false; from: 0; to: 1; duration: 350; easing.type: Easing.InOutQuad }
          marked: root.summary.unread === true
          markerColor: Qt.rgba(0.73,0.48,0.20,0.144)
          objectName: "message-subject"
          width: Math.max(1, subjectLane.width - (actions.visible ? actions.width + MailStyle.space(4) : 0))
          // Invariant: sender-controlled labels must never activate Qt’s rich-text loader.
          textFormat: Text.PlainText
          text: root.subjectText
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: root.listTextSize
          font.bold: false
          elide: Text.ElideRight
          horizontalAlignment: root.overview ? root.textAlignment : root.subjectAlignment
          wrapMode: Text.Wrap
          // Invariant: The Point is shown whole and the row grows to fit it (the engine caps it at
          // POINT_LIMIT characters); a sender's subject stops at three lines and is shown whole on hover.
          // While the tools narrow the line, the text keeps the line count it has without them and is cut.
          maximumLineCount: actions.visible ? Math.max(1, subjectAtRest.lineCount) : subjectAtRest.maximumLineCount
          Accessible.name: (root.summary.unread === true ? "Unread. " : "") + (root.overview ? "The Point: " + root.overview : text)
          Widgets.PanelToolTip { objectName: "overview-tooltip"; maximumWidth: root.width; visible: overviewHover.hovered && subject.truncated; text: subject.text; fontFamily: root.panelFontFamily }
          HoverHandler { id: overviewHover }
        }
      }
    }

    Text {
      id: subjectAtRest
      visible: false
      width: parent.width
      textFormat: Text.PlainText
      text: actions.visible ? root.subjectText : ""
      font.family: root.panelFontFamily
      font.pixelSize: root.listTextSize
      elide: Text.ElideRight
      wrapMode: Text.Wrap
      maximumLineCount: root.overview ? 2147483647 : 3
    }

    Text {
      id: descriptionAtRest
      visible: false
      width: Math.max(0, parent.width - time.width - MailStyle.space(16))
      textFormat: Text.PlainText
      text: actions.visible ? String(root.summary.snippet || "") : ""
      font.family: root.panelFontFamily
      font.pixelSize: root.listTextSize
      elide: Text.ElideRight
      wrapMode: Text.Wrap
      maximumLineCount: 2
    }

    Item {
      width: Math.max(1, Math.min(subject.width, parent.width - time.width - MailStyle.space(16)))
      visible: !root.writing && !root.overview && String(root.summary.snippet || "") !== ""
      implicitHeight: visible ? (actions.visible ? descriptionAtRest.implicitHeight : description.implicitHeight) : 0
      clip: actions.visible


      Text {
        id: description
        objectName: "message-description"
        anchors.left: parent.left
        anchors.right: parent.right
        visible: true
        textFormat: Text.PlainText
        text: String(root.summary.snippet || "")
        color: root.secondaryTextColor
        font.family: root.panelFontFamily
        font.pixelSize: root.listTextSize
        elide: Text.ElideRight
        maximumLineCount: actions.visible ? Math.max(1, descriptionAtRest.lineCount) : descriptionAtRest.maximumLineCount
        wrapMode: Text.Wrap
        horizontalAlignment: root.textAlignment
      }
    }

    // The whole question always shows, whatever the tools do, so Bundle is never offered with part of
    // the address cut off. Only its buttons share a line with the tools (C-071, C-073).
    Column {
      id: bundleLane
      objectName: "bundle-proposal"
      visible: root.bundleProposal && !root.writing
      width: parent.width
      spacing: MailStyle.space(6)

      Text {
        id: bundleQuestion
        objectName: "bundle-question"
        width: parent.width
        textFormat: Text.PlainText
        text: root.summary.bundleQuestion || "Bundle these?"
        color: root.secondaryTextColor
        font.family: root.panelFontFamily
        font.pixelSize: root.listTextSize
        wrapMode: Text.Wrap
      }

      Item {
        id: bundleButtons
        objectName: "bundle-buttons"
        width: Math.max(0, parent.width - (actions.visible ? actions.width + MailStyle.space(4) : 0))
        // Selection or the snooze picker keep the tools showing; the buttons then stop short of them.
        clip: root.proposalCrowded
        // Too narrow for both side by side, Dismiss goes under Bundle so the offer can still be refused.
        readonly property bool stacked: width < bundleApprove.implicitWidth + MailStyle.space(10) + bundleDismiss.implicitWidth
        implicitHeight: stacked
          ? bundleApprove.implicitHeight + MailStyle.space(6) + bundleDismiss.implicitHeight
          : Math.max(bundleApprove.implicitHeight, bundleDismiss.implicitHeight)

        Grid {
          anchors.verticalCenter: parent.verticalCenter
          columns: bundleButtons.stacked ? 1 : 2
          columnSpacing: MailStyle.space(10)
          rowSpacing: MailStyle.space(6)

          Widgets.Button {
            id: bundleApprove
            objectName: "bundle-approve"
            text: "Bundle"
            tooltipText: "Bundle these, and let this address bundle other senders' mail from now on"
            foreground: root.textColor
            accent: root.accentColor
            fontFamily: root.panelFontFamily
            fontSize: MailStyle.caption
            onClicked: root.bundleApproveRequested()
          }

          Widgets.Button {
            id: bundleDismiss
            objectName: "bundle-dismiss"
            text: "Dismiss"
            tooltipText: "Keep these apart"
            foreground: root.dimColor
            accent: root.accentColor
            fontFamily: root.panelFontFamily
            fontSize: MailStyle.caption
            onClicked: root.bundleDismissRequested()
          }
        }
      }
    }
  }

  Row {
    id: actions
    objectName: "message-actions"
    anchors.right: parent.right
    anchors.rightMargin: MailStyle.space(6)
    // With an offer showing, the tools share the buttons' line and stay clear of its question.
    y: bundleLane.visible
      ? body.y + bundleLane.y + bundleButtons.y + (bundleButtons.height - height) / 2
      : body.y + subjectLane.y + (body.height - subjectLane.y - height) / 2
    spacing: Math.max(MailStyle.space(24), Style.font.iconSmall * 2.5 + MailStyle.space(8)) * 0.15
    visible: (root.hot && !root.proposalCrowded) || root.selectionMode || root.snoozeOpen

    IconButton {
      activationKey: root.messageIdentity
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
      activationKey: root.messageIdentity
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
      activationKey: root.messageIdentity
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
      activationKey: root.messageIdentity
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
        property int pressedRevision: -1
        onPressed: pressedRevision = root.identityRevision
        onCanceled: pressedRevision = -1
        onClicked: function(event) {
          if (pressedRevision !== root.identityRevision) return
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

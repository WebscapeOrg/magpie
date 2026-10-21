import QtQuick
import "../settings"
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Menu.js" as Menu
import "../account/Model.js" as Model

// Invariant: the list’s clipping Flickable would cut off a child menu; use a popup.
Item {
  id: root

  required property var service
  required property color textColor
  required property color urgentColor
  required property color dimColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  property string messageId: ""
  // Invariant: a rail stop targets one member, while a conversation row targets its counted
  // members.
  property bool memberOnly: false
  property real anchorX: 0
  property real anchorY: 0
  property int cursorIndex: -1
  readonly property var menuRows: [continueRow, replyRow, replyAllRow, forwardRow, archiveRow,
    unarchiveRow, moveRow,
    trashRow, spamRow, readRow, starRow, browserRow, aiRow]
  // Invariant: spam has its own inverse only where the provider supports it; IMAP Junk otherwise
  // remains eligible for Move to Inbox.
  readonly property var messageHost: !root.service ? null
    : typeof root.service.hostForId === "function"
      ? root.service.hostForId(root.messageId) : root.service
  readonly property bool archived: !!root.summary
    && root.summary.inInbox === false
    && root.summary.inTrash !== true
    && (root.summary.inSpam !== true || (root.messageHost && root.messageHost.canReportSpam === false))
    && root.summary.isSent !== true
    && root.summary.isDraft !== true

  readonly property bool inLabelView: !!root.service
    && !!root.service.hasLabels
    && String(root.service.rawLabelId || "") !== ""
    && !Model.isSystemLabelId(String(root.service.rawLabelId || ""))

  readonly property bool opened: menu.opened
  readonly property var summary: {
    if (!service || messageId === "") return null
    var list = service.messages
    for (var entryIndex = 0; entryIndex < list.length; entryIndex++) {
      if (list[entryIndex].id === messageId) return list[entryIndex]
    }
    var members = service.memberSummaries
    if (members && typeof members === "object" && members[messageId]) return members[messageId]
    return null
  }

  signal agentRequested(string id, real sceneX, real sceneY)
  signal composeRequested(string mode, string id)
  signal actionRequested(string action, string id)
  signal memberComposeRequested(string mode, string id)
  signal memberActionRequested(string action, string id)

  anchors.fill: parent
  z: 50

  function openAt(id, sceneX, sceneY) {
    root.memberOnly = false
    openMenu(id, sceneX, sceneY)
  }

  function openForMember(id, sceneX, sceneY) {
    root.memberOnly = true
    openMenu(id, sceneX, sceneY)
  }

  function openMenu(id, sceneX, sceneY) {
    root.messageId = String(id || "")
    if (!root.summary) return
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

  function run(action) {
    var id = root.messageId
    var member = root.memberOnly
    menu.close()
    if (member) root.memberActionRequested(action, id)
    else root.actionRequested(action, id)
  }

  function compose(mode) {
    var id = root.messageId
    var member = root.memberOnly
    menu.close()
    if (member) root.memberComposeRequested(mode, id)
    else root.composeRequested(mode, id)
  }

  QQC.Popup {
    id: menu
    width: MailStyle.space(200)
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
        id: continueRow
        objectName: "message-menu-continue-draft"
        visible: !!root.summary && root.summary.isDraft === true && !root.memberOnly
        text: "Continue editing"
        onActivated: root.compose("draft")
      }
      MenuRow { id: replyRow; visible: !root.summary || !root.summary.isDraft; text: "Reply"; onActivated: root.compose("reply") }
      MenuRow { id: replyAllRow; visible: !root.summary || !root.summary.isDraft; text: "Reply all"; onActivated: root.compose("replyAll") }
      MenuRow { id: forwardRow; visible: !root.summary || !root.summary.isDraft; text: "Forward"; onActivated: root.compose("forward") }

      MenuSeparatorLine {
        width: menu.width - menu.leftPadding - menu.rightPadding
        lineColor: root.textColor
      }

      MenuRow {
        id: archiveRow
        visible: (!root.service || root.service.canArchive) && !root.archived
        text: "Archive"
        onActivated: root.run("archive")
      }
      // Invariant: adding INBOX does not remove SPAM or TRASH and can relocate IMAP drafts; this
      // action applies only to archived mail.
      MenuRow {
        id: unarchiveRow
        visible: (!root.service || root.service.canArchive) && root.archived
        text: root.inLabelView ? "Move to Inbox and remove label" : "Move to Inbox"
        onActivated: root.run("unarchive")
      }
      MenuRow {
        id: moveRow
        visible: !!root.service && root.service.canMoveToLabel && !root.memberOnly
        text: "Move to..."
        onActivated: root.run("moveToLabel")
      }
      MenuRow { id: trashRow; text: "Move to trash"; tone: root.urgentColor; onActivated: root.run("trash") }
      MenuRow {
        id: spamRow
        visible: !root.service || root.service.canReportSpam
        text: "Report spam"
        tone: root.urgentColor
        onActivated: root.run("spam")
      }

      MenuSeparatorLine {
        width: menu.width - menu.leftPadding - menu.rightPadding
        lineColor: root.textColor
      }

      MenuRow {
        id: readRow
        text: root.summary && root.summary.unread ? "Mark as read" : "Mark as unread"
        onActivated: root.run(root.summary && root.summary.unread ? "markRead" : "markUnread")
      }
      MenuRow {
        id: starRow
        visible: !root.service || root.service.canStar
        text: root.summary && root.summary.starred ? "Unstar" : "Star"
        onActivated: root.run(root.summary && root.summary.starred ? "unstar" : "star")
      }

      MenuSeparatorLine {
        width: menu.width - menu.leftPadding - menu.rightPadding
        lineColor: root.textColor
      }

      MenuRow {
        id: aiRow
        objectName: "message-menu-ai"
        enabled: !!root.service && root.service.agentAvailable !== false
        visible: !!root.service && root.service.hasAgent !== false
        text: "Ask AI..."
        onActivated: {
          var id = root.messageId
          var scene = root.mapToGlobal(root.anchorX, root.anchorY)
          menu.close()
          root.agentRequested(id, scene.x, scene.y)
        }
      }

      MenuRow {
        id: browserRow
        visible: !root.service || root.service.canOpenOnWeb
        text: "Open in browser..."
        tone: root.dimColor
        onActivated: {
          var id = root.messageId
          menu.close()
          if (root.service) root.service.openInBrowser(id)
        }
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

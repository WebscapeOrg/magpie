import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui
import "../account/SyncHealth.js" as SyncHealth
import "../account/Unsaved.js" as Unsaved

// Settings → Mailboxes → Sync for the chosen mailbox: how its offline copy is doing, its queued
// changes and Pause sync, as the iPhone shows under Settings → the account → Sync (Q-011).
// Invariant: the rows are created once, so a status update changes their text in place and a
// screen reader keeps its place.
Column {
  id: root
  required property var mailbox
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily
  readonly property var status: mailbox ? mailbox.status : ({})
  readonly property double now: mailbox ? mailbox.clock : Date.now()
  // The list's "needs Gmail" message belongs beside its Search online button, not here.
  readonly property string problem: !mailbox ? ""
    : mailbox.error !== "" && mailbox.needsGmail !== true ? mailbox.error : mailbox.problem
  readonly property string unsaved: Unsaved.summary(status)
  visible: !!mailbox && mailbox.available === true
  spacing: MailStyle.space(6)

  readonly property var labels: ({status: "Status", checked: "Last checked", inbox: "Inbox", other: "Other mail",
    changes: "Mailbox changes"})
  function value(key) {
    if (key === "status") return SyncHealth.summary(status, mailbox ? mailbox.problem : "",
      !!mailbox && mailbox.statusFailed === true, now)
    if (key === "checked") return SyncHealth.lastChecked(status, now)
    if (key === "inbox") return SyncHealth.inbox(status, now)
    if (key === "other") return SyncHealth.otherMail(status, now)
    return SyncHealth.changes(status)
  }

  function ticket(state, latest) {
    var entries = mailbox ? mailbox.edits : []
    for (var step = 0; step < entries.length; step++) {
      var entry = entries[latest ? entries.length - 1 - step : step]
      if (entry.state === state) return String(entry.ticket)
    }
    return ""
  }

  TextMetrics {
    id: labelMetrics
    text: "Mailbox changes"
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
  }

  Text {
    width: parent.width
    text: "Sync"
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    Accessible.role: Accessible.Heading
    Accessible.name: text
  }

  Rectangle {
    width: parent.width
    implicitHeight: details.implicitHeight + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    Column {
      id: details
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(12)
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(6)

      // The model never changes, so the rows stay; each value binding follows the status.
      Repeater {
        model: ["status", "checked", "inbox", "other", "changes"]
        Row {
          id: line
          required property string modelData
          readonly property string label: root.labels[modelData]
          readonly property string value: root.value(modelData)
          width: details.width
          spacing: MailStyle.space(10)
          Accessible.role: Accessible.StaticText
          Accessible.name: label + ": " + value
          Text {
            id: caption
            width: Math.min(Math.ceil(labelMetrics.width) + MailStyle.space(4), line.width * 0.45)
            text: line.label
            textFormat: Text.PlainText
            color: root.dimColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.bodySmall
            wrapMode: Text.Wrap
            Accessible.ignored: true
          }
          Text {
            objectName: "settings-sync-" + line.modelData
            width: line.width - line.spacing - caption.width
            text: line.value
            textFormat: Text.PlainText
            color: root.textColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.bodySmall
            wrapMode: Text.Wrap
            Accessible.ignored: true
          }
        }
      }

      Text {
        objectName: "settings-sync-unsaved"
        width: parent.width
        visible: root.unsaved !== ""
        text: root.unsaved
        textFormat: Text.PlainText
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
        Accessible.role: Accessible.StaticText
        Accessible.name: text
      }

      Text {
        objectName: "settings-sync-problem"
        width: parent.width
        visible: root.problem !== ""
        text: root.problem
        textFormat: Text.PlainText
        color: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
        Accessible.role: Accessible.StaticText
        Accessible.name: text
      }

      Flow {
        width: parent.width
        // A child's visible is false while this row is hidden, so the row reads their tickets.
        visible: undo.ticket !== "" || dismiss.ticket !== ""
        spacing: MailStyle.space(6)
        Widgets.Button {
          id: undo
          objectName: "settings-sync-undo"
          readonly property string ticket: root.ticket("queued", true)
          visible: ticket !== ""
          focusable: true
          text: "Undo latest change"
          foreground: root.textColor
          accent: root.accentColor
          fontFamily: root.panelFontFamily
          fontSize: MailStyle.caption
          onClicked: root.mailbox.undo(ticket)
        }
        Widgets.Button {
          id: dismiss
          objectName: "settings-sync-dismiss"
          readonly property string ticket: root.ticket("conflict", false)
          visible: ticket !== ""
          focusable: true
          text: "Dismiss failed change"
          foreground: root.textColor
          accent: root.accentColor
          fontFamily: root.panelFontFamily
          fontSize: MailStyle.caption
          onClicked: root.mailbox.dismissConflict(ticket)
        }
      }
    }
  }

  Rectangle {
    width: parent.width
    implicitHeight: Math.max(pauseText.implicitHeight, pauseSwitch.implicitHeight) + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    Column {
      id: pauseText
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(12)
      anchors.right: pauseSwitch.left
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)
      Text {
        width: parent.width
        text: "Pause sync"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
      }
      Text {
        objectName: "settings-sync-pause-note"
        width: parent.width
        text: "New mail stops downloading until you resume. Saved mail stays available, and changes such as archiving still reach Gmail."
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
        Accessible.role: Accessible.StaticText
        Accessible.name: text
      }
    }

    ToggleSwitch {
      id: pauseSwitch
      objectName: "settings-sync-pause"
      activeFocusOnTab: true
      cursorRing: true
      Accessible.role: Accessible.CheckBox
      Accessible.name: "Pause sync"
      Accessible.checked: checked
      Accessible.onPressAction: if (interactive && !busy) toggled()
      Accessible.onToggleAction: if (interactive && !busy) toggled()
      Keys.onReturnPressed: if (interactive && !busy) toggled()
      Keys.onEnterPressed: if (interactive && !busy) toggled()
      Keys.onSpacePressed: if (interactive && !busy) toggled()
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      checked: SyncHealth.paused(root.status)
      foreground: root.textColor
      accent: root.accentColor
      onToggled: if (root.mailbox) root.mailbox.setPaused(!SyncHealth.paused(root.status))

      Rectangle {
        objectName: "settings-sync-pause-focus"
        anchors.fill: parent
        radius: Style.cornerRadius
        color: "transparent"
        border.width: Math.max(2, Style.focusBorderWidth)
        border.color: Qt.rgba(pauseSwitch.foreground.r, pauseSwitch.foreground.g, pauseSwitch.foreground.b, 1)
        visible: pauseSwitch.activeFocus
        Accessible.ignored: true
      }
    }
  }
}

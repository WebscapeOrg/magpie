import QtQuick
import "../controls" as Widgets
import "../settings"

Column {
  id: root
  required property var mailbox
  required property color textColor
  required property color dimColor
  required property string panelFontFamily
  readonly property var status: mailbox ? mailbox.status : ({})
  visible: !!mailbox && mailbox.available
    && (mailbox.error !== "" || !!status.error || status.paused === true || !status.complete || Number(status.pendingEdits || 0) > 0
      || Number(status.editConflicts || 0) > 0)
  height: visible ? implicitHeight : 0
  spacing: MailStyle.space(4)

  Text {
    width: parent.width
    textFormat: Text.PlainText
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    wrapMode: Text.WordWrap
    text: {
      if (!root.mailbox) return ""
      if (root.mailbox.error !== "") return root.mailbox.error
      if (root.status.error === "local_disk_low" || root.status.error === "local_disk_full")
        return "Downloads paused: free at least 1 GB of disk space. Saved mail is available."
      if (root.status.error === "gmail_unauthorized" || root.status.error === "gmail_invalid_token")
        return "Sign in to Gmail again to resume syncing. Saved mail and queued changes are kept."
      if (root.status.error === "gmail_rate_limited")
        return "Gmail is limiting requests. Sync will retry automatically. Saved mail is available."
      if (root.status.error) return "Downloads are waiting for Gmail. Saved mail is available."
      if (root.status.paused) return "Mail downloads paused. Saved mail is available."
      if (Number(root.status.editConflicts || 0) > 0)
        return "A mailbox change could not sync. The message may have been removed or its permissions changed."
      if (Number(root.status.pendingEdits || 0) > 0)
        return root.status.pendingEdits + " mailbox changes saved, waiting to sync."
      if (Number(root.status.failed || 0) > 0)
        return root.status.failed + " messages could not finish downloading. Sync will retry automatically."
      if (root.status.complete) return ""
      var saved = Number(root.status.textComplete || 0)
      var total = Number(root.status.estimatedTotal || 0)
      return total > 0 ? saved + " of about " + total + " messages saved for offline use."
        : saved + " messages saved for offline use. Checking the rest..."
    }
  }
  Text {
    width: parent.width
    visible: !!root.mailbox && !root.status.complete
    textFormat: Text.PlainText
    text: "Local search covers downloaded text. Files download when opened."
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }
  Flow {
    width: parent.width
    spacing: MailStyle.space(6)
    Widgets.Button {
      readonly property string ticket: {
        var entries = root.mailbox ? root.mailbox.edits : []
        for (var i=0;i<entries.length;i++) if (entries[i].state === "conflict") return String(entries[i].ticket)
        return ""
      }
      visible: ticket !== ""
      focusable: true
      text: "Dismiss failed change"
      foreground: root.textColor
      fontSize: MailStyle.caption
      onClicked: root.mailbox.dismissConflict(ticket)
    }
    Widgets.Button {
      text: root.status.paused ? "Resume downloads" : "Pause downloads"
      focusable: true
      foreground: root.textColor
      fontSize: MailStyle.caption
      enabled: !!root.mailbox
      onClicked: root.mailbox.setPaused(!root.status.paused)
    }
    Widgets.Button {
      text: "Search online"
      focusable: true
      foreground: root.textColor
      fontSize: MailStyle.caption
      enabled: !!root.mailbox && !root.mailbox.account.listLoading
      onClicked: root.mailbox.searchOnline()
    }
    Widgets.Button {
      readonly property string ticket: {
        var entries = root.mailbox ? root.mailbox.edits : []
        for (var i=entries.length-1;i>=0;i--)
          if (entries[i].state === "queued") return String(entries[i].ticket)
        return ""
      }
      visible: ticket !== ""
      focusable: true
      text: "Undo latest change"
      foreground: root.textColor
      fontSize: MailStyle.caption
      onClicked: root.mailbox.undo(ticket)
    }
  }
}

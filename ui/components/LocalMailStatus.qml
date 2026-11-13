import QtQuick
import "../controls" as Widgets
import "../settings"
import "../account/SyncHealth.js" as SyncHealth

// The line above the Inbox about offline mail. It shows only a problem Dave can act on or should
// know about (Q-011); download progress, pausing and queued changes are in Settings → Mailboxes.
Column {
  id: root
  required property var mailbox
  required property color textColor
  required property color dimColor
  required property string panelFontFamily
  property bool searchActive: false
  readonly property var status: mailbox ? mailbox.status : ({})
  readonly property string message: !mailbox ? "" : mailbox.error !== "" ? mailbox.error : mailbox.problem
  readonly property bool conflicted: SyncHealth.conflicts(status) > 0
  readonly property bool offersSearch: !searchActive && !!mailbox && mailbox.needsGmail === true
  visible: !!mailbox && mailbox.available && (message !== "" || conflicted)
  height: visible ? implicitHeight : 0
  spacing: MailStyle.space(4)

  Text {
    Accessible.role: Accessible.StaticText
    Accessible.name: text
    width: parent.width
    visible: text !== ""
    textFormat: Text.PlainText
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    wrapMode: Text.WordWrap
    text: root.message
  }
  Text {
    Accessible.role: Accessible.StaticText
    Accessible.name: text
    width: parent.width
    visible: root.conflicted
    textFormat: Text.PlainText
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    wrapMode: Text.WordWrap
    text: "A mailbox change could not sync. The message may have been removed or its permissions changed."
  }
  Flow {
    width: parent.width
    // A child's visible is false while this row is hidden, so the row reads their conditions.
    visible: (root.conflicted && dismiss.ticket !== "") || root.offersSearch
    spacing: MailStyle.space(6)
    Widgets.Button {
      id: dismiss
      readonly property string ticket: {
        var entries = root.mailbox ? root.mailbox.edits : []
        for (var entryIndex=0;entryIndex<entries.length;entryIndex++) if (entries[entryIndex].state === "conflict") return String(entries[entryIndex].ticket)
        return ""
      }
      visible: root.conflicted && ticket !== ""
      focusable: true
      text: "Dismiss failed change"
      foreground: root.textColor
      fontSize: MailStyle.caption
      onClicked: root.mailbox.dismissConflict(ticket)
    }
    Widgets.Button {
      id: search
      text: "Search online"
      visible: root.offersSearch
      focusable: true
      foreground: root.textColor
      fontSize: MailStyle.caption
      enabled: !!root.mailbox && !root.mailbox.account.listLoading
      onClicked: root.mailbox.searchOnline()
    }
  }
}

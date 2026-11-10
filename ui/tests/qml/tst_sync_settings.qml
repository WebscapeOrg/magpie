import QtQuick
import QtTest
import "../../components" as Mail
import "../../account" as Account

Item {
  width: 640
  height: 640
  QtObject {
    id: mailbox
    property bool available: true
    property string error: ""
    property string problem: ""
    property bool statusFailed: false
    readonly property bool needsGmail: error === "This search needs Gmail. Choose Search online to continue."
    property double clock: 1793700000000
    property var status: ({})
    property var edits: []
    property var pauses: []
    property string undone: ""
    property string dismissed: ""
    function setPaused(value) { pauses = pauses.concat([value]); status = Object.assign({}, status, {paused: value}) }
    function undo(ticket) { undone = ticket }
    function dismissConflict(ticket) { dismissed = ticket }
  }
  Mail.SyncSettings {
    id: panel
    width: 480
    mailbox: mailbox
    textColor: Qt.rgba(1, 1, 1, 1)
    dimColor: Qt.rgba(0.6, 0.6, 0.6, 1)
    accentColor: Qt.rgba(0.94, 0.64, 0.42, 1)
    panelFontFamily: "sans-serif"
  }
  // A real offline mailbox without a backend, to check the problem it reports.
  QtObject {
    id: offlineAccount
    property var backend: null
    property string accountId: "synthetic@example.test"
  }
  Account.LocalMailbox {
    id: local
    account: offlineAccount
  }
  TestCase {
    name: "SyncSettings"
    when: windowShown
    function find(item, name) {
      if (!item) return null
      if (item.objectName === name) return item
      var children = item.children || []
      for (var index = 0; index < children.length; index++) {
        var found = find(children[index], name)
        if (found) return found
      }
      return null
    }
    function findText(item, text) {
      if (!item) return null
      if (item.text === text) return item
      var children = item.children || []
      for (var index = 0; index < children.length; index++) {
        var found = findText(children[index], text)
        if (found) return found
      }
      return null
    }
    function healthy(extra) {
      return Object.assign({inventoryComplete: true, complete: true, pendingEdits: 0, editConflicts: 0,
        health: {lastChecked: mailbox.clock - 5000, inboxKnown: true, inboxComplete: true, inboxMissing: 0, otherMissing: 0}}, extra || {})
    }
    function init() {
      mailbox.available = true
      mailbox.statusFailed = false
      mailbox.error = ""
      mailbox.problem = ""
      mailbox.status = healthy()
      mailbox.edits = []
      mailbox.pauses = []
      mailbox.undone = ""
      mailbox.dismissed = ""
    }
    function test_a_healthy_mailbox_reads_as_on_the_iphone() {
      verify(panel.visible)
      compare(find(panel, "settings-sync-status").text, "Everything is working")
      compare(find(panel, "settings-sync-checked").text, "Moments ago")
      compare(find(panel, "settings-sync-inbox").text, "Fully updated")
      compare(find(panel, "settings-sync-other").text, "Fully downloaded")
      compare(find(panel, "settings-sync-changes").text, "All synced")
      verify(!find(panel, "settings-sync-unsaved").visible)
      verify(!find(panel, "settings-sync-problem").visible)
      verify(!find(panel, "settings-sync-undo").visible)
      verify(!find(panel, "settings-sync-pause").checked)
    }
    function test_a_first_download_shows_exact_counts_not_the_old_estimate() {
      mailbox.status = healthy({complete: false, textComplete: 5030, estimatedTotal: 4599,
        health: {lastChecked: mailbox.clock - 5000, inboxKnown: true, inboxComplete: false, inboxMissing: 12, otherMissing: 431}})
      compare(find(panel, "settings-sync-inbox").text, "12 messages still downloading")
      compare(find(panel, "settings-sync-other").text, "431 messages still downloading")
      verify(!findText(panel, "5030 of about 4599 messages saved for offline use."))
    }
    function test_pause_sync_is_a_labelled_switch() {
      var toggle = find(panel, "settings-sync-pause")
      compare(toggle.Accessible.name, "Pause sync")
      compare(toggle.Accessible.role, Accessible.CheckBox)
      toggle.forceActiveFocus()
      keyClick(Qt.Key_Space)
      compare(mailbox.pauses, [true])
      verify(toggle.checked)
      compare(find(panel, "settings-sync-status").text, "Sync paused")
      compare(find(panel, "settings-sync-other").text, "Downloaded through the last check")
      keyClick(Qt.Key_Return)
      compare(mailbox.pauses, [true, false])
      verify(!toggle.checked)
    }
    function test_queued_and_failed_changes_can_be_undone_or_dismissed() {
      mailbox.status = healthy({pendingEdits: 2, editConflicts: 1})
      mailbox.edits = [{ticket: "first", state: "queued"}, {ticket: "failed", state: "conflict"}, {ticket: "latest", state: "queued"}]
      compare(find(panel, "settings-sync-changes").text, "2 waiting to sync, 1 could not sync")
      compare(find(panel, "settings-sync-status").text, "Needs attention")
      var undo = find(panel, "settings-sync-undo")
      verify(undo.visible)
      undo.forceActiveFocus()
      keyClick(Qt.Key_Return)
      compare(mailbox.undone, "latest")
      var dismiss = find(panel, "settings-sync-dismiss")
      verify(dismiss.visible)
      dismiss.forceActiveFocus()
      keyClick(Qt.Key_Return)
      compare(mailbox.dismissed, "failed")
    }
    function test_problems_and_unsaved_mail_are_explained() {
      mailbox.status = healthy({unsaved: 2, unsavedReasons: {local_text_unreadable: 2}})
      compare(find(panel, "settings-sync-unsaved").text,
        "2 messages could not be saved in full because Gmail's copy of their text is damaged.")
      mailbox.problem = "Some mail downloads are still failing. Magpie Mail will keep trying."
      verify(find(panel, "settings-sync-problem").visible)
      compare(find(panel, "settings-sync-problem").text, mailbox.problem)
      compare(find(panel, "settings-sync-status").text, "Needs attention")
      mailbox.error = "Could not change the download setting. Try again."
      compare(find(panel, "settings-sync-problem").text, mailbox.error)
    }
    function test_rows_update_in_place() {
      var row = find(panel, "settings-sync-other")
      mailbox.status = healthy({health: {lastChecked: mailbox.clock - 5000, inboxKnown: true, inboxComplete: true, otherMissing: 4599}})
      verify(find(panel, "settings-sync-other") === row, "the row was not rebuilt")
      compare(row.text, "4,599 messages still downloading")
      mailbox.clock += 30000
      verify(find(panel, "settings-sync-other") === row)
    }
    function test_a_failed_status_read_says_so() {
      mailbox.statusFailed = true
      mailbox.error = "Offline mail is unavailable. Your saved messages have been kept."
      compare(find(panel, "settings-sync-status").text, "Status unavailable")
      compare(find(panel, "settings-sync-problem").text, mailbox.error)
    }
    function test_the_lists_needs_gmail_message_stays_out_of_settings() {
      mailbox.error = "This search needs Gmail. Choose Search online to continue."
      verify(!find(panel, "settings-sync-problem").visible)
      mailbox.problem = "Some mail downloads are still failing. Magpie Mail will keep trying."
      compare(find(panel, "settings-sync-problem").text, mailbox.problem)
    }
    function test_undo_needs_a_queued_change_even_beside_a_failed_one() {
      mailbox.status = healthy({editConflicts: 1})
      mailbox.edits = [{ticket: "failed", state: "conflict"}]
      verify(find(panel, "settings-sync-dismiss").visible, "the row of buttons is shown")
      verify(!find(panel, "settings-sync-undo").visible)
    }
    function test_screen_readers_get_every_line() {
      mailbox.status = healthy({unsaved: 2, unsavedReasons: {local_text_unreadable: 2}})
      var unsaved = find(panel, "settings-sync-unsaved")
      compare(unsaved.Accessible.name, unsaved.text)
      compare(find(panel, "settings-sync-pause-note").Accessible.name, find(panel, "settings-sync-pause-note").text)
      compare(find(panel, "settings-sync-status").parent.Accessible.name, "Status: Everything is working")
    }
    function test_an_unavailable_offline_copy_hides_the_section() {
      mailbox.available = false
      verify(!panel.visible)
    }
    function test_the_offline_mailbox_reports_lasting_problems_only() {
      local.status = ({error: "gmail_unauthorized", updated: "1"})
      compare(local.problem, "Sign in to Gmail again to resume syncing. Saved mail and queued changes are kept.")
      local.status = ({error: "gmail_rate_limited", updated: "1"})
      compare(local.problem, "", "a passing limit is not shown")
      verify(local.warnings.episode !== null)
      local.status = ({complete: true})
      compare(local.problem, "")
      compare(local.warnings.episode, null)
      // Paused, queued changes are still sent; their sign-in error still shows.
      local.status = ({paused: true, error: "gmail_unauthorized", pendingEdits: 1})
      compare(local.problem, "Sign in to Gmail again to resume syncing. Saved mail and queued changes are kept.")
      local.statusFailed = true
      local.status = ({complete: true})
      verify(!local.statusFailed, "a new status clears a failed read")
      local.error = local.needsGmailText
      verify(local.needsGmail)
      local.error = "Could not read offline mail. Your saved messages have been kept."
      verify(!local.needsGmail)
      local.error = ""
    }
  }
}

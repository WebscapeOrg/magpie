import QtQuick 2.15
import QtTest 1.3
import "../../components" as Omamail
import "../../account/Model.js" as Model

// Invariant: adding INBOX alone does not remove SPAM or TRASH; the menu must respect the available recovery action.
Item {
  width: 500
  height: 500

  QtObject {
    id: fakeService

    property bool canArchive: true
    property bool canReportSpam: true
    property bool canStar: true
    property bool canOpenOnWeb: false
    property bool hasLabels: true
    property string rawLabelId: ""
    property var messages: []
    property var hosts: null
    function hostForId(id) { return hosts ? hosts[id] || null : fakeService }
  }

  Omamail.MessageMenu {
    id: menu
    anchors.fill: parent
    service: fakeService
    textColor: Qt.rgba(0.1, 0.1, 0.1, 1)
    urgentColor: Qt.rgba(0.8, 0.1, 0.1, 1)
    dimColor: Qt.rgba(0.45, 0.45, 0.45, 1)
    popupBackgroundColor: Qt.rgba(0.95, 0.95, 0.95, 1)
    popupBorderColor: Qt.rgba(0.6, 0.6, 0.6, 1)
    panelFontFamily: "monospace"
  }

  SignalSpy {
    id: actionSpy
    target: menu
    signalName: "actionRequested"
  }
  SignalSpy { id: composeSpy; target: menu; signalName: "composeRequested" }

  TestCase {
    name: "MessageMenuInbox"
    when: windowShown

    // Invariant: these unnamed rows use the same array positions as keyboard navigation.
    function continueRow() { return menu.menuRows[0] }
    function unarchiveRow() { return menu.menuRows[5] }
    function archiveRow() { return menu.menuRows[4] }

    // Invariant: open the popup before inspecting its lazily constructed rows.
    function show(summary) {
      fakeService.messages = [summary]
      fakeService.rawLabelId = ""
      menu.close()
      actionSpy.clear()
      composeSpy.clear()
      menu.openAt(String(summary.id), 100, 100)
      wait(20)
    }

    function cleanup() {
      menu.close()
      fakeService.hosts = null
      fakeService.canReportSpam = true
    }

    function archivedMessage() {
      return { id: "m1", subject: "filed", unread: false, starred: false,
        inInbox: false, inTrash: false, inSpam: false, isSent: false,
        isDraft: false, labelIds: ["Label_17"] }
    }

    function test_an_archived_message_offers_it_in_place_of_archive() {
      show(archivedMessage())
      compare(menu.archived, true)
      compare(unarchiveRow().visible, true)
      compare(archiveRow().visible, false,
        "a message out of the inbox cannot be archived again")
    }

    function test_an_inbox_message_offers_archive_instead() {
      var summary = archivedMessage()
      summary.inInbox = true
      show(summary)
      compare(menu.archived, false)
      compare(unarchiveRow().visible, false)
      compare(archiveRow().visible, true)
    }

    function test_a_draft_offers_continue_editing() {
      var summary = archivedMessage()
      summary.isDraft = true
      show(summary)
      compare(continueRow().visible,true)
      compare(continueRow().text,"Continue editing")
      continueRow().activated()
      compare(composeSpy.count,1)
      compare(composeSpy.signalArguments[0][0],"draft")
      compare(composeSpy.signalArguments[0][1],"m1")
    }

    function test_it_is_not_offered_where_it_would_lie_data() {
      return [
        { tag: "spam", field: "inSpam" },
        { tag: "trash", field: "inTrash" },
        { tag: "sent", field: "isSent" },
        { tag: "draft", field: "isDraft" }
      ]
    }

    function test_it_is_not_offered_where_it_would_lie(row) {
      var summary = archivedMessage()
      summary[row.field] = true
      show(summary)
      compare(menu.archived, false, row.tag + " has its own verb or its own place")
      compare(unarchiveRow().visible, false)
    }

    // Invariant: IMAP has no report-spam action; unarchive moves Junk to Inbox.
    function test_junk_without_a_spam_verb_offers_it() {
      fakeService.canReportSpam = false
      var summary = archivedMessage()
      summary.inSpam = true
      show(summary)
      compare(menu.archived, true, "Junk with no spam verb is where Move to Inbox means")
      compare(unarchiveRow().visible, true)
      compare(unarchiveRow().text, "Move to Inbox")
      unarchiveRow().activated()
      compare(actionSpy.signalArguments[0][0], "unarchive")
      fakeService.canReportSpam = true
    }

    function test_junk_with_a_spam_verb_still_hides_it() {
      fakeService.canReportSpam = true
      var summary = archivedMessage()
      summary.inSpam = true
      show(summary)
      compare(menu.archived, false)
      compare(unarchiveRow().visible, false)
    }

    function test_mixed_mailboxes_use_the_messages_own_spam_capability_data() {
      return [
        { tag: "gmail", id: "gmail:owner:spam", capability: true, offered: false },
        { tag: "imap", id: "imap:owner:Junk:42", capability: false, offered: true }
      ]
    }

    function test_mixed_mailboxes_use_the_messages_own_spam_capability(row) {
      fakeService.canReportSpam = false
      var hosts = ({})
      hosts[row.id] = { canReportSpam: row.capability }
      fakeService.hosts = hosts
      var summary = archivedMessage()
      summary.id = row.id
      summary.inSpam = true
      show(summary)
      compare(menu.archived, row.offered)
      compare(unarchiveRow().visible, row.offered)
      if (row.offered) {
        unarchiveRow().activated()
        compare(actionSpy.signalArguments[0][0], "unarchive")
        compare(actionSpy.signalArguments[0][1], row.id)
      }
    }

    function test_missing_owner_does_not_offer_a_spam_recovery_action() {
      fakeService.canReportSpam = false
      fakeService.hosts = ({})
      var summary = archivedMessage()
      summary.inSpam = true
      show(summary)
      compare(menu.archived, false)
      compare(unarchiveRow().visible, false)
    }

    function test_from_a_label_it_says_the_label_goes_too() {
      show(archivedMessage())
      compare(unarchiveRow().text, "Move to Inbox")

      fakeService.rawLabelId = "Label_17"
      compare(menu.inLabelView, true)
      compare(unarchiveRow().text, "Move to Inbox and remove label")
    }

    function test_a_system_label_is_not_a_label_it_can_remove() {
      show(archivedMessage())
      fakeService.rawLabelId = "IMPORTANT"
      compare(menu.inLabelView, false)
      compare(unarchiveRow().text, "Move to Inbox")
    }

    // Invariant: a folder name is not a removable Gmail label id.
    function test_a_folder_provider_promises_no_label_removal() {
      show(archivedMessage())
      fakeService.rawLabelId = "Archive"
      fakeService.hasLabels = false
      compare(menu.inLabelView, false)
      compare(unarchiveRow().text, "Move to Inbox")
      fakeService.hasLabels = true
    }

    function test_choosing_it_asks_for_unarchive_on_that_message() {
      show(archivedMessage())
      unarchiveRow().activated()

      compare(actionSpy.count, 1)
      compare(actionSpy.signalArguments[0][0], "unarchive")
      compare(actionSpy.signalArguments[0][1], "m1",
        "and names the message the menu was opened on")
      compare(menu.opened, false, "choosing a row closes the menu")
    }

    // Invariant: walking the cursor detects an unlisted row; looking up its known array index would pass tautologically.
    function test_the_keyboard_can_reach_it() {
      show(archivedMessage())
      var steps = 0
      while (steps < menu.menuRows.length
        && (menu.cursorIndex < 0
          || menu.menuRows[menu.cursorIndex].text !== "Move to Inbox")) {
        menu.moveCursor(1)
        steps++
      }
      compare(menu.menuRows[menu.cursorIndex].text, "Move to Inbox",
        "j steps onto the row rather than over it")

      menu.runCursor()
      compare(actionSpy.count, 1)
      compare(actionSpy.signalArguments[0][0], "unarchive",
        "and Enter on it asks for the action")
    }

    // Invariant: the menu must consume the post-mutation summary so stale inSpam cannot offer an ineffective Inbox action.
    function test_a_message_just_reported_as_spam_is_not_offered_it() {
      var summary = archivedMessage()
      summary.inInbox = true
      summary.labelIds = ["INBOX"]
      show(Model.applyLabelChange(summary, "spam"))

      compare(menu.summary.inSpam, true, "the row is in Spam the moment it is reported")
      compare(menu.archived, false)
      compare(unarchiveRow().visible, false)
    }
  }
}

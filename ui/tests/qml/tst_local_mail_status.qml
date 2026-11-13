import QtQuick
import QtTest
import "../../components" as Mail

Item {
  width: 480
  height: 400
  QtObject {
    id: mailbox
    property bool available: true
    property string error: ""
    property string problem: ""
    readonly property bool needsGmail: error === "This search needs Gmail. Choose Search online to continue."
    property var status: ({complete:false,textComplete:501,estimatedTotal:1200})
    property var account: ({listLoading:false})
    property var edits: []
    property int searches: 0
    property string dismissed: ""
    function searchOnline() { searches++ }
    function dismissConflict(ticket) { dismissed=ticket }
  }
  Mail.LocalMailStatus {
    id: notice
    width: parent.width
    mailbox: mailbox
    textColor: Qt.rgba(1,1,1,1)
    dimColor: Qt.rgba(0.69,0.74,0.74,1)
    panelFontFamily: "monospace"
  }
  TestCase {
    name: "LocalMailStatus"
    when: windowShown
    function findText(item, text) {
      if (item.text === text) return item
      for (var childIndex=0;childIndex<item.children.length;childIndex++) {
        var found=findText(item.children[childIndex],text)
        if (found) return found
      }
      return null
    }
    function init() {
      notice.searchActive=false
      mailbox.error=""
      mailbox.problem=""
      mailbox.status=({complete:false,textComplete:501,estimatedTotal:1200})
      mailbox.account=({listLoading:false})
      mailbox.edits=[]
      mailbox.searches=0
      mailbox.dismissed=""
    }
    // Q-011: progress, pausing, queued changes and mail that cannot be saved are routine; they are
    // in Settings → Mailboxes, not above the Inbox.
    function test_routine_sync_shows_nothing_above_the_inbox() {
      var routine = [
        {complete:false,textComplete:5030,estimatedTotal:4599},
        {complete:false,pending:1},
        {complete:true,paused:true},
        {complete:true,pendingEdits:2},
        {complete:true,unsaved:2,unsavedReasons:{local_text_unreadable:2}},
        {complete:false,error:"gmail_server_rate_limited"},
        {complete:false,error:"gmail_request_deferred"},
        {complete:false,failed:3}
      ]
      for (var index=0;index<routine.length;index++) {
        mailbox.status=routine[index]
        verify(!notice.visible, JSON.stringify(routine[index]))
        compare(notice.height, 0)
      }
      mailbox.edits=[{ticket:"queued",state:"queued"}]
      mailbox.status=({complete:true,pendingEdits:1})
      verify(!notice.visible, "a queued change is undone from Settings")
      verify(!findText(notice,"Pause downloads"))
      verify(!findText(notice,"Undo latest change"))
      verify(!findText(notice,"Local search covers downloaded text. Files download when opened."))
    }
    function test_a_problem_is_shown_with_its_own_words() {
      mailbox.problem="Sign in to Gmail again to resume syncing. Saved mail and queued changes are kept."
      verify(notice.visible)
      verify(findText(notice,mailbox.problem).visible)
      verify(!findText(notice,"Search online").visible, "only a mailbox that needs Gmail offers Search online")
      mailbox.status=({complete:true,editConflicts:1})
      mailbox.edits=[{ticket:"failed",state:"conflict"}]
      verify(findText(notice,"Dismiss failed change").visible, "the row of buttons is shown")
      verify(!findText(notice,"Search online").visible, "and still has no Search online")
      mailbox.status=({complete:false,textComplete:501,estimatedTotal:1200})
      mailbox.edits=[]
      notice.searchActive=true
      verify(notice.visible, "a problem still shows while searching")
      mailbox.error="Could not change the download setting. Try again."
      verify(findText(notice,mailbox.error).visible, "the latest action's error comes first")
      mailbox.error=""
      mailbox.problem=""
      verify(!notice.visible)
    }
    function test_a_mailbox_that_needs_gmail_offers_search_online() {
      mailbox.status=({complete:true})
      mailbox.error="This search needs Gmail. Choose Search online to continue."
      verify(notice.visible)
      var search=findText(notice,"Search online")
      verify(search.visible)
      mailbox.account=({listLoading:true})
      verify(!search.enabled)
      mailbox.account=({listLoading:false})
      search.forceActiveFocus()
      keyClick(Qt.Key_Return)
      compare(mailbox.searches,1)
      notice.searchActive=true
      verify(!search.visible, "a submitted search retries from the search status")
    }
    function test_a_change_that_could_not_sync_can_be_dismissed() {
      mailbox.status=({complete:true,editConflicts:1})
      mailbox.edits=[{ticket:"queued",state:"queued"},{ticket:"failed",state:"conflict"}]
      verify(notice.visible)
      verify(findText(notice,"A mailbox change could not sync. The message may have been removed or its permissions changed.").visible)
      var dismiss=findText(notice,"Dismiss failed change")
      verify(dismiss.visible)
      dismiss.forceActiveFocus()
      keyClick(Qt.Key_Return)
      compare(mailbox.dismissed,"failed")
      mailbox.status=({complete:true,editConflicts:0})
      mailbox.edits=[]
      verify(!notice.visible)
    }
    function test_an_unavailable_offline_copy_shows_nothing() {
      mailbox.problem="Downloads are waiting for Gmail. Saved mail is available."
      mailbox.available=false
      verify(!notice.visible)
      mailbox.available=true
      verify(notice.visible)
    }
  }
}

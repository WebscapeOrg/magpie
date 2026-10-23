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
    property var status: ({complete:false,textComplete:501,estimatedTotal:1200})
    property var account: ({listLoading:false})
    property var edits: []
    property int pauses: 0
    property int searches: 0
    property string undone: ""
    function setPaused(value) { pauses++; status=Object.assign({},status,{paused:value}) }
    function searchOnline() { searches++ }
    function undo(ticket) { undone=ticket }
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
      mailbox.status=({complete:false,textComplete:501,estimatedTotal:1200})
      mailbox.account=({listLoading:false})
      mailbox.edits=[]
      mailbox.pauses=0
      mailbox.searches=0
      mailbox.undone=""
    }
    function test_partial_coverage_and_keyboard_pause_are_visible() {
      verify(findText(notice,"501 of about 1200 messages saved for offline use."))
      var pause=findText(notice,"Pause downloads")
      verify(pause)
      pause.forceActiveFocus()
      keyClick(Qt.Key_Return)
      compare(mailbox.pauses,1)
      verify(findText(notice,"Resume downloads"))
    }
    function test_search_waits_for_current_list_and_undo_names_the_saved_ticket() {
      var search=findText(notice,"Search online")
      mailbox.account=({listLoading:true})
      verify(!search.enabled)
      mailbox.account=({listLoading:false})
      search.forceActiveFocus()
      keyClick(Qt.Key_Return)
      compare(mailbox.searches,1)
      mailbox.edits=[{ticket:"one",state:"queued"}]
      var undo=findText(notice,"Undo latest change")
      verify(undo.visible)
      undo.forceActiveFocus()
      keyClick(Qt.Key_Return)
      compare(mailbox.undone,"one")
    }
    function test_completed_storage_hides_notice_but_failure_explains_recovery() {
      mailbox.status=({complete:true})
      verify(!notice.visible)
      mailbox.status=({complete:true,paused:true})
      verify(notice.visible)
      verify(findText(notice,"Resume downloads"))
      mailbox.status=({complete:true,error:"gmail_server_rate_limited"})
      verify(notice.visible)
      verify(findText(notice,"Gmail is limiting requests. Sync will retry automatically. Saved mail is available."))
      mailbox.error="This search needs Gmail. Choose Search online to continue."
      verify(notice.visible)
      verify(findText(notice,mailbox.error))
    }
    function test_search_hides_routine_sync_details_but_keeps_recovery() {
      notice.searchActive = true
      verify(!notice.visible)
      var routine = ["gmail_request_deferred", "gmail_rate_limited", "gmail_server_rate_limited"]
      for (var index = 0; index < routine.length; index++) {
        mailbox.status = {complete:false,error:routine[index]}
        verify(!notice.visible)
      }
      mailbox.status = {complete:false,paused:true}
      verify(!notice.visible)
      mailbox.status = {complete:true,error:"gmail_unauthorized"}
      verify(notice.visible)
      mailbox.status = {complete:true,editConflicts:1}
      verify(notice.visible)
      mailbox.status = {complete:true,pendingEdits:1}
      mailbox.edits = [{ticket:"queued-search-edit",state:"queued"}]
      verify(notice.visible)
      var undo = findText(notice,"Undo latest change")
      verify(undo.visible)
      undo.forceActiveFocus()
      keyClick(Qt.Key_Return)
      compare(mailbox.undone,"queued-search-edit")
      verify(!findText(notice,"Search online").visible)
    }
    function test_local_pacing_and_legacy_limits_do_not_blame_gmail() {
      mailbox.status=({complete:false,error:"gmail_request_deferred"})
      verify(notice.visible)
      verify(findText(notice,"Magpie is spacing out mail requests. Sync will continue automatically. Saved mail is available."))
      verify(!findText(notice,"Gmail is limiting requests. Sync will retry automatically. Saved mail is available."))
      mailbox.status=({complete:false,error:"gmail_rate_limited"})
      verify(findText(notice,"Mail requests are temporarily limited. Sync will retry automatically. Saved mail is available."))
      mailbox.status=({complete:false,error:"",textComplete:502,estimatedTotal:1200})
      verify(findText(notice,"502 of about 1200 messages saved for offline use."))
      mailbox.status=({complete:true,error:""})
      verify(!notice.visible)
    }
  }
}

import QtQuick
import QtTest
import qs.Commons
import "../../components" as Mail
import "../../search" as Search
import "../../settings"
import "../../settings/Display.js" as Display

Item {
  width: 800
  height: 700

  QtObject {
    id: mail
    property var messages: []
    property bool hasMore: false
    property bool listLoading: false
    property bool listLoaded: true
    property string searchQuery: "from:sender@example.test"
    property string selectedId: ""
    property bool canArchive: true
    property string contentDirection: "auto"
    property var inboxTools: null
    property var backend: null
    property int searchGeneration: 1
    property bool searchActive: true
    property var searchStatus: ({phase: "checking", text: "Saved mail results · Searching Gmail...",
      scope: "Gmail accounts · 2 of 3 accounts searched", canStop: true, canRetry: false})
    property int stops: 0
    property int retries: 0
    function stopSearch() { stops++ }
    function retrySearch() { retries++ }
    function loadMore() {}
  }

  Search.SearchStatus {
    id: status
    width: 400
    service: mail
    textColor: Color.foreground
    accentColor: Color.accent
    dimColor: MailStyle.muted(Color.foreground,Color.background)
    panelFontFamily: "sans-serif"
  }

  Mail.MessageList {
    id: list
    y: 250
    width: 400
    height: 350
    service: mail
    textColor: Color.foreground
    accentColor: Color.accent
    dimColor: MailStyle.muted(Color.foreground,Color.background)
    urgentColor: Color.urgent
    panelFontFamily: "sans-serif"
    property var activated: []
    onMessageActivated: function(id) { activated.push(id) }
  }

  TestCase {
    name: "SearchResults"
    when: windowShown

    function row(id) {
      return {id:id, from:{email:"sender@example.test",display:"Sender"}, subject:"Message " + id,
        snippet:"A synthetic message",time:"12:00",date:"",unread:false,starred:false,inInbox:true,labelIds:["INBOX"]}
    }
    function rows(count) {
      var result = []
      for (var index = 0; index < count; index++) result.push(row("account-a:" + index))
      return result
    }
    function init() {
      MailStyle.preferences = Display.normalize({interfaceSize:12,listSize:12})
      status.width = 400
      mail.stops = 0
      mail.retries = 0
      list.activated = []
      mail.searchActive = true
      mail.searchGeneration++
      mail.searchStatus = {phase:"checking",text:"Saved mail results · Searching Gmail...",
        scope:"Gmail accounts · 2 of 3 accounts searched",canStop:true,canRetry:false}
      mail.messages = rows(60)
      wait(25)
    }
    function focusAnchor(index, offset) {
      list.positionViewAtIndex(index, ListView.Beginning)
      list.forceLayout()
      var target = list.itemAtIndex(index)
      verify(target)
      list.contentY = target.y - offset
      wait(25)
      compare(list.viewportAnchor.id, mail.messages[index].id)
      verify(Math.abs(list.viewportAnchor.offset - offset) <= 1)
      return list.viewportAnchor
    }
    function anchorOffset(id) {
      var index = -1
      for (var rowIndex = 0; rowIndex < mail.messages.length; rowIndex++) {
        if (mail.messages[rowIndex].id === id) index = rowIndex
      }
      var target = list.itemAtIndex(index)
      verify(target, "The anchored message remains visible")
      return target.y - list.contentY
    }
    function test_progressive_insert_keeps_the_top_message_and_pixel_offset() {
      var anchor = focusAnchor(20, -17)
      mail.messages = [row("account-b:incoming"), row("account-c:incoming")].concat(mail.messages)
      wait(40)
      verify(Math.abs(anchorOffset(anchor.id) - anchor.offset) <= 1)
    }
    function test_authoritative_reorder_keeps_account_qualified_message() {
      var anchor = focusAnchor(20, -17)
      var result = mail.messages.slice(10)
      result.unshift(row("account-b:20"))
      mail.messages = result
      wait(40)
      compare(list.viewportAnchor.id, "account-a:20")
      verify(Math.abs(anchorOffset(anchor.id) - anchor.offset) <= 1)
    }
    function test_large_authoritative_reduction_keeps_a_surviving_anchor() {
      var anchor = focusAnchor(50, -17)
      mail.messages = mail.messages.slice(40)
      wait(40)
      compare(list.viewportAnchor.id, anchor.id)
      verify(Math.abs(anchorOffset(anchor.id) - anchor.offset) <= 1)
    }
    function test_removed_anchor_uses_the_next_surviving_message() {
      focusAnchor(20, -17)
      mail.messages = mail.messages.filter(function(row) { return row.id !== "account-a:20" })
      wait(40)
      compare(list.viewportAnchor.id, "account-a:21")
      verify(Math.abs(anchorOffset("account-a:21") + 17) <= 1)
    }
    function test_rapid_updates_keep_the_same_anchor() {
      var anchor = focusAnchor(20, -17)
      mail.messages = [row("account-b:first")].concat(mail.messages)
      mail.messages = [row("account-b:second")].concat(mail.messages)
      wait(40)
      verify(Math.abs(anchorOffset(anchor.id) - anchor.offset) <= 1)
    }
    function test_summary_update_keeps_the_pressed_search_result() {
      focusAnchor(20, -17)
      var item = list.itemAtIndex(21)
      verify(item)
      var pointerY = item.y - list.contentY + item.height / 2
      mousePress(list, 20, pointerY)
      var replacement = mail.messages.slice()
      replacement[21] = row("account-a:21")
      replacement[21].unread = true
      mail.messages = replacement
      wait(30)
      mouseRelease(list, 20, pointerY)
      compare(list.activated, ["account-a:21"])
    }
    function test_new_submission_resets_the_list_to_the_beginning() {
      focusAnchor(20, -17)
      mail.searchGeneration++
      mail.messages = rows(30)
      wait(40)
      verify(list.atYBeginning, JSON.stringify({y:list.contentY,origin:list.originY,anchor:list.viewportAnchor}))
      compare(list.viewportAnchor.id, "account-a:0")
    }
    function test_status_and_scope_render_markup_as_literal_text() {
      mail.searchStatus = {phase:"failed",text:'<img src="https://invalid.example/x">',scope:"<b>Account</b>",
        error:'<img src="https://invalid.example/error">',canRetry:true}
      var text = findChild(status,"search-status-text")
      var scope = findChild(status,"search-status-scope")
      var error = findChild(status,"search-status-error")
      compare(text.textFormat, Text.PlainText)
      compare(scope.textFormat, Text.PlainText)
      compare(error.textFormat, Text.PlainText)
      compare(text.text,mail.searchStatus.text)
      compare(scope.text,mail.searchStatus.scope)
      compare(error.text,mail.searchStatus.error)
      verify(error.visible)
      compare(findChild(status,"search-retry").text,"Retry Gmail search")
    }
    function test_stop_and_retry_work_with_keyboard() {
      var stop = findChild(status,"search-stop")
      stop.forceActiveFocus()
      keyClick(Qt.Key_Space)
      compare(mail.stops,1)
      compare(stop.Accessible.name,"Stop search")
      mail.searchStatus = {phase:"failed",text:"Gmail search could not finish.",canRetry:true}
      var retry = findChild(status,"search-retry")
      retry.forceActiveFocus()
      keyClick(Qt.Key_Return)
      compare(mail.retries,1)
      compare(retry.Accessible.name,"Retry Gmail search")
    }
    function test_incomplete_search_never_claims_no_matches() {
      mail.messages = []
      var empty = findChild(list,"message-list-empty")
      verify(empty)
      var phases = ["preparing","local","checking","stopped","failed","partial","invalid"]
      for (var index = 0; index < phases.length; index++) {
        mail.searchStatus = {phase:phases[index],text:"Status"}
        verify(empty.text !== "")
        verify(empty.text.indexOf("No messages match") === -1, phases[index])
      }
      mail.searchStatus = {phase:"complete",text:"Search complete"}
      verify(empty.text.indexOf("No messages match") === 0)
    }
    function test_narrow_enlarged_status_wraps_and_controls_fit() {
      MailStyle.preferences = Display.normalize({interfaceSize:24,listSize:12})
      status.width = 220
      wait(25)
      var text = findChild(status,"search-status-text")
      var scope = findChild(status,"search-status-scope")
      var stop = findChild(status,"search-stop")
      verify(text.lineCount > 1)
      verify(scope.lineCount > 1)
      verify(stop.width <= status.width)
      verify(scope.y >= text.y + text.height)
      verify(stop.parent.y >= scope.y + scope.height)
      verify(status.height >= stop.parent.y + stop.height)
    }
  }
}

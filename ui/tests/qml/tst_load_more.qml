import "../../settings"
import QtQuick 2.15
import QtTest 1.3
import qs.Commons as Commons
import "../../components" as Mail

Item {
  width: 400
  height: MailStyle.space(300)

  QtObject {
    id: fakeService
    property var messages: []
    property bool hasMore: true
    property bool listLoading: false
    property bool listLoaded: true
    property string searchQuery: ""
    property string selectedId: ""
    property bool canArchive: true
    property string contentDirection: "auto"
    property int loads: 0
    property var agentJobs: ({})
    property var agentAttentionByMessage: ({})
    function loadMore() { loads++; listLoading = true }
    function act(_id, _action) {}
    function toggleStar(_id) {}
  }

  Mail.MessageList {
      id: list
      anchors.fill: parent
      service: fakeService
      textColor: Commons.Color.foreground
      accentColor: Commons.Color.accent
      dimColor: Commons.Color.foreground
      urgentColor: Commons.Color.accent
      panelFontFamily: "monospace"
  }

  TestCase {
    name: "LoadMore"
    when: windowShown

    function row(id) {
      return ({ id: id, threadId: "", from: { email: "x@example.com", display: "X" }, subject: "Message " + id,
        snippet: "", time: "", date: "", unread: false, starred: false, inInbox: true, labelIds: ["INBOX"] })
    }

    function init() {
      failOnWarning(/Unable to assign \[undefined\]/)
      // Invariant: Settle deferred load requests before starting the next test's counters.
      fakeService.hasMore = false
      fakeService.listLoading = false
      var rows = []
      for (var rowIndex = 1; rowIndex <= 12; rowIndex++) rows.push(row(rowIndex + ":INBOX"))
      fakeService.messages = rows
      list.contentY = 0
      wait(30)
      fakeService.hasMore = true
      fakeService.loads = 0
      wait(30)
    }

    function test_the_foot_asks_for_the_next_page_once() {
      verify(list.contentHeight > list.height, "the list is longer than the view")
      compare(fakeService.loads, 0)
      list.positionViewAtEnd()
      tryCompare(fakeService, "loads", 1, 1000, "reaching the foot asks for the page")
      list.contentY = list.contentY - 1
      list.positionViewAtEnd()
      wait(20)
      compare(fakeService.loads, 1)
      fakeService.listLoading = false
      var more = fakeService.messages.slice()
      for (var rowIndex = 13; rowIndex <= 24; rowIndex++) more.push(row(rowIndex + ":INBOX"))
      fakeService.messages = more
      wait(20)
      verify(list.contentY < list.contentHeight - list.height, "the foot moved away")
      list.positionViewAtEnd()
      tryCompare(fakeService, "loads", 2, 1000)
    }

    function test_a_short_page_is_followed_until_the_foot_is_out_of_view() {
      fakeService.hasMore = false
      fakeService.messages = []
      fakeService.listLoading = true
      fakeService.hasMore = true
      fakeService.messages = [row("1:INBOX"), row("2:INBOX")]
      wait(30)
      verify(list.contentHeight <= list.height, "shorter than the view")
      fakeService.listLoading = false
      tryCompare(fakeService, "loads", 1, 1000, "the page that settled short is followed")
      compare(fakeService.listLoading, true, "and that ask is on its way")
      fakeService.messages = [row("1:INBOX"), row("2:INBOX"), row("3:INBOX")]
      wait(30)
      fakeService.listLoading = false
      tryCompare(fakeService, "loads", 2, 1000, "and the next, until the foot leaves the view")
      fakeService.hasMore = false
      fakeService.listLoading = false
      wait(30)
      compare(fakeService.loads, 2, "no more, no ask")
    }

    function test_no_more_means_no_ask() {
      fakeService.hasMore = false
      list.positionViewAtEnd()
      wait(20)
      compare(fakeService.loads, 0)
      compare(list.loadMoreIfAtFoot(), false)
    }

    function test_large_lists_keep_delegates_bounded_and_rebind_identity() {
      fakeService.hasMore = false
      var values=[]
      for (var rowIndex=0;rowIndex<10000;rowIndex++) values.push(row("synthetic-"+rowIndex))
      fakeService.messages=values
      wait(100)
      compare(list.count,10000)
      verify(list.contentItem.children.length<100,"only the viewport and nearby rows are instantiated")
      list.reveal("synthetic-9999")
      tryVerify(function(){return list.itemAtIndex(9999)!==null},1000)
      compare(list.itemAtIndex(9999).summary.id,"synthetic-9999")
      verify(list.contentItem.children.length<100,"recycling keeps the delegate count bounded")
      list.reveal("synthetic-0")
      tryVerify(function(){return list.itemAtIndex(0)!==null},1000)
      compare(list.itemAtIndex(0).summary.id,"synthetic-0")
      compare(fakeService.loads,0)
    }

    function test_a_failed_page_waits_for_manual_retry() {
      list.positionViewAtEnd()
      tryCompare(fakeService, "loads", 1, 1000)

      // Invariant: A failed page at the visible foot must not trigger an unbounded automatic retry loop.
      fakeService.listLoading = false
      wait(60)
      compare(fakeService.loads, 1)

      var button = findByName(list, "load-more")
      verify(button !== null)
      button.clicked()
      compare(fakeService.loads, 2, "the explicit retry remains available")
    }

    function test_the_button_is_still_there_for_a_page_that_did_not_come() {
      var button = findByName(list, "load-more")
      verify(button !== null)
      compare(button.visible, true)
      button.clicked()
      compare(fakeService.loads, 1)
    }

    function findByName(item, name) {
      if (item.objectName === name) return item
      var kids = item.children || []
      for (var childIndex = 0; childIndex < kids.length; childIndex++) {
        var found = findByName(kids[childIndex], name)
        if (found) return found
      }
      return null
    }
  }
}

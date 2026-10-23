import QtQuick
import QtTest
import "../../account" as Account
import "NativeDomainFixture.js" as Native
import "../../../benchmarks/mail/baseline/ui/message/Message.js" as Mail

// Invariant: A cached reader resource predates optimistic label changes; reopening it must not restore unread flags or send another mark-read.
Item {
  id: fixture
  QtObject {
    id: transport
    property var pending: ({})
  }
  QtObject {
    id: backend
    property bool ready: true
    property var cached: ({})
    function call(method, parameters, callback) {
      if (method === "reader.open") {
        function projection(message) { return Native.readerProjection(message, parameters) }
        if (parameters.cacheOnly) callback(cached[parameters.id] ? projection(cached[parameters.id]) : null, null)
        else transport.pending[parameters.id] = function(message, error) {
          callback(message ? projection(message) : null, error ? {code: "read_failed"} : null)
        }
      } else if (method === "reader.cancel") {
        callback({cancelled: true}, null)
      } else {
        var result = Native.answer(method, parameters)
        if (result !== undefined) callback(result, null)
      }
    }
  }
  Component {
    id: clientFactory
    QtObject {
      function abortRequest(handle) { handle.aborted = true }
      function getSummaries(ids, callback) { return {aborted: false} }
    }
  }
  Account.MailAccount {
    id: account
    pluginDir: "/synthetic/plugin"
    backend: backend
    clientOverride: clientFactory
    property var readMarks: []
    function act(id, action, quiet) {
      readMarks.push({id: id, action: action, quiet: quiet})
      var members = JSON.parse(JSON.stringify(memberSummaries))
      if (members[id]) members[id] = read(members[id])
      memberSummaries = members
      if (selectedMessage && selectedMessage.id === id) selectedMessage = read(selectedMessage)
      var rows = JSON.parse(JSON.stringify(messages))
      for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
        if (rows[rowIndex].id === id) rows[rowIndex] = read(rows[rowIndex])
        var block = rows[rowIndex].thread
        if (!block || (block.memberIds || []).indexOf(id) < 0) continue
        // Invariant: Read each member's own labels, not the representative row's aggregate conversation flags.
        var unread = rows[rowIndex].labelIds.indexOf("UNREAD") >= 0
        for (var memberIndex = 0; memberIndex < block.memberIds.length; memberIndex++) {
          var member = members[block.memberIds[memberIndex]]
          if (member && (member.labelIds || []).indexOf("UNREAD") >= 0) unread = true
        }
        block.unread = unread
        rows[rowIndex].unread = unread
      }
      messages = rows
      return true
    }
    function read(summary) {
      var next = JSON.parse(JSON.stringify(summary))
      next.unread = false
      next.labelIds = (next.labelIds || []).filter(function(label) { return label !== "UNREAD" })
      return next
    }
  }
  property var unreadMoments: []
  Connections {
    target: account
    function onMemberSummariesChanged() {
      var member = account.memberSummaries.reply
      if (member && (member.unread === true || (member.labelIds || []).indexOf("UNREAD") >= 0))
        fixture.unreadMoments.push("store")
    }
    function onConversationOrganisationChanged() {
      var stops = account.conversationOrganisation ? account.conversationOrganisation.stops || [] : []
      for (var stopIndex = 0; stopIndex < stops.length; stopIndex++)
        if (stops[stopIndex].id === "reply" && stops[stopIndex].unread === true) fixture.unreadMoments.push("stop")
    }
  }
  TestCase {
    name: "CachedReadMemberFlags"
    function resource(id, text, unread, replyUnread) {
      var result = {id: id, threadId: "t", labelIds: unread ? ["INBOX", "UNREAD"] : ["INBOX"],
        payload: {mimeType: "text/plain", headers: [
          {name: "Subject", value: "Thread"}, {name: "From", value: "Sender <sender@example.org>"}],
          body: {data: Mail.bytesToBase64(Mail.utf8Bytes(text), true)}}}
      if (replyUnread !== undefined)
        result.thread = {id: "t", memberIds: ["first", "reply"], count: 2, unread: unread || replyUnread}
      return result
    }
    function summary(id, text, unread, replyUnread) {
      return Native.summary(resource(id, text, unread, replyUnread), new Date())
    }
    function init() {
      account.clearSelection()
      account.accountId = "first@example.org"
      account.lastError = ""
      account.readMarks = []
      transport.pending = ({})
      backend.cached = ({})
      fixture.unreadMoments = []
    }
    function test_a_member_opened_again_from_its_cached_copy_stays_read() {
      account.messages = [summary("first", "Hello", false, true)]
      account.memberSummaries = {reply: summary("reply", "Reply", true)}
      account.selectedThread = {id: "t", memberIds: ["first", "reply"], count: 2, unread: true}
      account.selectedId = "first"

      account.select("reply", false)
      transport.pending.reply(resource("reply", "Reply", true), "")
      compare(account.readMarks.length, 1, "opening an unread member marks it read once")
      compare(account.memberSummaries.reply.unread, false)
      compare(account.messages[0].thread.unread, false, "and the row's block is recomputed")
      verify(account.conversationOrganisation.stops.some(function(stop) { return stop.id === "reply" && !stop.unread }),
        "the rail draws the reply as read")
      backend.cached.reply = resource("reply", "Reply", true)

      backend.cached.first = resource("first", "Hello", false, true)
      account.select("first", false)
      compare(account.selectedBody.text, "Hello")

      fixture.unreadMoments = []
      account.select("reply", false)
      compare(account.selectedBody.text, "Reply", "the cached copy painted")
      compare(fixture.unreadMoments, [], "and the reply never read as unread on the way")
      compare(account.memberSummaries.reply.unread, false, "the store still says read")
      compare(account.memberSummaries.reply.labelIds.indexOf("UNREAD"), -1)
      compare(account.selectedMessage.unread, false, "so does the open summary")
      compare(account.readMarks.length, 1, "and nothing was marked read again")

      transport.pending.reply(resource("reply", "Reply", false), "")
      compare(fixture.unreadMoments, [])
      compare(account.memberSummaries.reply.unread, false)
      compare(account.readMarks.length, 1)
    }
    // Invariant: A cached representative block must not replace the newer block recomputed from member state.
    function test_a_representative_opened_from_its_cached_copy_keeps_the_block_in_hand() {
      account.messages = [summary("first", "Hello", false, false)]
      account.memberSummaries = {reply: summary("reply", "Reply", false)}
      account.selectedThread = {id: "t", memberIds: ["first", "reply"], count: 2, unread: false}
      backend.cached.first = resource("first", "Hello", false, true)
      account.select("first", false)
      compare(account.selectedBody.text, "Hello")
      compare(account.selectedMessage.unread, false, "the row's block, not the file's, says whether the thread is read")
      compare(account.selectedMessage.thread.unread, false)
      compare(account.readMarks, [], "so nothing is marked read again")
    }
  }
}

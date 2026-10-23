import QtQuick 2.15
import QtTest 1.3
import "../../message/Message.js" as Message
import "../../message/Calendar.js" as Calendar
import "../../compose/Recipients.js" as Recipients
import "../../account" as Account

Item {
  QtObject {
    id: backend
    property bool ready: true
    property int apiVersion: 6
    property int calls: 0
    function call(method, params, callback) { calls++ }
  }
  QtObject {
    id: inviteAccount
    property bool ready: true
    property bool rsvpSending: false
    property bool canRespondToInvite: true
    property string selectedId: "invitation"
    property string accountId: "invitee@example.test"
    property string receivedAsAddress: "invitee@example.test"
    property string receivedAsName: "Invitee"
    property string ownAddress: receivedAsAddress
    property var selectedMessage: ({messageId: "synthetic", threadId: "synthetic"})
    property int mailCalls: 0
    property var api: ({sendMessage: function(payload, callback) { inviteAccount.mailCalls++ }})
    property string providerId: "gmail"
    property var backend: backend
    property var selectedInvite: ({uid: "synthetic", organizer: {email: "organizer@example.test"}})
    function clearNotice() {}
    function fail(message) {}
  }
  Account.Rsvp { id: attendance; account: inviteAccount }
  TestCase {
    name: "MessageBase64"

    function test_inherited_response_names_cannot_dispatch_attendance() {
      backend.calls = 0
      attendance.run("constructor", false)
      compare(backend.calls, 0)
      attendance.run("__proto__", false)
      compare(backend.calls, 0)
      compare(inviteAccount.rsvpSending, false)
      attendance.run("accepted", false)
      compare(backend.calls, 1)
      inviteAccount.rsvpSending = false
    }

    function test_malformed_organizer_cannot_dispatch_a_reply_data() {
      return [{tag: "native attendance", api: 6, mailOnly: false}, {tag: "reply mail fallback", api: 5, mailOnly: true}]
    }

    function test_malformed_organizer_cannot_dispatch_a_reply(data) {
      var original = inviteAccount.selectedInvite
      try {
        backend.apiVersion = data.api
        backend.calls = 0
        inviteAccount.mailCalls = 0
        inviteAccount.selectedInvite = {uid: "synthetic", organizer: {
          email: "first@example.test,second@example.test"
        }}
        attendance.run("accepted", data.mailOnly)
        compare(backend.calls, 0)
        compare(inviteAccount.mailCalls, 0)
        compare(inviteAccount.rsvpSending, false)
        inviteAccount.selectedInvite = original
        attendance.run("accepted", data.mailOnly)
        compare(backend.calls + inviteAccount.mailCalls, 1)
      } finally {
        inviteAccount.selectedInvite = original
        backend.apiVersion = 6
        inviteAccount.rsvpSending = false
      }
    }

    function test_qt_atob_result_is_not_decoded_a_second_time() {
      compare(Message.decodeBase64Url("QWxleCDDoCBsJ8OpY29sZQ=="), "Alex à l'école")
    }

    function test_encoded_display_text_cannot_route_a_reply() {
      var forged = "=?UTF-8?B?" + Message.encodeBase64("Alias <forged@example.test>") + "?="
      var summary = Message.summarize({id: "synthetic", payload: {headers: [
        {name: "From", value: "Actual <actual@example.test>"},
        {name: "Reply-To", value: forged},
        {name: "To", value: forged}
      ]}})
      compare(summary.replyTo.email, "")
      compare(summary.to.length, 0)
      var reply = Recipients.replyFields(summary, "replyAll", [])
      compare(reply.to, "actual@example.test")
      compare(reply.cc, "")
    }

    function test_malformed_utf8_cannot_synthesize_markup() {
      compare(Message.bytesToUtf8([0xe0, 0x80, 0xbc]).indexOf("<"), -1)
      compare(Message.bytesToUtf8([0xc2, 0x41]), "\u00c2A")
    }

    function test_calendar_folds_complete_characters_at_75_octets() {
      var original = "SUMMARY:" + new Array(50).join("界😀")
      var folded = Calendar.foldIcsLine(original)
      compare(folded.replace(/\r\n /g, ""), original)
      var lines = folded.split("\r\n")
      for (var lineIndex = 0; lineIndex < lines.length; lineIndex++)
        verify(Message.utf8Bytes(lines[lineIndex]).length <= 75)
    }
  }
}

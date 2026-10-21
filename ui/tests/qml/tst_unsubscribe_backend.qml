import QtQuick
import QtTest
import "../../account" as Account

Item {
  QtObject {
    id: transport
    property bool ready: true
    property var calls: []
    property var done: null
    function call(method, params, callback) {
      calls = calls.concat([{method: method, params: params}])
      done = callback
    }
  }
  QtObject {
    id: mailbox
    property var backend: transport
    property string accountId: "jmap:reader@example.org"
    property string selectedId: "newsletter-a"
    property int detailSerial: 1
    property bool unsubscribing: false
    property string unsubscribeDone: ""
    property string error: ""
    function fail(message) { error = message }
  }
  Account.Unsubscribe { id: action; account: mailbox }
  TestCase {
    name: "UnsubscribeBackend"
    when: windowShown
    function init() {
      transport.ready = true
      transport.calls = []
      transport.done = null
      mailbox.accountId = "jmap:reader@example.org"
      mailbox.selectedId = "newsletter-a"
      mailbox.detailSerial = 1
      mailbox.unsubscribing = false
      mailbox.unsubscribeDone = ""
      mailbox.error = ""
    }
    function test_native_request_and_success() {
      action.postUnsubscribe("https://sender.example/unsubscribe?token=synthetic")
      compare(transport.calls.length, 1)
      compare(transport.calls[0].method, "public.unsubscribe")
      compare(transport.calls[0].params.url, "https://sender.example/unsubscribe?token=synthetic")
      compare(mailbox.unsubscribing, true)
      transport.done({status: 204}, null)
      compare(mailbox.unsubscribing, false)
      compare(mailbox.unsubscribeDone, "Unsubscribed from this list")
    }
    function test_completion_cannot_change_another_message() {
      action.postUnsubscribe("https://sender.example/unsubscribe")
      mailbox.selectedId = "newsletter-b"
      mailbox.detailSerial++
      transport.done({status: 204}, null)
      compare(mailbox.unsubscribing, false)
      compare(mailbox.unsubscribeDone, "")
      compare(mailbox.error, "")
    }
    function test_completion_cannot_report_failure_in_another_account() {
      action.postUnsubscribe("https://sender.example/unsubscribe")
      mailbox.accountId = "jmap:other@example.org"
      transport.done(null, {message: "synthetic failure"})
      compare(mailbox.unsubscribing, false)
      compare(mailbox.unsubscribeDone, "")
      compare(mailbox.error, "")
    }
    function test_reopening_same_message_does_not_accept_an_old_completion() {
      action.postUnsubscribe("https://sender.example/unsubscribe")
      mailbox.detailSerial++
      transport.done({status: 204}, null)
      compare(mailbox.unsubscribeDone, "")
    }
    function test_redirect_is_not_success() {
      action.postUnsubscribe("https://sender.example/unsubscribe")
      transport.done({status: 302}, null)
      compare(mailbox.unsubscribeDone, "")
      verify(mailbox.error.indexOf("redirect") >= 0)
    }
    function test_raw_errors_are_not_displayed() {
      action.postUnsubscribe("https://sender.example/unsubscribe")
      transport.done(null, {message: "secret subscriber token"})
      compare(mailbox.error, "The unsubscribe request could not be sent")
      compare(mailbox.unsubscribing, false)
    }
    function test_private_url_and_unavailable_backend_do_not_dispatch() {
      action.postUnsubscribe("https://127.0.0.1/unsubscribe")
      compare(transport.calls.length, 0)
      transport.ready = false
      action.postUnsubscribe("https://sender.example/unsubscribe")
      compare(transport.calls.length, 0)
      compare(mailbox.unsubscribing, false)
    }
  }
}

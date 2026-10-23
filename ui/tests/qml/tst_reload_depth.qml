import QtQuick 2.15
import QtTest 1.3
import "NativeIntentFixture.js" as NativeIntentFixture
import "../../account" as Account

Item {
  width: 400
  height: 300

  Component {
    id: controlledClient
    QtObject {
      property var requests: []
      function listMessages(query, limit, token, callback) {
        var request = {query: query, limit: limit, token: token, aborted: false}
        requests = requests.concat([request])
        return request
      }
      function abortRequest(handle) { if (handle) handle.aborted = true }
      function getProfile(callback) {}
      function getLabels(callback) {}
      function getSendAs(callback) {}
    }
  }

  Account.MailAccount {
    id: account
    pluginDir: "/tmp/omamail-test"
    accountId: "ada@example.org"
    configuredEmail: "ada@example.org"
    clientOverride: controlledClient
    active: true
    windowOpen: true
  }

  TestCase {
    name: "ReloadDepth"
    function initTestCase() { account.backend = NativeIntentFixture.backend(account) }
    function settleNative() {
      wait(1)
      tryVerify(function() {return account.backend.pending.length === 0})
    }

    when: windowShown

    function rows(count) {
      var result = []
      for (var messageIndex = 0; messageIndex < count; messageIndex++)
        result.push({ id: "m" + messageIndex, subject: "Message " + messageIndex, unread: false, labelIds: ["INBOX"] })
      return result
    }

    // Invariant: Three-row unread-count requests are not reloads and must be excluded from this oracle.
    function listAsks(before) {
      return account.api.requests.slice(before).filter(function(request) {
        return request.limit !== 3
      }).map(function(request) { return request.limit })
    }

    function test_reload_asks_for_the_depth_reached_and_navigation_for_a_page() {
      account.auth.credentials = {clientId:"123-example.apps.googleusercontent.com",clientSecret:"synthetic-secret"}
      account.auth.loggedIn = true
      tryVerify(function() { return account.ready }, 2000,
        "a configured Gmail mailbox with an authenticated session is ready")
      settleNative()

      account.messages = rows(100)
      account.loadedDepth = 100
      account.listLoaded = true
      account.listLoading = false

      var before = account.api.requests.length
      account.loadMessages(false)
      settleNative()
      compare(listAsks(before), [100], "a reload asks for the hundred rows the view reached")

      account.listLoading = false
      account.loadedDepth = 63
      before = account.api.requests.length
      account.loadMessages(false)
      settleNative()
      compare(listAsks(before), [63])

      account.listLoading = false
      before = account.api.requests.length
      account.selectMailbox("archive")
      settleNative()
      compare(account.loadedDepth, 0, "navigation resets the depth")
      compare(listAsks(before), [account.maxMessages], "and asks for a page")
    }
  }
}

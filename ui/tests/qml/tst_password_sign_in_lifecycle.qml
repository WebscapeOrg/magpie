import QtQuick
import QtTest
import "../../providers" as Providers

Item {
  id: root
  QtObject {
    id: credentials
    property var writes: []
    property var lookups: []
    function credentialGet(kind, accountId, clientId, callback) {
      lookups = lookups.concat([callback])
    }
    function credentialPut(kind, accountId, clientId, secret, callback) {
      writes = writes.concat([{ accountId: accountId, secret: secret }])
      callback(true, "")
    }
    function credentialDelete(kind, accountId, clientId, callback) { callback(true, "") }
  }
  QtObject {
    id: fakeBackend
    property bool ready: true
    property var requests: []
    function call(method, params, callback) {
      requests = requests.concat([{ method: method, params: params, callback: callback }])
    }
  }
  Component {
    id: imapAuthFactory
    Providers.ImapAuth {
      pluginDir: "/synthetic"
      platform: credentials
      accountId: "imap:one@example.test"
      settings: ({ imapHost: "imap.example.test", imapPort: 993,
        smtpHost: "smtp.example.test", smtpPort: 465, username: "one@example.test" })
    }
  }
  Component { id: imapClientFactory; Providers.ImapClient { backend: fakeBackend; email: "one@example.test" } }
  Component {
    id: jmapAuthFactory
    Providers.JmapAuth {
      pluginDir: "/synthetic"
      platform: credentials
      accountId: "jmap:one@example.test"
      address: "one@example.test"
      settings: ({ sessionUrl: "https://mail.example.test/session", accountId: "one", authScheme: "basic" })
    }
  }
  Component { id: jmapClientFactory; Providers.JmapClient { backend: fakeBackend } }

  TestCase {
    name: "PasswordSignInLifecycle"
    function init() { credentials.writes = []; credentials.lookups = []; fakeBackend.requests = [] }
    function providers() { return [{ tag: "imap", protocol: "imap" }, { tag: "jmap", protocol: "jmap" }] }
    function pair(protocol) {
      var auth = createTemporaryObject(protocol === "imap" ? imapAuthFactory : jmapAuthFactory, root)
      var client = createTemporaryObject(protocol === "imap" ? imapClientFactory : jmapClientFactory, root, { auth: auth })
      verify(auth && client)
      return { auth: auth, client: client }
    }
    function verification(protocol) {
      var method = protocol === "imap" ? "imap.folders" : "jmap.verify"
      var requests = fakeBackend.requests.filter(function(request) { return request.method === method })
      verify(requests.length > 0)
      return requests[requests.length - 1]
    }
    function accept(request, protocol) {
      request.callback(protocol === "imap"
        ? { folders: [], special: {}, capabilities: [], labels: [] }
        : { session: {}, sessionUrl: "https://mail.example.test/session", accountId: "one", mailboxes: [] }, null)
    }
    function test_cancel_discards_verification_data() { return providers() }
    function test_cancel_discards_verification(data) {
      var objects = pair(data.protocol)
      var successes = 0
      objects.auth.loginSucceeded.connect(function() { successes++ })
      verify(objects.auth.signIn("first-secret"))
      var request = verification(data.protocol)
      objects.auth.cancelLogin()
      accept(request, data.protocol)
      wait(0)
      compare(credentials.writes.length, 0, "cancelled verification must not persist a secret")
      compare(successes, 0)
      compare(objects.auth.loggedIn, false)
      compare(objects.auth.pendingPassword || objects.auth.pendingSecret || "", "")
    }
    function test_old_verification_cannot_complete_a_new_attempt_data() { return providers() }
    function test_old_verification_cannot_complete_a_new_attempt(data) {
      var objects = pair(data.protocol)
      verify(objects.auth.signIn("first-secret"))
      var first = verification(data.protocol)
      objects.auth.cancelLogin()
      verify(objects.auth.signIn("second-secret"))
      var second = verification(data.protocol)
      accept(first, data.protocol)
      compare(credentials.writes.length, 0, "an old answer cannot approve an unverified replacement password")
      compare(objects.auth.loginBusy, true)
      accept(second, data.protocol)
      compare(credentials.writes.length, 1)
      compare(credentials.writes[0].secret, "second-secret")
    }
    function test_logout_discards_credential_lookup_data() { return providers() }
    function test_logout_discards_credential_lookup(data) {
      var objects = pair(data.protocol)
      var successes = 0
      objects.auth.loginSucceeded.connect(function() { successes++ })
      objects.auth.restoreSession()
      compare(credentials.lookups.length, 1)
      objects.auth.logout()
      credentials.lookups[0]("stored-secret", "")
      compare(objects.auth.loggedIn, false, "logout must not be undone by an earlier keyring answer")
      compare(successes, 0)
      compare(objects.auth.sessionBusy, false)
    }
    function test_busy_sign_in_cannot_replace_the_pending_secret_data() { return providers() }
    function test_busy_sign_in_cannot_replace_the_pending_secret(data) {
      var objects = pair(data.protocol)
      verify(objects.auth.signIn("first-secret"))
      var first = verification(data.protocol)
      verify(!objects.auth.signIn("second-secret"))
      accept(first, data.protocol)
      compare(credentials.writes.length, 1)
      compare(credentials.writes[0].secret, "first-secret")
    }
  }
}

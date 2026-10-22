import QtQuick
import QtTest
import "../../providers" as Providers

Item {
  QtObject {
    id: transport
    property bool ready: true
    property var calls: []
    function call(method, params, callback) {
      calls = calls.concat([{method: method, params: params, done: callback}])
    }
  }
  QtObject {
    id: storage
    property var writes: []
    property var deletes: []
    property bool holdWrites: false
    property var pendingWrite: null
    function credentialPut(kind, accountId, clientId, value, done) {
      writes = writes.concat([{accountId: accountId, value: value}])
      if (holdWrites) pendingWrite = done
      else done(true, "")
    }
    function credentialDelete(kind, accountId, clientId, done) {
      deletes = deletes.concat([accountId])
      if (typeof done === "function") done(true, "")
    }
  }
  Component {
    id: factory
    Providers.AuthManager {
      pluginDir: "/synthetic/plugin"
      backend: transport
      platform: storage
    }
  }
  Loader {
    id: lifecycleLoader
    active: false
    sourceComponent: factory
  }
  TestCase {
    name: "GoogleAuthSession"
    function init() {
      transport.calls = []
      storage.writes = []
      storage.deletes = []
      storage.holdWrites = false
      storage.pendingWrite = null
    }
    function manager() {
      var auth = createTemporaryObject(factory, parent)
      auth.accountId = "first@example.org"
      auth.credentials = {clientId: "synthetic-client", clientSecret: "synthetic-secret"}
      return auth
    }
    function test_account_removal_cancels_deferred_session_restore() {
      failOnWarning(/.?/)
      lifecycleLoader.active = true
      verify(lifecycleLoader.item)
      lifecycleLoader.item.credentials = {clientId:"123-example.apps.googleusercontent.com",clientSecret:"synthetic-secret"}
      verify(lifecycleLoader.item.credentialsPresent)
      lifecycleLoader.item.accountId = "removed@example.org"
      lifecycleLoader.active = false
      wait(10)
      compare(transport.calls, [])
      compare(storage.writes, [])
      compare(storage.deletes, [])
    }
    function test_logout_cancels_deferred_session_restore() {
      var auth = manager()
      auth.credentials = {clientId:"123-example.apps.googleusercontent.com",clientSecret:"synthetic-secret"}
      auth.logout()
      wait(10)
      compare(transport.calls.filter(function(request) { return request.method === "auth.token" }), [])
      compare(auth.savedSessionPresent, false)
      compare(auth.loggedIn, false)
    }
    function test_deferred_restore_uses_the_current_account() {
      var auth = manager()
      auth.credentials = {clientId:"123-example.apps.googleusercontent.com",clientSecret:"synthetic-secret"}
      auth.accountId = "second@example.org"
      wait(10)
      compare(transport.calls.length, 1)
      compare(transport.calls[0].method, "auth.token")
      compare(transport.calls[0].params.accountId, "second@example.org")
    }
    function test_waiter_session_change_blocks_later_token_data() {
      return [
        {tag: "sign-out", change: function(auth) { auth.logout() }},
        {tag: "account", change: function(auth) { auth.accountId = "second@example.org" }},
        {tag: "account-return", change: function(auth) {
          auth.accountId = "second@example.org"
          auth.accountId = "first@example.org"
        }},
        {tag: "client", change: function(auth) {
          auth.credentials = {clientId: "replacement-client", clientSecret: "synthetic-secret"}
        }}
      ]
    }
    function test_waiter_session_change_blocks_later_token(data) {
      var auth = manager()
      var observed = []
      auth.tokenWaiters = [
        function(token, error) { data.change(auth) },
        function(token, error) { observed.push({token: token, error: error}) }
      ]
      auth.acceptSignIn({ok: true, accessToken: "synthetic-access", expiresIn: 3600,
        scope: auth.scopes.join(" "), refreshToken: ""})
      compare(observed.length, 1)
      compare(observed[0].token, "")
      verify(observed[0].error !== "")
      compare(auth.tokenWaiters, [])
    }
    function test_waiter_signout_does_not_announce_signin() {
      var auth = manager()
      var successes = 0
      auth.loginSucceeded.connect(function() { successes++ })
      auth.tokenWaiters = [function(token, error) { auth.logout() }]
      auth.acceptSignIn({ok: true, accessToken: "synthetic-access", expiresIn: 3600,
        scope: auth.scopes.join(" "), refreshToken: ""})
      compare(successes, 0)
      compare(auth.loggedIn, false)
    }
    function test_unchanged_session_delivers_all_waiters_and_success() {
      var auth = manager()
      var tokens = []
      var successes = 0
      auth.loginSucceeded.connect(function() { successes++ })
      auth.tokenWaiters = [
        function(token, error) { tokens.push(token) },
        function(token, error) { tokens.push(token) }
      ]
      auth.acceptSignIn({ok: true, accessToken: "synthetic-access", expiresIn: 3600,
        scope: auth.scopes.join(" "), refreshToken: ""})
      compare(tokens, ["synthetic-access", "synthetic-access"])
      compare(successes, 1)
      compare(auth.loggedIn, true)
    }
    function test_terminal_native_error_is_signed_out_data() {
      return [
        {tag: "missing", code: "gmail_token_missing"},
        {tag: "invalid", code: "gmail_token_invalid"},
        {tag: "revoked", code: "gmail_invalid_token"},
        {tag: "unauthorized", code: "gmail_unauthorized"}
      ]
    }
    function test_terminal_native_error_is_signed_out(data) {
      var auth = manager()
      auth.savedSessionPresent = true
      auth.refreshWithToken("", "restore")
      var request = transport.calls[transport.calls.length - 1]
      request.done(null, {code: -32000, message: data.code})
      compare(auth.savedSessionPresent, false)
      compare(auth.refreshRetryAttempt, 0)
      compare(auth.loggedIn, false)
      verify(auth.lastError.indexOf("Sign in again") >= 0)
    }
    function test_transient_native_error_keeps_saved_session() {
      var auth = manager()
      auth.savedSessionPresent = true
      auth.refreshWithToken("", "restore")
      transport.calls[transport.calls.length - 1].done(null, {code: -32000, message: "request_timed_out"})
      compare(auth.savedSessionPresent, true)
      compare(auth.refreshRetryAttempt, 1)
      compare(storage.deletes.length, 0)
    }
    function test_account_change_clears_previous_token() {
      var auth = manager()
      auth.accessToken = "synthetic-first-token"
      auth.accessTokenExpiresAt = Date.now() + 3600000
      auth.loggedIn = true
      auth.accountId = "second@example.org"
      compare(auth.accessToken, "")
      compare(auth.loggedIn, false)
    }
    function test_pending_token_cannot_reach_a_replacement_account() {
      var auth = manager()
      var results = []
      auth.postTokenRequest("", function(value) { results.push(value) })
      var request = transport.calls[transport.calls.length - 1]
      auth.accountId = "second@example.org"
      request.done({access_token: "synthetic-first-token", expires_in: 3600}, null)
      compare(results.length, 0)
      compare(auth.accessToken, "")
    }
    function test_logout_during_write_does_not_delete_replacement_grant() {
      var auth = manager()
      storage.holdWrites = true
      auth.storeRefreshToken("synthetic-refresh")
      auth.logout()
      auth.accountId = "second@example.org"
      storage.pendingWrite(true, "")
      verify(storage.deletes.length > 0)
      verify(storage.deletes.every(function(id) { return id === "first@example.org" }))
    }
    function test_logout_of_replacement_does_not_delete_pending_old_grant() {
      var auth = manager()
      storage.holdWrites = true
      auth.storeRefreshToken("synthetic-refresh")
      auth.accountId = "second@example.org"
      auth.logout()
      storage.pendingWrite(true, "")
      compare(storage.deletes, ["second@example.org"])
    }
    function test_sign_in_port_conflict_has_actionable_error() {
      var auth = manager()
      auth.credentials = {clientId: "123-example.apps.googleusercontent.com", clientSecret: "synthetic-secret"}
      auth.beginLogin()
      var request = transport.calls[transport.calls.length - 1]
      compare(request.method, "auth.begin")
      request.done(null, {code: -32000, message: "auth_port_unavailable"})
      verify(auth.lastError.indexOf("Could not listen on port") >= 0)
      compare(auth.loginBusy, false)
    }
    function test_first_sign_in_retains_its_unnamed_grant() {
      var auth = createTemporaryObject(factory, parent)
      auth.credentials = {clientId: "synthetic-client", clientSecret: "synthetic-secret"}
      auth.accessToken = "synthetic-new-token"
      auth.loggedIn = true
      auth.unnamedRefreshToken = "synthetic-new-refresh"
      auth.accountId = "new@example.org"
      compare(auth.accessToken, "synthetic-new-token")
      compare(auth.loggedIn, true)
      compare(storage.writes.length, 1)
      compare(storage.writes[0].accountId, "new@example.org")
      compare(auth.unnamedRefreshToken, "")
    }
  }
}

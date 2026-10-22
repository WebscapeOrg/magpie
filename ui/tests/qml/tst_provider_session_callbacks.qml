import QtQuick
import QtTest
import "../../providers" as Providers

Item {
  id: root
  QtObject {
    id: fakeBackend
    property bool ready: true
    property string executable: "/synthetic/omamail"
    property var requests: []
    function call(method, params, callback) {
      requests = requests.concat([{ method: method, params: params, callback: callback }])
    }
  }
  Component {
    id: outlookFactory
    Providers.OutlookAuth {
      pluginDir: "/synthetic"
      accountId: "outlook:one@example.test"
      configuredEmail: "one@example.test"
      configuredClientId: "12345678-1234-4abc-9def-1234567890ab"
    }
  }
  Component { id: heyFactory; Providers.HeyAuth { pluginDir: "/synthetic" } }
  Component { id: heyClientFactory; Providers.HeyClient {} }
  Loader { id: lifecycleLoader; active: false; sourceComponent: outlookFactory }
  TestCase {
    name: "ProviderSessionCallbacks"
    function init() { fakeBackend.requests = [] }
    function test_removed_outlook_owner_does_not_restore_a_session() {
      failOnWarning(/.?/)
      lifecycleLoader.active = true
      verify(lifecycleLoader.item)
      lifecycleLoader.item.backend = fakeBackend
      lifecycleLoader.item.accountId = "outlook:removed@example.test"
      lifecycleLoader.active = false
      wait(10)
      compare(fakeBackend.requests.length, 0)
    }
    function test_outlook_waiter_logout_prevents_sign_in_announcement() {
      var auth = createTemporaryObject(outlookFactory, root)
      wait(0)
      var successes = 0
      auth.loginSucceeded.connect(function() { successes++ })
      auth.loginBusy = true
      auth.pendingAccessToken = "synthetic-access"
      auth.pendingRefreshToken = "synthetic-refresh"
      auth.pendingExpiresIn = 3600
      auth.tokenWaiters = [function() { auth.logout() }]
      auth.completeSignIn(true, "", auth.sessionGeneration)
      compare(auth.loggedIn, false)
      compare(successes, 0, "sign-out during token delivery must not announce sign-in")
    }
    function test_hey_account_change_discards_cached_mail() {
      var auth = hey()
      auth.accountId = "hey:first@example.test"
      auth.loggedIn = true
      var client = createTemporaryObject(heyClientFactory, root, { auth: auth, backend: fakeBackend })
      client.rememberResources([{ id: "1:1", marker: "first-account-private-mail" }])
      auth.accountId = "hey:second@example.test"
      var result = undefined
      client.getMessage("1:1", false, function(message) { result = message })
      wait(10)
      compare(result, null, "cached mail must not cross an account switch")
    }
    function test_hey_account_change_discards_cached_sender() {
      var auth = hey()
      auth.accountId = "hey:first@example.test"
      auth.loggedIn = true
      var client = createTemporaryObject(heyClientFactory, root, { auth: auth, backend: fakeBackend })
      client.address = "first@example.test"
      auth.accountId = "hey:second@example.test"
      var delivered = false
      client.getSendAs(function() { delivered = true })
      wait(10)
      compare(delivered, false, "sender must be loaded for the replacement account")
      compare(fakeBackend.requests[fakeBackend.requests.length - 1].method, "hey.profile")
    }
    function test_graph_probe_stops_after_a_waiter_signs_out_data() {
      return [{ tag: "accepted", accepted: true }, { tag: "temporary-error", accepted: false }]
    }
    function test_graph_probe_stops_after_a_waiter_signs_out(data) {
      var auth = createTemporaryObject(outlookFactory, root)
      wait(0)
      auth.backend = fakeBackend
      auth.loggedIn = true
      auth.graphRoundOfSignIn = true
      var successes = 0
      var refusals = 0
      auth.loginSucceeded.connect(function() { successes++ })
      auth.graphRefused.connect(function() { refusals++ })
      auth.graphWaiters = [function() { auth.logout() }]
      auth.probeGraphConsent("")
      var request = fakeBackend.requests[fakeBackend.requests.length - 1]
      compare(request.method, "auth.token")
      request.callback(data.accepted ? { access_token: "synthetic-graph", expires_in: 3600,
        scope: "Mail.Send Calendars.ReadWrite" } : null, data.accepted ? null : { message: "network unavailable" })
      compare(auth.loggedIn, false)
      compare(successes, 0)
      compare(refusals, 0)
    }
    function test_graph_completion_stops_after_a_waiter_signs_out_data() {
      return [{ tag: "accepted", accepted: true }, { tag: "refused", accepted: false }]
    }
    function test_graph_completion_stops_after_a_waiter_signs_out(data) {
      var auth = createTemporaryObject(outlookFactory, root)
      wait(0)
      auth.loggedIn = true
      auth.graphRoundOfSignIn = true
      var successes = 0
      var refusals = 0
      auth.loginSucceeded.connect(function() { successes++ })
      auth.graphRefused.connect(function() { refusals++ })
      auth.graphWaiters = [function() { auth.logout() }]
      if (data.accepted) auth.acceptGraphSignIn({ accessToken: "synthetic-graph", expiresIn: 3600,
        scope: "Mail.Send Calendars.ReadWrite", idToken: "h.eyJwcmVmZXJyZWRfdXNlcm5hbWUiOiJvbmVAZXhhbXBsZS50ZXN0In0.s" })
      else auth.failGraphRound("synthetic refusal")
      compare(auth.loggedIn, false)
      compare(successes, 0)
      compare(refusals, 0, "a removed session must not announce Graph results")
    }
    function test_graph_waiters_cannot_receive_a_previous_accounts_token() {
      var auth = createTemporaryObject(outlookFactory, root)
      wait(0)
      var second = null
      auth.graphWaiters = [function() { auth.accountId = "outlook:two@example.test" },
        function(token, error) { second = { token: token, error: error } }]
      auth.finishGraphWaiters("first-account-token", "")
      verify(second !== null)
      compare(second.token, "", "no token crosses an account switch inside another waiter")
      verify(second.error !== "")
    }
    function test_one_graph_waiter_exception_does_not_strand_the_rest() {
      var auth = createTemporaryObject(outlookFactory, root)
      wait(0)
      var answered = false
      auth.graphWaiters = [function() { throw new Error("synthetic consumer failure") },
        function(token, error) { answered = true }]
      try { auth.finishGraphWaiters("same-account-token", "") } catch (error) {}
      verify(answered)
    }
    function test_tenant_change_invalidates_session_context_and_tokens() {
      var auth = createTemporaryObject(outlookFactory, root)
      wait(0)
      var context = auth.sessionContext()
      auth.accessToken = "old-tenant-token"
      auth.accessTokenExpiresAt = Date.now() + 3600000
      auth.loggedIn = true
      auth.entrySettings = { tenant: "organizations" }
      verify(!auth.isCurrent(context))
      compare(auth.accessToken, "")
      compare(auth.loggedIn, false)
    }
    function test_unidentified_graph_grant_cannot_replace_the_mailbox_grant() {
      var auth = createTemporaryObject(outlookFactory, root)
      wait(0)
      auth.loggedIn = true
      auth.accessToken = "mail-token"
      auth.backend = fakeBackend
      auth.acceptGraphSignIn({ accessToken: "unbound-graph-token", refreshToken: "unbound-refresh-token",
        expiresIn: 3600, scope: "Mail.Send Calendars.ReadWrite", idToken: "" })
      compare(auth.graphAccessToken, "", "a grant without a matching identity must not be accepted")
      compare(auth.graphGrants, 0)
      compare(fakeBackend.requests.filter(function(request) { return request.method === "auth.store" }).length, 0)
      compare(auth.accessToken, "mail-token")
      compare(auth.loggedIn, true)
    }
    function hey() {
      var auth = createTemporaryObject(heyFactory, root)
      auth.backend = fakeBackend
      auth.heyPath = "/synthetic/hey"
      auth.toolsChecked = true
      auth.missingTools = []
      fakeBackend.requests = []
      return auth
    }
    function test_cancelled_empty_hey_read_does_not_deliver() {
      var auth = hey()
      var client = createTemporaryObject(heyClientFactory, root, { auth: auth })
      var delivered = 0
      var handle = client.getMessages([], true, function() { delivered++ })
      client.abortRequest(handle)
      wait(1)
      compare(delivered, 0)
    }
    function test_cancelled_hey_start_cannot_restart_polling() {
      var auth = hey()
      auth.beginLogin()
      compare(fakeBackend.requests[0].method, "hey.loginStart")
      var start = fakeBackend.requests[0]
      auth.cancelLogin()
      start.callback({}, null)
      wait(650)
      compare(fakeBackend.requests.filter(function(request) { return request.method === "hey.loginPoll" }).length, 0)
      compare(auth.loginBusy, false)
    }
    function test_old_hey_status_cannot_restore_a_logged_out_session() {
      var auth = hey()
      auth.restoreSession()
      var status = fakeBackend.requests[0]
      compare(status.method, "hey.status")
      auth.logout()
      fakeBackend.requests[fakeBackend.requests.length - 1].callback({}, null)
      status.callback({ authenticated: true }, null)
      compare(auth.loggedIn, false)
      compare(auth.sessionBusy, false)
    }
  }
}

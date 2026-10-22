import QtQuick
import QtTest
import "../../providers" as Providers
import "../../backend" as Backend

Item {
  id: fixture
  property int callbackCount: 0
  Backend.Backend {
    id: transport
    executable: "/synthetic/omamail"
    expectedVersion: "0.11.0"
    expectedApiVersion: 7
  }
  QtObject {
    id: shellPlatform
    property var opened: []
    property var saved: null
    property var fetched: null
    property var stored: null
    property var deletes: []
    function openExternal(url) { opened.push(url) }
    function writeConfig(name, text, callback) { saved = callback }
    function credentialGet(kind, accountId, clientId, callback) { fetched = callback }
    function credentialPut(kind, accountId, clientId, value, callback) { stored = callback }
    function credentialDelete(kind, accountId, clientId) { deletes.push({accountId: accountId, clientId: clientId}) }
  }
  Component {
    id: authFactory
    Providers.AuthManager {
      pluginDir: "/synthetic/plugin"
      backend: transport
      platform: shellPlatform
    }
  }
  Loader { id: owner; active: false; sourceComponent: authFactory }
  TestCase {
    name: "GoogleBackendLifetime"
    property var pipe
    function requests() { return pipe.written.trim().split("\n").map(function(line) { return JSON.parse(line) }) }
    function answer(request, result) {
      transport.receive(JSON.stringify({jsonrpc: "2.0", id: request.id, result: result}))
    }
    function initTestCase() {
      pipe = transport.children.filter(function(child) { return child.command && child.command[1] === "serve" })[0]
      verify(pipe)
      pipe.started()
      answer(requests()[0], {protocol: 1, version: "0.11.0", apiVersion: 7,
        methods: ["auth.begin", "auth.poll", "auth.token", "auth.cancel"]})
      verify(transport.ready)
    }
    function init() {
      owner.active = true
      verify(owner.item)
      owner.item.accountId = "synthetic@example.test"
      owner.item.credentials = {clientId: "123-example.apps.googleusercontent.com", clientSecret: "synthetic-secret"}
      owner.item.cancelLogin()
      fixture.callbackCount = 0
      shellPlatform.opened = []
      shellPlatform.saved = null
      shellPlatform.fetched = null
      shellPlatform.stored = null
      shellPlatform.deletes = []
    }
    function cleanup() { owner.active = false; wait(0) }
    function test_late_begin_cancels_created_flow_without_opening_browser() {
      failOnWarning(/.?/)
      owner.item.beginLogin()
      var request = requests().slice(-1)[0]
      compare(request.method, "auth.begin")
      owner.active = false
      wait(0)
      answer(request, {id: "late-flow", url: "https://accounts.example.test/synthetic"})
      compare(shellPlatform.opened, [])
      var cancellation = requests().slice(-1)[0]
      compare(cancellation.method, "auth.cancel")
      compare(cancellation.params.id, "late-flow")
    }
    function test_late_poll_cannot_deliver_tokens_after_removal() {
      failOnWarning(/.?/)
      owner.item.loginBusy = true
      owner.item.nativeFlow = "known-flow"
      owner.item.tokenWaiters = [function() { fixture.callbackCount++ }]
      owner.item.pollNativeLogin()
      var request = requests().slice(-1)[0]
      compare(request.method, "auth.poll")
      owner.active = false
      wait(0)
      answer(request, {pending: false, status: 200, body: "{}"})
      compare(fixture.callbackCount, 0)
      compare(shellPlatform.opened, [])
      var cancellations = requests().filter(function(request) {
        return request.method === "auth.cancel" && request.params.id === "known-flow"
      })
      compare(cancellations.length, 1)
    }
    function test_late_token_cannot_reach_a_removed_session() {
      failOnWarning(/.?/)
      owner.item.postTokenRequest("", function(result) { fixture.callbackCount++ })
      var request = requests().slice(-1)[0]
      compare(request.method, "auth.token")
      owner.active = false
      wait(0)
      answer(request, {access_token: "synthetic-token", expires_in: 3600})
      compare(fixture.callbackCount, 0)
    }
    function test_removed_owner_ignores_client_file_save_completion() {
      failOnWarning(/.?/)
      verify(owner.item.saveCredentials(JSON.stringify({installed: {
        client_id: "123-example.apps.googleusercontent.com", client_secret: "synthetic-secret"}})))
      verify(shellPlatform.saved)
      owner.active = false
      wait(0)
      shellPlatform.saved(true, "")
      compare(shellPlatform.opened, [])
    }
    function test_removed_owner_ignores_legacy_credential_lookup() {
      failOnWarning(/.?/)
      owner.item.backend = null
      owner.item.startSecretLookup()
      verify(shellPlatform.fetched)
      owner.active = false
      wait(0)
      shellPlatform.fetched("synthetic-refresh-token", "")
      compare(shellPlatform.deletes, [])
    }
    function test_cancelled_write_is_removed_after_owner_destruction() {
      failOnWarning(/.?/)
      owner.item.storeRefreshToken("synthetic-refresh-token")
      verify(shellPlatform.stored)
      owner.item.logout()
      compare(shellPlatform.deletes.length, 1)
      owner.active = false
      wait(0)
      shellPlatform.stored(true, "")
      compare(shellPlatform.deletes, [
        {accountId: "synthetic@example.test", clientId: "123-example.apps.googleusercontent.com"},
        {accountId: "synthetic@example.test", clientId: "123-example.apps.googleusercontent.com"}])
    }
    function test_live_begin_opens_the_browser() {
      owner.item.beginLogin()
      answer(requests().slice(-1)[0], {id: "live-flow", url: "https://accounts.example.test/synthetic"})
      compare(shellPlatform.opened, ["https://accounts.example.test/synthetic"])
      compare(owner.item.nativeFlow, "live-flow")
    }
    function test_live_token_request_still_completes() {
      owner.item.postTokenRequest("", function(result) { verify(result.ok); fixture.callbackCount++ })
      answer(requests().slice(-1)[0], {access_token: "synthetic-token", expires_in: 3600})
      compare(fixture.callbackCount, 1)
    }
  }
}

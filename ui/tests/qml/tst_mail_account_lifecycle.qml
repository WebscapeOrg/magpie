import QtQuick
import QtTest
import "../../account" as Accounts
import "../../backend" as BackendModule

Item {
  Component {
    id: backendFactory
    BackendModule.Backend {
      executable: "/synthetic/runtime/bin/omamail"
      expectedVersion: "0.0.0"
      expectedApiVersion: 6
      launchEnabled: false
    }
  }
  Component {
    id: accountFactory
    Accounts.MailAccount {
      pluginDir: "/synthetic/plugin"
      accountId: "synthetic@example.test"
      configuredEmail: "synthetic@example.test"
    }
  }
  TestCase {
    name: "MailAccountLifetime"
    when: windowShown
    function test_destroyed_account_drops_send_queue_completion() {
      failOnWarning(/TypeError|invalid context/)
      var backend = createTemporaryObject(backendFactory, parent)
      backend.launchEnabled = true
      wait(0)
      backend.connected = true
      backend.protocolInfo = {apiVersion: 6, protocol: 1, version: "0.0.0"}
      var account = accountFactory.createObject(parent, {backend: backend})
      verify(account !== null)
      var delivered = []
      function request() {
        verify(account.sendQueue.request("outbox.snapshot", {}, function(result, error) {
          delivered.push(result.marker)
        }))
        return "qml-" + backend.sequence
      }
      var liveId = request()
      backend.receive(JSON.stringify({jsonrpc: "2.0", id: liveId, result: {marker: "live"}}))
      compare(delivered, ["live"], "a live owner receives its completion")
      var lateId = request()
      account.destroy()
      wait(0)
      verify(!Qt.isQtObject(account), "the mailbox QObject must actually be destroyed")
      backend.receive(JSON.stringify({jsonrpc: "2.0", id: lateId, result: {marker: "late"}}))
      compare(delivered, ["live"], "a destroyed owner must not receive its late completion")
    }
    function test_destroyed_account_cancels_conversation_completion() {
      failOnWarning(/TypeError|invalid context/)
      var backend = createTemporaryObject(backendFactory, parent)
      backend.launchEnabled = true
      wait(0)
      backend.connected = true
      backend.protocolInfo = {apiVersion: 6, protocol: 1, version: "0.0.0"}
      var account = accountFactory.createObject(parent, {backend: backend})
      verify(account !== null)
      account.queueConversation("project", null, null, null)
      var request = null
      for (var id in backend.pending) {
        if (backend.pending[id].operation === "account.conversation") request = backend.pending[id]
      }
      verify(request !== null)
      compare(account.conversationBusy, true)
      account.queueConversation("merge", null, {late: {id: "late"}}, null)
      var before = backend.sequence
      account.destroy()
      wait(0)
      verify(!Qt.isQtObject(account), "the mailbox QObject must actually be destroyed")
      compare(request.cancelled, true, "owner destruction must cancel its retained RPC callback")
      backend.receive(JSON.stringify({jsonrpc: "2.0", id: request.id,
        result: {summaries: {late: {id: "late"}}, thread: {}, showsRail: false}}))
      wait(0)
      compare(backend.sequence, before, "late completion must not pump another conversation request")
      verify(!Object.prototype.hasOwnProperty.call(backend.pending, request.id))
    }
  }
}

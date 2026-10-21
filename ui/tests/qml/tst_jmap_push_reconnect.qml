import QtQuick 2.15
import QtTest 1.3
import "../../providers" as Providers

// Socket reconnect timing belongs to Rust's stream runtime tests. This test
// exercises the UI lifetime boundary: stale opens/polls cannot restore a stopped
// account, and a rejected credential stops the stream without a retry loop.
Item {
  Component {
    id: fixture
    Item {
      property alias push: push
      property alias calls: backend.calls
      property alias auth: auth
      QtObject {
        id: backend
        property bool ready: true
        property var calls: []
        function call(method, params, callback) {
          calls = calls.concat([{method:method, params:params, callback:callback}])
        }
      }
      QtObject {
        id: auth
        property bool loggedIn: false
        property string accountId: "jmap:ada@example.org"
        function withCredentials(callback) {
          callback({scheme:"basic", username:"ada", secret:"synthetic-secret"}, "")
        }
      }
      QtObject {
        id: client
        property var backend: backend
        property var auth: auth
        property bool credentialsRejected: false
        property string accountId: "t"
        property var knownStates: ({})
        property var session: ({eventSourceUrl:"https://example.org/events?types={types}&ping={ping}"})
        function ensureSession(callback) { callback(session, "") }
        function nativeRequest(method, params, callback) {
          var handle={aborted:false,requestId:"request-"+backend.calls.length}
          backend.call(method, {accountId:auth.accountId,streamId:params.streamId}, function(result,error) {
            if (!handle.aborted) callback(result,error)
          })
          return handle
        }
        function abortRequest(handle) {
          handle.aborted=true
          backend.call("jmap.cancel",{requestId:handle.requestId},function(){})
        }
      }
      Providers.JmapPush { id: push; client: client }
    }
  }
  TestCase {
    name: "JmapPushBackendLifetime"
    when: windowShown
    function test_stale_open_is_closed_without_starting_poll() {
      var scenario = createTemporaryObject(fixture, this)
      scenario.auth.loggedIn = true
      compare(scenario.calls.length, 1)
      compare(scenario.calls[0].method, "jmap.watch")
      compare(scenario.calls[0].params.accountId, "jmap:ada@example.org")
      compare(scenario.calls[0].params.credential, undefined)
      scenario.auth.loggedIn = false
      scenario.calls[0].callback({opened:true}, "")
      compare(scenario.calls.length, 3)
      compare(scenario.calls[1].method, "jmap.cancel")
      compare(scenario.calls[2].method, "jmap.stream.close")
      compare(scenario.calls[2].params.streamId, scenario.calls[0].params.streamId)
      compare(scenario.push.streamId, "")
    }
    function test_poll_stops_when_account_logs_out_and_stale_reply_is_ignored() {
      var scenario = createTemporaryObject(fixture, this)
      scenario.auth.loggedIn = true
      scenario.calls[0].callback({opened:true}, "")
      compare(scenario.calls[1].method, "jmap.stream.poll")
      var id = scenario.calls[1].params.streamId
      scenario.auth.loggedIn = false
      compare(scenario.calls[2].method, "jmap.stream.close")
      compare(scenario.calls[2].params.streamId, id)
      scenario.calls[1].callback({events:[{kind:"connected"}], closed:false}, "")
      wait(0)
      compare(scenario.calls.length, 3)
      compare(scenario.push.streamId, "")
    }
    function test_rejected_credential_closes_without_reopening() {
      var scenario = createTemporaryObject(fixture, this)
      var rejected = 0
      scenario.push.secretRejected.connect(function() { rejected++ })
      scenario.auth.loggedIn = true
      scenario.calls[0].callback({opened:true}, "")
      scenario.calls[1].callback({events:[{kind:"rejected"}], closed:false}, "")
      compare(rejected, 1)
      compare(scenario.calls[2].method, "jmap.stream.close")
      wait(0)
      compare(scenario.calls.length, 3)
    }
    function test_poll_delivery_continues_on_same_stream() {
      var scenario = createTemporaryObject(fixture, this)
      var changes = 0
      scenario.push.remoteChanged.connect(function() { changes++ })
      scenario.auth.loggedIn = true
      scenario.calls[0].callback({opened:true}, "")
      scenario.calls[1].callback({events:[{kind:"connected"}], closed:false}, "")
      compare(changes, 1)
      tryVerify(function() { return scenario.calls.length === 3 })
      compare(scenario.calls[2].method, "jmap.stream.poll")
      compare(scenario.calls[2].params.streamId, scenario.calls[1].params.streamId)
    }
  }
}

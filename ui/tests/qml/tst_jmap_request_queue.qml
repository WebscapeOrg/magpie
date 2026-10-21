import QtQuick
import QtTest
import "../../providers" as Providers
import "transports.js" as Transports

Item {
  Component {
    id: fixture
    Item {
      property alias api: client
      QtObject {
        id: auth
        property string accountId: "jmap:ada@example.org"
        property bool loggedIn: false
        property var settings: ({sessionUrl:"https://example.org/session",username:"ada"})
        signal verifyRequested(var settings, string address, string secret)
        signal loggedOut()
      }
      Providers.JmapClient { id: client; auth: auth }
    }
  }
  TestCase {
    when: windowShown
    function setup() {
      var scenario = createTemporaryObject(fixture, this)
      Transports.install(scenario.api)
      return scenario
    }
    name: "JmapNativeRequestLifetime"
    function test_abandoned_requests_cancel_by_id_and_late_reply_cannot_apply_state() {
      var scenario = setup()
      var called = 0
      for (var itemIndex = 0; itemIndex < 4; itemIndex++) {
        var before = Transports.transports(scenario.api)
        var handle = scenario.api.getMessage("m" + itemIndex, true, function() { called++ })
        var request = Transports.newSince(scenario.api, before)[0]
        compare(request.method, "jmap.read")
        compare(request.params.accountId, "jmap:ada@example.org")
        compare(request.params.credential, undefined)
        compare(scenario.api.inFlight, 1)
        scenario.api.abortRequest(handle)
        var cancel = scenario.api.backend.testCalls.slice(-1)[0]
        compare(cancel.method, "jmap.cancel")
        compare(cancel.params.requestId, request.params.requestId)
        scenario.api.abortRequest(handle)
        compare(scenario.api.backend.testCalls.slice(-1)[0], cancel)
        Transports.complete(request, {id:"m" + itemIndex}, {session:{state:"stale"},mailboxes:[]})
        compare(scenario.api.inFlight, 0)
        compare(called, 0)
        compare(scenario.api.session, null)
      }
      var before = Transports.transports(scenario.api)
      scenario.api.getMessage("next", true, function(result,error) { compare(error, ""); called++ })
      Transports.complete(Transports.newSince(scenario.api,before)[0], {id:"next"})
      compare(called, 1)
      compare(scenario.api.inFlight, 0)
    }
    function test_server_change_ignores_pending_result_and_completes_busy_accounting() {
      var scenario = setup()
      var called = false
      scenario.api.getLabels(function() { called = true })
      var request = Transports.transports(scenario.api)[0]
      scenario.api.forgetServer()
      Transports.complete(request, [], {session:{state:"old"},mailboxes:[{id:"old"}]})
      compare(called, false)
      compare(scenario.api.session, null)
      compare(scenario.api.mailboxList.length, 0)
      compare(scenario.api.inFlight, 0)
    }
    function test_attachment_callback_receives_the_base64_string_not_the_wire_object() {
      var scenario = setup()
      var got = []
      var before = Transports.transports(scenario.api)
      scenario.api.getAttachment("m1", "blob1", function(data, error) { got.push([data, error]) })
      var request = Transports.newSince(scenario.api, before)[0]
      compare(request.method, "jmap.attachment")
      Transports.complete(request, {data: "aGk", size: 2})
      compare(got.length, 1)
      compare(got[0][0], "aGk")
      compare(got[0][1], "")

      before = Transports.transports(scenario.api)
      scenario.api.getAttachment("m1", "blob2", function(data, error) { got.push([data, error]) })
      Transports.reply(Transports.newSince(scenario.api, before)[0], null, {message: "attachment_data_invalid"})
      compare(got.length, 2)
      compare(got[1][0], "")
      verify(got[1][1] !== "")
    }
  }
}

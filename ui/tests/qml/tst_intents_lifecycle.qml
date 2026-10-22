import QtQuick
import QtTest
import "../../account" as Account
import "../../backend" as Backend

Item {
  id: fixture
  property var completions: []
  Backend.Backend {
    id: transport
    executable: "/synthetic/omamail"
    expectedVersion: "0.11.0"
    expectedApiVersion: 7
  }
  QtObject {
    id: mailbox
    property var backend: transport
    property string accountId: "synthetic@example.test"
    property string selectedId: "message"
    property var selectedMessage: ({id: "message"})
    property string cacheKey: "inbox"
    property int actionPreparations: 0
    property string pendingAction: ""
    property string pendingActionQuery: ""
    property var queuedActions: []
    function intentView() { return {selectedId: selectedId, selectedMessage: selectedMessage} }
    function fail(error) { fixture.completions.push(error) }
  }
  Component { id: intentFactory; Account.Intents { account: mailbox } }
  Loader { id: owner; active: false; sourceComponent: intentFactory }
  TestCase {
    name: "IntentLifetime"
    property var pipe
    function requests() { return pipe.written.trim().split("\n").map(function(line) { return JSON.parse(line) }) }
    function answer(request, result) {
      transport.receive(JSON.stringify({jsonrpc: "2.0", id: request.id, result: result}))
    }
    function initTestCase() {
      pipe = transport.children.filter(function(child) { return child.command && child.command[1] === "serve" })[0]
      verify(pipe)
      pipe.started()
      answer(requests()[0], {protocol: 1, version: "0.11.0", apiVersion: 7, methods: ["model.intent"]})
      verify(transport.ready)
    }
    function init() {
      fixture.completions = []
      owner.active = true
      verify(owner.item)
      owner.item.generation = 1
    }
    function cleanup() { owner.active = false; wait(0) }
    function test_surviving_owner_receives_the_response() {
      failOnWarning(/.?/)
      owner.item.settle(mailbox.accountId, "inbox", 1, [],
        function(result, error) { fixture.completions.push(result) }, 1)
      answer(requests().slice(-1)[0], {settled: true})
      compare(fixture.completions, [{settled: true}])
      compare(owner.item.running, false)
      compare(owner.item.pendingRequest, null)
    }
    function test_removal_with_pending_request_data() {
      return [{tag: "begin", operation: "begin"}, {tag: "settle", operation: "settle"},
        {tag: "coalesce", operation: "coalesce"}, {tag: "reset", operation: "reset"},
        {tag: "clear", operation: "clear"}]
    }
    function test_removal_with_pending_request(data) {
      failOnWarning(/.?/)
      if (data.operation === "reset") owner.item.generation = -1
      if (data.operation === "begin" || data.operation === "reset") owner.item.begin({accountId: mailbox.accountId, query: "inbox"},
        function(result, error) { fixture.completions.push(error) })
      else if (data.operation === "settle") owner.item.settle(mailbox.accountId, "inbox", 1, [],
        function(result, error) { fixture.completions.push(error) }, 1)
      else if (data.operation === "clear") owner.item.clear()
      else owner.item.coalesce(mailbox.accountId, "inbox", 1, 2, 1)
      var request = requests().slice(-1)[0]
      compare(request.params.operation, data.operation)
      owner.active = false
      wait(0)
      answer(request, {generation: 1})
      compare(fixture.completions, [])
    }
  }
}

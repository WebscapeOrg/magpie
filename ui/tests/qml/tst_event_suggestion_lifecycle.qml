import QtQuick
import QtTest
import "../../agent" as Agent

Item {
  Component {
    id: fixture
    Item {
      id: host
      property alias suggester: suggestions
      property alias service: service
      property alias runner: runner
      property alias backend: backend
      QtObject {
        id: backend
        property bool ready: true
        property var contexts: []
        function call(method, parameters, callback) {
          if (method !== "agent.context") { callback({}, null); return }
          contexts = contexts.concat([{parameters: parameters, callback: callback,
            startedMessages: runner.starts.map(function(payload) { return payload.messageId })}])
        }
        function complete(index) {
          var context = contexts[index]
          context.callback({payload: {accountId: context.parameters.accountId,
            messageId: context.parameters.ids[0]}}, null)
        }
      }
      QtObject {
        id: service
        property var backend: backend
        property bool suggestEvents: true
        property bool hasAgent: true
        property bool agentAvailable: true
        property bool backendCanSuggestEvents: true
        property var reading: null
        property var calendarController: null
        property var accounts: ({ada: {accountId: "ada"}, bob: {accountId: "bob"}})
        function findAccount(accountId) { return accounts[accountId] || null }
      }
      QtObject {
        id: runner
        property bool starting: false
        property int activeEventLooks: 0
        property var eventLooks: ({})
        property string selectedAgent: "Claude"
        property string selectedModel: ""
        property var starts: []
        signal startRefused(string code)
        function selection() { return {agent: selectedAgent, model: selectedModel} }
        function start(payload, quiet, selected) {
          if (starting) return false
          starts = starts.concat([payload])
          return true
        }
      }
      Agent.EventSuggester { id: suggestions; service: service; runner: runner }
    }
  }
  TestCase {
    name: "EventSuggestionLifecycle"
    when: windowShown
    property var host
    function init() { host = createTemporaryObject(fixture, parent); verify(host !== null) }
    function look(account, message) {
      return {key: account + " " + message, accountId: account, id: message,
        summary: {id: message}, folder: "INBOX"}
    }
    function test_disabled_setting_blocks_prepared_context() {
      verify(host.suggester.tryStart(look("ada", "message")))
      compare(host.backend.contexts.length, 1)
      host.service.suggestEvents = false
      host.backend.complete(0)
      compare(host.runner.starts.length, 0, "Disabling suggestions must prevent a prepared request from starting AI")
    }
    function test_disabled_setting_discards_waiting_contexts() {
      host.runner.starting = true
      verify(!host.suggester.tryStart(look("ada", "message")))
      host.service.suggestEvents = false
      host.runner.starting = false
      compare(host.backend.contexts.length, 0, "Disabled suggestions must not read queued messages")
    }
    function test_removed_account_blocks_prepared_context() {
      verify(host.suggester.tryStart(look("ada", "message")))
      host.service.accounts = ({bob: {accountId: "bob"}})
      host.backend.complete(0)
      compare(host.runner.starts.length, 0, "Removed accounts must not launch prepared AI work")
    }
    function test_completion_starts_current_job_before_draining_next() {
      verify(host.suggester.tryStart(look("ada", "first")))
      verify(!host.suggester.tryStart(look("ada", "second")))
      host.backend.complete(0)
      compare(host.runner.starts.length, 1)
      compare(host.runner.starts[0].messageId, "first")
      compare(host.backend.contexts.length, 2)
      compare(host.backend.contexts[1].startedMessages.length, 1,
        "The first job must start before another context read can complete reentrantly")
      host.backend.complete(1)
      compare(host.runner.starts.length, 2)
      compare(host.runner.starts[1].messageId, "second")
    }
  }
}

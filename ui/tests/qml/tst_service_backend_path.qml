import QtQuick
import QtTest
import "../.." as Omamail

Item {
  Component {
    id: factory
    Omamail.Service {}
  }
  TestCase {
    name: "ServiceBackendPath"
    function test_calendar_requirements_are_fixed_across_releases() {
      var service = createTemporaryObject(factory, parent)
      verify(service !== null)
      var backend = service.backend
      backend.expectedApiVersion = 7
      backend.latestApiVersion = 8
      backend.launchEnabled = true
      backend.connected = true
      backend.protocolInfo = ({ apiVersion: 4 })
      compare(service.backendCanDiscoverCalendars, false)
      compare(service.backendCanGoogleCalendars, false)
      backend.protocolInfo = ({ apiVersion: 5 })
      compare(service.backendCanDiscoverCalendars, true)
      compare(service.backendCanGoogleCalendars, false)
      backend.protocolInfo = ({ apiVersion: 6 })
      compare(service.backendCanDiscoverCalendars, true)
      compare(service.backendCanGoogleCalendars, true)
      backend.protocolInfo = ({ apiVersion: 8 })
      compare(service.backendCanGoogleCalendars, true)
      backend.connected = false
      compare(service.backendCanDiscoverCalendars, false)
      compare(service.backendCanGoogleCalendars, false)
    }
    function test_calendar_requests_obey_the_connected_api() {
      var service = createTemporaryObject(factory, parent)
      verify(service !== null)
      var backend = service.backend
      backend.expectedApiVersion = 7
      backend.latestApiVersion = 8
      backend.launchEnabled = true
      backend.connected = true
      backend.protocolInfo = ({ apiVersion: 5 })
      var controller = service.calendarController
      var initialRequests = Object.keys(backend.pending).length
      var source = {kind: "google", calendarId: "shared@example.org"}
      var operations = ["list", "create", "update", "delete"]
      var refused = 0
      for (var operationIndex = 0; operationIndex < operations.length; operationIndex++) {
        controller.nativeRequest(source, operations[operationIndex], {}, function(result, error) {
          compare(result, null)
          compare(error, "Update the backend to access Google calendars")
          refused++
        })
      }
      compare(refused, 4)
      compare(Object.keys(backend.pending).length, initialRequests)
      controller.nativeRequest({kind: "google", calendarId: ""}, "list", {}, function() {})
      compare(Object.keys(backend.pending).length, initialRequests + 1,
        "the historical Google primary calendar still works on API 5")
      backend.protocolInfo = ({ apiVersion: 6 })
      var supportedRequests = Object.keys(backend.pending).length
      for (var action = 0; action < operations.length; action++)
        controller.nativeRequest(source, operations[action], {}, function() {})
      compare(Object.keys(backend.pending).length, supportedRequests + 4)
    }
    function test_resolved_runtime_path_starts_backend() {
      var service = createTemporaryObject(factory, parent)
      verify(service !== null)
      var runtime = service.backendRuntime
      var resolved = "/synthetic/real-checkout/runtime/bin/omamail"
      verify(resolved !== service.pluginDir + "/runtime/bin/omamail")
      runtime.applyResult({ state: "ready", requiredVersion: "0.8.2", requiredApiVersion: 1,
        installedVersion: "0.8.2", executable: resolved, error: "" }, 0)
      tryCompare(service.backend, "launchEnabled", true)
      compare(service.backend.executable, resolved)
      var process = null
      for (var childIndex = 0; childIndex < service.backend.children.length; childIndex++) {
        var child = service.backend.children[childIndex]
        if (child.command) process = child
      }
      verify(process !== null)
      tryCompare(process, "running", true)
      process.started()
      var request = JSON.parse(process.written.trim())
      process.stdout.read(JSON.stringify({jsonrpc: "2.0", id: request.id,
        result: {name: "omamail", version: "0.8.2", apiVersion: 1, protocol: 1,
                 methods: ["system.info", "system.quit"]}}))
      tryCompare(service.backend, "ready", true)
    }
  }
}

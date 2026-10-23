import QtQuick
import QtTest
import "../.." as Omamail
import "BackendFixture.js" as BackendFixture

Item {
  id: root

  Omamail.Service {
    id: pluginService
    manifest: ({id:"omamail",name:"Omamail",version:"0.10.1"})
  }

  QtObject {
    id: standaloneHost
    property bool standalone: true
    property string backendPath: "/synthetic/omamail"
    property var capabilities: ({agent:false,tray:false,mailto:false,notifications:false})
  }

  Component {
    id: standaloneFactory
    Omamail.Service {
      manifest: ({id:"omamail",name:"Omamail",version:"0.10.1"})
      platform: standaloneHost
    }
  }

  TestCase {
    name: "CredentialCompatibility"

    function processNamed(owner, name) {
      var process = findChild(owner, name)
      verify(process, "missing " + name)
      return process
    }

    function test_pinned_api_three_plugin_uses_the_fixed_keyring_adapter() {
      BackendFixture.markReady(pluginService, 3)
      compare(pluginService.backendCanStoreCredentials, false)
      compare(pluginService.legacyCredentialCompatibility, true)
      compare(pluginService.canAccessCredentials, true)

      var read = ""
      verify(pluginService.credentialGet("google-refresh-token", "one@example.org", "synthetic-client",
        function(value, error) { read = value + "|" + error }))
      var lookup = processNamed(pluginService, "legacy-credential-get")
      compare(lookup.command, ["secret-tool", "lookup", "service", "omamail", "kind", "refresh-token", "client-id",
        "synthetic-client", "account", "one@example.org", "grant", "calendar-events-v1"])
      lookup.stdout.text = "quotes '\" and Unicode 你好\n"
      lookup.exited(0)
      compare(read, "quotes '\" and Unicode 你好|")

      var stored = false
      verify(pluginService.credentialPut("google-refresh-token", "one@example.org", "synthetic-client", "$(not shell)",
        function(ok) { stored = ok }))
      var writer = processNamed(pluginService, "legacy-credential-put")
      compare(writer.command, [pluginService.pluginDir + "/scripts/keyring-store.sh",
        "service", "omamail", "kind", "refresh-token", "client-id", "synthetic-client",
        "account", "one@example.org", "grant", "calendar-events-v1"])
      verify(writer.command.indexOf("$(not shell)") < 0)
      writer.started()
      compare(writer.written, "$(not shell)\n")
      writer.exited(0)
      compare(stored, true)
    }

    function test_plugin_fallback_rejects_controls_before_process_creation() {
      BackendFixture.markReady(pluginService, 3)
      var called = ""
      verify(!pluginService.credentialPut("google-refresh-token", "one@example.org\n", "synthetic-client",
        "secret", function(ok, error) { called = ok + "|" + error }))
      compare(called, "false|invalid_params")
      compare(findChild(pluginService, "legacy-credential-put"), null)
      verify(!pluginService.credentialPut("google-refresh-token", "one@example.org", "synthetic-client",
        "line one\nline two", function(ok, error) { called = ok + "|" + error }))
      compare(called, "false|invalid_params")
      compare(findChild(pluginService, "legacy-credential-put"), null)
    }

    function test_api_four_uses_typed_rpc_without_a_keyring_process() {
      var listener = BackendFixture.markReady(pluginService, 4)
      listener.answers["credentials.get"] = ({found:true,secret:"native secret"})
      var answer = ""
      verify(pluginService.credentialGet("google-refresh-token", "one@example.org", "synthetic-client",
        function(value, error) { answer = value + "|" + error }))
      tryVerify(function() { return answer !== "" })
      compare(answer, "native secret|")
      var found = null
      for (var index = 0; index < listener.requests.length; index++)
        if (listener.requests[index].method === "credentials.get") found = listener.requests[index]
      verify(found)
      compare(found.params, {kind:"google-refresh-token",accountId:"one@example.org",clientId:"synthetic-client"})
      compare(findChild(pluginService, "legacy-credential-get"), null)
    }

    function test_api_three_standalone_refuses_the_plugin_compatibility_process() {
      var service = createTemporaryObject(standaloneFactory, root)
      verify(service)
      BackendFixture.markReady(service, 3)
      compare(service.legacyCredentialCompatibility, false)
      compare(service.canAccessCredentials, false)
      var answer = ""
      verify(!service.credentialGet("google-refresh-token", "one@example.org", "synthetic-client",
        function(value, error) { answer = value + "|" + error }))
      compare(answer, "|backend_needs_update")
      compare(findChild(service, "legacy-credential-get"), null)
      wait(10)
    }
  }
}

import QtQuick
import QtTest
import "../../account" as Accounts
import "../../backend" as BackendModule

// Invariant: API 7 aligns composer sender names with agent sends; server-named identities keep their server name.
Item {
  Component {
    id: backendFactory
    BackendModule.Backend {
      executable: "/synthetic/runtime/bin/omamail"
      expectedVersion: "0.8.2"
      expectedApiVersion: 7
      latestApiVersion: 8
      launchEnabled: false
    }
  }
  Component {
    id: accountFactory
    Accounts.MailAccount {
      pluginDir: "/synthetic/plugin"
      configuredEmail: "ada@example.org"
      active: false
      windowOpen: false
    }
  }
  TestCase {
    name: "ComposerSenderName"

    function connected(apiVersion) {
      var backend = createTemporaryObject(backendFactory, parent)
      backend.launchEnabled = true
      backend.connected = true
      backend.protocolInfo = ({ apiVersion: apiVersion })
      return backend
    }

    function primary(account) {
      var rows = account.availableSendAsAliases
      for (var index = 0; index < rows.length; index++) if (rows[index].isPrimary) return rows[index]
      return null
    }

    function test_a_server_named_mailbox_keeps_its_own_name() {
      var account = createTemporaryObject(accountFactory, parent,
        { backend: connected(7) })
      account.profile = ({ email: "ada@example.org" })
      compare(account.availableSendAsAliases.length, 1)
      compare(account.availableSendAsAliases[0].displayName, "")
      account.sendAsAliases = [{email:"ada@example.org",displayName:"Ada from Gmail",isPrimary:true,isDefault:true}]
      compare(account.availableSendAsAliases[0].displayName, "Ada from Gmail")
    }
  }
}

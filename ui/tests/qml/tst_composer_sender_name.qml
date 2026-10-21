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
      senderName: "Ada Lovelace"
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

    function test_imap_and_outlook_name_the_primary_address_from_api_7() {
      var providers = ["imap", "outlook"]
      for (var index = 0; index < providers.length; index++) {
        var backend = connected(6)
        var account = createTemporaryObject(accountFactory, parent,
          { backend: backend, providerId: providers[index] })
        account.profile = ({ email: "ada@example.org" })
        compare(backend.ready, true)
        compare(primary(account).displayName, "",
          providers[index] + ": API 6 cannot name agent sends, so the composer does not either")
        backend.protocolInfo = ({ apiVersion: 7 })
        compare(primary(account).displayName, "Ada Lovelace", providers[index])
        backend.latestApiVersion = 8
        backend.protocolInfo = ({ apiVersion: 8 })
        compare(primary(account).displayName, "Ada Lovelace", providers[index] + ": a later API keeps it")
        backend.connected = false
        compare(primary(account).displayName, "", providers[index] + ": nothing is promised offline")
      }
    }

    function test_a_server_named_mailbox_keeps_its_own_name() {
      var account = createTemporaryObject(accountFactory, parent,
        { backend: connected(7), providerId: "gmail" })
      account.profile = ({ email: "ada@example.org" })
      compare(account.availableSendAsAliases.length, 1)
      compare(account.availableSendAsAliases[0].displayName, "")
    }
  }
}

import QtQuick 2.15
import QtTest 1.3
import "transports.js" as Transports
import "NativeIntentFixture.js" as NativeIntentFixture
import "../../account" as Account

// Invariant: A push arriving during an optimistic mutation waits for that mutation,
// then starts the deferred refresh even if the mutation failed. RPC replies are controlled.
Item {
  width: 400
  height: 300

  Account.MailAccount {
    id: account

    pluginDir: "/tmp/omamail-test"
    accountId: "jmap:ada@example.org"
    configuredEmail: "ada@example.org"
    providerId: "jmap"
    jmapSettings: ({
      sessionUrl: "https://mail.example.org/jmap/session",
      username: "ada@example.org",
      authScheme: "basic",
      accountId: "t"
    })
    active: true
    windowOpen: true
  }

  TestCase {
    name: "JmapPushAction"
    function initTestCase() { account.backend = NativeIntentFixture.backend(account) }
    function settleNative() {
      wait(1)
      tryVerify(function() {return account.backend.pending.length === 0})
    }

    when: windowShown

    // A session with no `eventSourceUrl`, so the push owner has nowhere to
    // connect and starts no stream of its own. This test is about what a plan
    // does once it arrives, not about how it got here — and a stream would put
    // a second process among the ones counted below.
    readonly property var session: ({
      capabilities: {
        "urn:ietf:params:jmap:core": {},
        "urn:ietf:params:jmap:mail": {}
      },
      accounts: {
        t: {
          name: "ada@example.org",
          isPersonal: true,
          isReadOnly: false,
          accountCapabilities: {
            "urn:ietf:params:jmap:mail": {
              emailQuerySortOptions: ["receivedAt"]
            }
          }
        }
      },
      primaryAccounts: {
        "urn:ietf:params:jmap:core": "t",
        "urn:ietf:params:jmap:mail": "t"
      },
      apiUrl: "https://api.example.org/jmap/",
      state: "s0"
    })

    readonly property var mailboxes: [
      { id: "a", name: "Inbox", role: "inbox", parentId: null,
        totalEmails: 1, unreadEmails: 1 },
      { id: "b", name: "Trash", role: "trash", parentId: null,
        totalEmails: 0, unreadEmails: 0 }
    ]

    function test_push_while_action_pending_defers_and_replays() {
      verify(!!account.auth, "the JMAP account builds its own sign-in object")
      verify(!!account.api, "and its own client")

      // The session and the mailbox list are what every read gates on, and both
      // are normally the answer to a request. Placing them here is what stops
      // the action below from spending its first round trip on them.
      Transports.install(account.api)
      account.api.session = session
      account.api.mailboxList = mailboxes
      account.api.mailboxesLoaded = true
      // The secret is set on the object rather than written anywhere: a test
      // must never put an entry in the keyring, and `secretChecked` is what
      // stops the lookup that would otherwise still be pending.
      account.auth.secret = "app-password"
      account.auth.secretChecked = true

      tryVerify(function() { return account.ready }, 2000,
        "a configured mailbox with a secret in memory is ready")

      wait(1)
      // One row, already on screen and already loaded — so the deferral below
      // is the ordinary one rather than the cleared-view variant.
      account.messages = [{ id: "m1", subject: "One", unread: true,
        labelIds: ["INBOX", "UNREAD"] }]
      account.listLoaded = true
      account.listLoading = false

      var beforeAction = Transports.transports(account.api)
      verify(account.act("m1", "markRead"), "the action was accepted")
      settleNative()
      compare(account.pendingAction, "markRead")
      compare(account.pendingActionQuery, account.cacheKey)
      var actionProcesses = Transports.newSince(account.api, beforeAction)
      compare(actionProcesses.length, 1, "the action is one request in flight")
      var actionProcess = actionProcesses[0]

      // The push. This is exactly what `JmapPush` emits when a `StateChange`
      // names a state the client does not already hold — the object it hands
      // over is `Jmap.refreshPlan`'s answer and nothing else.
      compare(account.deferredListLoad, null, "nothing is deferred yet")
      var beforePush = Transports.transports(account.api)
      account.api.remoteChanged({ mail: true, mailboxes: false })

      verify(!!account.deferredListLoad,
        "a refresh arriving mid-action is deferred, not run over the edit")
      compare(account.deferredListLoad.cacheKey, account.cacheKey,
        "and it is deferred for the query the user is looking at")
      compare(Transports.newSince(account.api, beforePush).length, 0,
        "no list request went out while the action was pending")

      // The action answers with a backend transport failure — the failure path,
      // where the row goes back and the deferred load is replayed all the same.
      var beforeReply = Transports.transports(account.api)
      Transports.fail(actionProcess)
      settleNative()

      compare(account.pendingAction, "", "the action is finished")
      compare(account.deferredListLoad, null, "and the deferred load was taken")
      compare(Transports.newSince(account.api, beforeReply).length, 1,
        "the action's own callback is what put the list request out")
    }
  }
}

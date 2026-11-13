import QtQuick
import QtTest
import "../.." as Omamail
import "../../account/Accounts.js" as Accounts
import "BackendFixture.js" as BackendFixture

Item {
  width: 600
  height: 400
  QtObject {
    id: store
    function updateEntryInline(id, entry) {
    }
  }
  QtObject {
    id: replyRecorder
    property var received: []
    function receive(reply) { received = received.concat([JSON.parse(reply)]) }
  }
  Loader {
    id: replyOwner
    active: false
    sourceComponent: Component { Item { property var backend: replyRecorder } }
  }
  Component {
    id: serviceComponent
    Omamail.Service {
      shell: store
      manifest: ({
          id: "omamail",
          __sourceDir: "/tmp/synthetic"
        })
      property int oauthCalls: 0
      function signIn() {
        oauthCalls++;
      }
    }
  }
  TestCase {
    name: "AccountPersistence"
    when: windowShown
    function test_fixture_reply_requires_a_live_backend() {
      failOnWarning(/.?/)
      replyRecorder.received = []
      replyOwner.active = true
      BackendFixture.respond(replyOwner.item, {id: "live"}, {ok: true})
      tryCompare(replyRecorder, "received", [{jsonrpc: "2.0", id: "live", result: {ok: true}}])
      BackendFixture.respond(replyOwner.item, {id: "removed"}, {ok: true})
      replyOwner.item.backend = null
      replyOwner.active = false
      wait(10)
      compare(replyRecorder.received.length, 1, "a removed owner cannot receive a queued reply")
    }
    function test_fixture_reply_after_owner_destruction_is_ignored() {
      failOnWarning(/.?/)
      replyRecorder.received = []
      replyOwner.active = true
      var removed = replyOwner.item
      replyOwner.active = false
      wait(10)
      verify(!Qt.isQtObject(removed), "the owner was actually destroyed")
      BackendFixture.respond(removed, {id: "destroyed"}, {ok: true})
      wait(10)
      compare(replyRecorder.received.length, 0)
    }
    function create() {
      var service = createTemporaryObject(serviceComponent, parent);
      verify(service !== null);
      BackendFixture.markReady(service);
      var list = Accounts.emptyList();
      list = Accounts.add(list, {
        provider: "gmail",
        email: "alias@example.com"
      });
      list = Accounts.add(list, {
        provider: "gmail",
        email: "other@example.com"
      });
      service.applyAccounts(Accounts.serialize(list));
      compare(service.lastPersistedIds.length, 2);
      return service;
    }
    function latestRequest(service, method) {
      var requests = BackendFixture.install(service).requests
      for (var requestIndex = requests.length - 1; requestIndex >= 0; requestIndex--)
        if (requests[requestIndex].method === method) return requests[requestIndex].id
      return ""
    }
    function finishWrite(service) {
      var id = latestRequest(service, "accounts.save")
      verify(id !== "")
      service.backend.receive(JSON.stringify({jsonrpc:"2.0",id:id,result:{revision:"synthetic-revision"}}))
    }
    function test_native_registry_event_reloads_and_coalesces_inflight_read() {
      var service = create()
      var first = latestRequest(service, "accounts.read")
      verify(first !== "")
      var revision = new Array(65).join("a")
      service.backend.receive(JSON.stringify({jsonrpc:"2.0",method:"accounts.changed",params:{revision:revision}}))
      compare(service.accountsReloadQueued, true)
      service.backend.receive(JSON.stringify({jsonrpc:"2.0",id:first,result:{registry:service.accountList,revision:new Array(65).join("b")}}))
      var next = latestRequest(service, "accounts.read")
      verify(next !== first)
      var changed = Accounts.setLabel(service.accountList,"alias@example.com","Native change")
      service.backend.receive(JSON.stringify({jsonrpc:"2.0",id:next,result:{registry:changed,revision:revision}}))
      compare(service.accountsRevision, revision)
      compare(service.accountList.accounts[0].label, "Native change")
      compare(service.accountsReading, false)
    }
    function test_queued_profile_correction_is_saved_after_the_old_write() {
      var service = create();
      service.saveAccounts();
      service.nameAccount(0, "canonical@example.com");
      compare(service.accountsSaveQueued, true);
      finishWrite(service);
      verify(service.accountsWritePayload.indexOf("canonical@example.com") >= 0);
      verify(service.accountsWritePayload.indexOf("other@example.com") >= 0);
    }
    function test_profile_duplicate_releases_only_its_redundant_row() {
      var service = create();
      service.nameAccount(0, "other@example.com");
      compare(service.accountList.accounts.length, 1);
      compare(Accounts.load(service.accountsWritePayload).accounts[0].email, "other@example.com");
    }
    function test_first_profile_name_keeps_existing_accounts() {
      var service = create();
      service.accountList = Accounts.add(service.accountList, {
        provider: "gmail",
        email: "",
        pending: true
      });
      service.nameAccount(2, "new@example.com");
      compare(Accounts.load(service.accountsWritePayload).accounts.length, 3);
    }
    function test_invalid_profile_name_changes_nothing() {
      var service = create();
      var before = Accounts.serialize(service.accountList);
      service.nameAccount(0, "");
      compare(Accounts.serialize(service.accountList), before);
      compare(service.lastPersistedIds, ["alias@example.com", "other@example.com"]);
      compare(service.accountsWritePayload, "");
    }
    function test_correction_does_not_authorize_an_unrelated_drop() {
      var service = create();
      service.nameAccount(0, "canonical@example.com");
      finishWrite(service);
      service.accountList = Accounts.remove(service.accountList, "other@example.com");
      service.saveAccounts();
      compare(service.accountsWriting, false, "unrelated omission must not start a writer");
      compare(service.accountsWritePayload, "");
    }
    function test_provider_identity_change_can_be_saved() {
      var service = create();
      service.nameAccount(0, "canonical@example.com");
      compare(service.accountList.accounts[0].email, "canonical@example.com");
      verify(service.accountsWritePayload.indexOf("canonical@example.com") >= 0, "profile identity must reach writer");
      finishWrite(service);
      service.setAccountLabel("canonical@example.com", "Personal");
      verify(service.accountsWritePayload.indexOf("Personal") >= 0, "later settings remain writable");
    }
    function accountRequests(service, methods) {
      return BackendFixture.install(service).requests.filter(function(request) {
        return methods.indexOf(request.method) >= 0
      }).length
    }
    function test_unsupported_registry_preserves_saved_accounts_and_refuses_changes() {
      var service = create()
      var before = Accounts.serialize(service.accountList)
      var protectedMethods = ["accounts.save", "credentials.get", "credentials.put", "credentials.delete", "auth.begin"]
      var calls = accountRequests(service, protectedMethods)
      service.applyAccounts(JSON.stringify({version: 1, activeId: "other@example.com", accounts: [
        {email: "other@example.com", provider: "imap", imap: {username: "other@example.com"}}
      ]}))
      verify(service.accountRegistryError !== "")
      compare(Accounts.serialize(service.accountList), before)
      service.applyAccounts("invalid")
      verify(service.accountRegistryError !== "", "a later read failure cannot clear the incompatible registry guard")
      service.saveAccounts({allowDrop: true})
      service.addAccount()
      compare(service.configureAccount(0, {email: "replacement@example.com"}), false)
      wait(0)
      compare(Accounts.serialize(service.accountList), before)
      compare(accountRequests(service, protectedMethods), calls, "rejected configuration cannot read/write credentials or save accounts")
    }
    function test_initial_unsupported_read_does_not_create_a_setup_placeholder() {
      var service = createTemporaryObject(serviceComponent, parent)
      verify(service !== null)
      BackendFixture.markReady(service)
      var request = latestRequest(service, "accounts.read")
      verify(request !== "")
      var before = Accounts.serialize(service.accountList)
      service.backend.receive(JSON.stringify({jsonrpc:"2.0", id:request, error:{code:-32000,message:"accounts_provider_unsupported"}}))
      verify(service.accountRegistryError !== "")
      compare(Accounts.serialize(service.accountList), before)
      compare(service.accountList.accounts.length, 0)
      service.addAccount()
      service.saveAccounts({allowDrop:true})
      compare(accountRequests(service, ["accounts.save", "credentials.get", "credentials.put", "credentials.delete", "auth.begin"]), 0)
    }
    function test_collision_does_not_dispatch_oauth() {
      var service = create();
      var before = Accounts.serialize(service.accountList);
      compare(service.configureCurrentAccountAndSignInOAuth({
        email: "other@example.com"
      }), false);
      wait(0);
      compare(service.oauthCalls, 0);
      compare(service.accountsWritePayload, "");
      compare(Accounts.serialize(service.accountList), before);
    }
  }
}

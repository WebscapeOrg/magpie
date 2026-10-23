import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail
import "BackendFixture.js" as BackendFixture
import "../../account/Accounts.js" as Accounts

// Invariant: Which mailbox the setup page is actually working on.
//
// `activeId` names the mailbox on screen; `activeIndex` overrides it for a row
// that has no id yet, because a draft cannot be named. Add account leaves both
// set — the draft at `activeIndex`, the previous mailbox still at `activeId` —
// and every reader has to agree on which one wins. Remove account did not: it
// asked `indexOfActiveAccount()` alone, so on the page of a freshly added
// mailbox it named the mailbox that was there before, and confirming deleted a
// working account while the page in front of the user showed an empty form.
//
// The list is assigned rather than fed through `applyAccounts`, so no test
// depends on the file watcher or on the state a previous test left the writer
// in.
Item {
  width: 900
  height: 600

  QtObject {
    id: shellStore
    function updateEntryInline(id, entry) {}
    function hide(id) {}
  }

  Omamail.Service {
    id: mailService
    shell: shellStore
    manifest: ({ id: "omamail", __sourceDir: "/tmp/omamail-test" })
  }

  Omamail.App { id: app; service: mailService }

  TestCase {
    name: "AccountRemoval"
    when: windowShown

    function init() { failOnWarning(/invalid context|TypeError/) }

    function initTestCase() { BackendFixture.markReady(mailService) }

    readonly property string ada: "ada@example.com"
    readonly property string bob: "bob@example.com"
    readonly property string adaId: "ada@example.com"
    readonly property string bobId: "bob@example.com"

    function entry(email) {
      return { email: email, provider: "gmail", clientId: "", clientSecret: "",
        label: "", signature: "" }
    }

    function seed(emails, activeId) {
      var list = Accounts.emptyList()
      for (var itemIndex = 0; itemIndex < emails.length; itemIndex++) list = Accounts.add(list, entry(emails[itemIndex]))
      list = Accounts.setActive(list, activeId)
      mailService.activeIndex = -1
      mailService.accountList = list
      mailService.accountsLoaded = true
      mailService.refreshCurrent()
    }

    function named(item, objectName) {
      if (!item) return null
      if (item.objectName === objectName) return item
      var values = item.children || []
      for (var itemIndex = 0; itemIndex < values.length; itemIndex++) {
        var found = named(values[itemIndex], objectName)
        if (found) return found
      }
      return null
    }

    function dialog() {

      function walk(item) {
        if (!item) return null
        if (item.hasOwnProperty("request") && item.hasOwnProperty("opened")
            && String(item).indexOf("AccountRemovalDialog") === 0) return item
        var children = item.children || []
        for (var itemIndex = 0; itemIndex < children.length; itemIndex++) {
          var found = walk(children[itemIndex])
          if (found) return found
        }
        return null
      }
      return walk(app)
    }

    function emails() {
      var addresses = []
      var values = mailService.accountSummaries || []
      for (var itemIndex = 0; itemIndex < values.length; itemIndex++) addresses.push(values[itemIndex].email)
      return addresses
    }

    function test_remove_on_a_new_mailbox_page_spares_the_mailbox_behind_it() {
      seed([ada], adaId)
      app.addMailbox()
      compare(mailService.accountCount, 2)
      compare(mailService.editingIndex(), 1, "the page is editing the new row")

      app.removeCurrentAccountFromEditor()

      compare(dialog().request, null,
        "a draft has no mailbox to name, so nothing is offered for confirmation")
      compare(emails(), [ada], "the mailbox that was there before is untouched")
      compare(mailService.accountCount, 1, "the draft is discarded instead")
    }

    // Invariant: The same divergence, reached the other way: `switchToIndex` used to
    // return early without clearing `activeIndex`, so Edit opened whatever
    // draft happened to be open rather than the mailbox that was clicked.
    function test_edit_opens_the_mailbox_that_was_clicked_not_an_open_draft() {
      seed([ada, bob], adaId)
      app.addMailbox()
      compare(mailService.editingIndex(), 2)

      app.editAccount(0)
      compare(mailService.editingIndex(), 0)
      compare(mailService.accountAddress, ada, "the editor opens on ada")

      app.editAccount(1)
      compare(mailService.editingIndex(), 1)
      compare(mailService.accountAddress, bob, "and on bob")
    }

    function test_remove_on_a_real_mailbox_names_that_mailbox() {
      seed([ada, bob], adaId)
      app.editAccount(1)
      app.removeCurrentAccountFromEditor()

      var request = dialog().request
      verify(request !== null, "a mailbox can be removed")
      compare(request.email, bob, "and the confirmation names the one on screen")
      compare(request.index, 1)

      app.confirmAccountRemoval(request)
      compare(emails(), [ada])
    }

    // Invariant: A persisted mailbox whose address cannot be repaired has no id too, but
    // it is not the form's pending draft. Remove must not silently discard it
    // and leave its editor merely because no confirmation request can name it.
    function test_remove_does_not_discard_an_unrepairable_mailbox_as_a_draft() {
      seed([ada, "broken"], adaId)
      app.editAccount(1)
      compare(mailService.editingIndex(), 1)
      verify(app.showSetup, "the damaged mailbox is open for correction")

      app.removeCurrentAccountFromEditor()

      compare(mailService.accountCount, 2, "the persisted mailbox is retained")
      compare(mailService.accountSummaries[1].email, "broken")
      verify(app.showSetup, "the editor stays open so its address can be corrected")
    }

    // Invariant: A Google profile cannot replace a saved identity with a malformed address.
    function test_a_profile_cannot_rename_a_mailbox_to_a_non_address() {
      seed([ada], adaId)
      mailService.nameAccount(0, "ada")
      compare(mailService.accountSummaries[0].email, ada, "the address is kept")
      compare(mailService.accountSummaries[0].id, adaId, "and so is the id")

      mailService.nameAccount(0, "carol@example.com")
      compare(mailService.accountSummaries[0].id, "carol@example.com")
    }

    // Invariant: `accountAddress` is a binding that now reaches `activeIndex` through a
    // function call. QML captures property reads made inside the callee, so it
    // still re-evaluates — but silently going stale here would put the wrong
    // mailbox in the editor, so it is pinned down rather than assumed.
    function test_the_address_binding_still_tracks_activeIndex_alone() {
      seed([ada, bob], adaId)
      compare(mailService.accountAddress, ada)
      mailService.activeIndex = 1
      compare(mailService.accountAddress, bob, "the binding re-evaluates")
      mailService.activeIndex = 0
      compare(mailService.accountAddress, ada)
      mailService.activeIndex = -1
      compare(mailService.accountAddress, ada)
    }

    // Invariant: A draft is the form's working state. It used to ride along on whatever
    // save happened next, leaving a "New mailbox" on disk that nothing could
    // select and nothing could remove.
    function test_a_draft_is_never_part_of_what_is_written() {
      seed([ada], adaId)
      app.addMailbox()
      compare(mailService.accountCount, 2)

      mailService.accountsWritePayload = ""
      mailService.setAccountSignature(adaId, "signed")
      verify(mailService.accountsWritePayload !== "", "the list was written")

      var written = Accounts.load(mailService.accountsWritePayload)
      compare(Accounts.count(written), 1, "only the mailbox is written")
      compare(written.accounts[0].email, ada)
      compare(written.activeId, adaId, "and it is still the selected one")
      compare(mailService.accountCount, 2, "the draft stays in memory for the form")
    }
  }
}

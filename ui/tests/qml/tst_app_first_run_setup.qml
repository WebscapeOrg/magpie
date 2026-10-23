import "../../settings/Display.js" as Display
import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail

Item {
  width: 900
  height: 600

  QtObject {
    id: fakeAuth

    property bool credentialsPresent: true
    property bool loggedIn: false
    property bool loginBusy: false
    property bool toolsChecked: true
    property bool toolsPresent: true
    property bool credentialsWriteBusy: false
    property var missingTools: []
    property string lastError: ""
    property string clientId: ""
    property string clientDescription: ""
    property string credentialsPath: ""
    property var credentials: null

    function recheck() {}
    function saveCredentials() {}
  }

  QtObject { id: fakeBackend; property bool ready: false }

  QtObject {
    id: mailService
    property var backend: fakeBackend

    property var displayPreferences: Display.normalize({layout: "Split view"})
    property bool ready: false
    property bool anyAccountReady: false
    property bool hasSavedAccounts: true
    property bool sendPending: false
    property bool sending: false
    property bool windowOpen: false
    property bool sidebarCollapsed: false
    property bool alwaysShowImages: false
    property bool unifiedCalendarView: false
    property bool selectedReaderEmpty: false
    property bool selectedReaderTooHeavy: false
    property bool selectedTooHeavy: false
    property bool detailLoading: false
    property bool detailPainted: false
    property bool canOpenOnWeb: false
    property bool canRespondToInvite: false
    property bool rsvpSending: false
    property bool canArchive: false
    property bool canStar: false
    property bool canSpam: false
    property bool canTrash: false
    property bool canMarkRead: false
    property bool canMarkUnread: false
    property bool accountDraftOpen: false
    property string signInProgress: ""
    property int sendSecondsRemaining: 10
    property int accountCount: 1
    property int inboxUnread: 0
    property real bodyZoom: 1
    property string bodyMode: "reader"
    property string providerId: "gmail"
    property string pluginDir: ""
    property string accountName: ""
    property string accountEmail: "someone@gmail.com"
    property string accountAddress: "someone@gmail.com"
    property string activeAccountId: "someone@gmail.com"
    property string mailboxKey: "inbox"
    property string searchQuery: ""
    property string rawQuery: ""
    property string selectedId: ""
    property string lastError: ""
    property string actionStatus: ""
    property string syncedLabel: ""
    property string recipientContactStatus: ""
    property var accountSummaries: [{ provider: "gmail", email: "someone@gmail.com", active: true }]
    property var mailboxes: []
    property var labels: []
    property var messages: []
    property var selectedAttachments: []
    property var selectedInvite: null
    property var selectedResponse: ""
    property var recipientContacts: []
    property var sendAsAliases: []
    property var sendIdentities: []
    property var calendarController: null
    property var auth: fakeAuth
    property var selectedBody: null
    property var selectedMessage: null

    property var log: []
    property string lastAddedProvider: ""
    property var lastConfigured: null

    signal accountAdded()
    signal replySent()

    function record(text) {
      var next = log.slice()
      next.push(text)
      log = next
    }
    function editingIndex() { return accountSummaries.length - 1 }
    function addAccount() {
      lastAddedProvider = "gmail"
      record("add:" + lastAddedProvider)
      accountSummaries = accountSummaries.concat([{provider: lastAddedProvider, email: "", active: false, pending: true}])
      accountCount += 1
      accountAdded()
    }
    function configureCurrentAccount(values) {
      lastConfigured = values
      record("configure:" + String(values.provider || ""))
      if (values.provider !== undefined) providerId = String(values.provider)
    }
    function discardCurrentDraft() {
      record("discard")
      if (accountCount <= 1) return false
      accountSummaries = accountSummaries.slice(0, -1)
      accountCount -= 1
      return true
    }
    function preferredSendAs(_recipients) { return null }
    function refreshRecipientContacts() {}
    function cursorOffset(_id, _delta) { return "" }
    function clearSelection() {}
    function select(_id) {}
    function refresh() {}
    function search(_query) { searchQuery = String(_query || "") }
    function fail(text) { lastError = String(text || "") }
    function note(text) { actionStatus = String(text || "") }
  }

  Omamail.App {
    id: app
    service: mailService
  }

  TestCase {
    name: "AppFirstRunSetup"
    when: windowShown

    function named(item, objectName) {
      if (!item) return null
      if (item.objectName === objectName) return item
      var values = item.children || []
      for (var childIndex = 0; childIndex < values.length; childIndex++) {
        var found = named(values[childIndex], objectName)
        if (found) return found
      }
      return null
    }

    function removeAccountButton(item) {
      if (!item) return null
      if (item.text === "Remove account" && typeof item.clicked === "function") return item
      var values = item.children || []
      for (var childIndex = 0; childIndex < values.length; childIndex++) {
        var found = removeAccountButton(values[childIndex])
        if (found) return found
      }
      return null
    }

    function page() {
      var loader = named(app, "setup-page")
      verify(loader, "the setup loader is on the page")
      return loader.item
    }

    function init() {
      app.opened = true
      mailService.log = []
      mailService.lastAddedProvider = ""
      mailService.lastConfigured = null
      mailService.accountSummaries = [{provider: "gmail", email: "someone@gmail.com", active: true}]
      mailService.accountCount = 1
      mailService.hasSavedAccounts = true
      mailService.anyAccountReady = false
      mailService.ready = false
      fakeAuth.credentialsPresent = true
      app.resetNavigation()
      waitForRendering(app)
    }

    function test_first_run_opens_gmail_setup_directly() {
      mailService.hasSavedAccounts = false
      fakeAuth.credentialsPresent = false
      app.resetNavigation()
      waitForRendering(app)
      compare(app.navKinds, ["setup"])
      verify(page() && page().visible, "the Gmail setup page is drawn")
      verify(typeof page().signInNamed === "function")
      compare(mailService.accountCount, 1)
      compare(mailService.lastAddedProvider, "")
      verify(!app.accountDraftOpen, "the initial row is retained across setup visits")
    }

    function test_escape_closes_unsigned_setup_without_discarding_saved_account() {
      compare(app.navKinds, ["setup"])
      app.goBack()
      compare(app.opened, false)
      compare(mailService.accountCount, 1)
      compare(mailService.log.indexOf("discard"), -1)
    }

    function test_add_on_first_run_reuses_the_initial_row() {
      mailService.hasSavedAccounts = false
      app.addMailbox()
      compare(app.page, "setup")
      compare(mailService.accountCount, 1)
      compare(mailService.lastAddedProvider, "")
      verify(!app.accountDraftOpen)
      app.back()
      compare(app.navKinds, ["setup"])
      compare(mailService.log.indexOf("discard"), -1)
    }

    function test_back_from_added_mailbox_discards_draft_and_returns_to_settings() {
      mailService.anyAccountReady = true
      mailService.ready = true
      app.resetNavigation()
      app.openSettings()
      app.addMailbox()
      waitForRendering(app)
      compare(app.navKinds, ["list", "settings", "setup"])
      compare(mailService.accountCount, 2)
      compare(mailService.lastAddedProvider, "gmail")
      verify(app.accountDraftOpen)
      verify(page().visible)

      var back = named(app, "page-back")
      verify(back && back.visible)
      back.activated()
      compare(app.navKinds, ["list", "settings"])
      compare(mailService.accountCount, 1)
      compare(mailService.log[mailService.log.length - 1], "discard")
      compare(mailService.accountSummaries, [{provider: "gmail", email: "someone@gmail.com", active: true}])
    }

    function test_remove_added_draft_keeps_the_saved_gmail_mailbox() {
      mailService.anyAccountReady = true
      mailService.ready = true
      app.resetNavigation()
      app.openSettings()
      app.addMailbox()
      waitForRendering(app)
      var removeButton = removeAccountButton(page())
      verify(removeButton && removeButton.visible)
      removeButton.clicked()
      compare(mailService.accountCount, 1)
      compare(app.navKinds, ["list", "settings"])
      compare(mailService.accountSummaries, [{provider: "gmail", email: "someone@gmail.com", active: true}])
    }
  }
}

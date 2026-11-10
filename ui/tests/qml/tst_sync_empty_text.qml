import "../../settings"
import QtQuick 2.15
import QtTest 1.3
import qs.Commons as Commons
import "../../components" as Mail

// Q-011: with the notice above the Inbox gone, an empty mailbox says why while mail is still
// arriving, in the list and in the reader pane, and Settings shows the chosen mailbox's sync.
Item {
  width: 700
  height: 600

  QtObject {
    id: offline
    property bool available: true
    property string error: ""
    property string problem: ""
    readonly property bool needsGmail: false
    property bool statusFailed: false
    property double clock: 1793700000000
    property var status: ({paused: true})
    property var edits: []
    function setPaused(_value) {}
    function undo(_ticket) {}
    function dismissConflict(_ticket) {}
  }
  QtObject {
    id: other
    property bool available: true
    property string error: ""
    property string problem: ""
    readonly property bool needsGmail: false
    property bool statusFailed: false
    property double clock: 1793700000000
    property var status: ({inventoryComplete: true, pendingEdits: 3})
    property var edits: []
    function setPaused(_value) {}
    function undo(_ticket) {}
    function dismissConflict(_ticket) {}
  }

  QtObject {
    id: fakeService
    property var messages: []
    property bool hasMore: false
    property bool listLoading: false
    property bool listLoaded: true
    property string searchQuery: ""
    property var searchStatus: ({})
    property int preparingInbox: 0
    property string selectedId: ""
    property bool canArchive: true
    property string contentDirection: "auto"
    property var agentJobs: ({})
    property var agentAttentionByMessage: ({})
    property var localMailbox: offline
    property string providerId: "gmail"
    property string mailboxKey: "inbox"
    property string pluginName: "Omamail"
    property string version: "0.7.0"
    function loadMore() {}
    function act(_id, _action) {}
    function toggleStar(_id) {}
  }

  QtObject {
    id: settingsService
    property string activeAccountId: "a@example.org"
    property var accountSummaries: [{id: "a@example.org"}, {id: "b@example.net"}]
    property var accountSignatures: [
      { id: "a@example.org", email: "a@example.org", label: "", signature: "", provider: "gmail" },
      { id: "b@example.net", email: "b@example.net", label: "Work", signature: "", provider: "gmail" }
    ]
    property int undoSendSeconds: 10
    property bool unifiedCalendarView: false
    property bool notifyNewMail: true
    property string contentDirection: "auto"
    property var auth: null
    property var backend: null
    function findAccount(id) { return id === "a@example.org" ? {local: offline} : id === "b@example.net" ? {local: other} : null }
    function setAccountLabel(_id, _text) {}
    function setAccountSignature(_id, _text) {}
    function setAccountSignatureHtml(_id, _html) {}
    function setUndoSendSeconds(_value) {}
    function setUnifiedCalendarView(_value) {}
    function setNotifyNewMail(_value) {}
    function setContentDirection(_value) {}
    function setAlwaysRenderHeavyMessages(_value) {}
  }

  Mail.MessageList {
    id: list
    width: 340
    height: 300
    service: fakeService
    textColor: Commons.Color.foreground
    accentColor: Commons.Color.accent
    dimColor: Commons.Color.foreground
    urgentColor: Commons.Color.accent
    panelFontFamily: "monospace"
  }

  Loader {
    id: reader
    x: 350
    width: 340
    height: 300
    Component.onCompleted: setSource("../../components/ReaderBlankSlate.qml", ({
      service: fakeService,
      textColor: Qt.rgba(1, 1, 1, 1),
      accentColor: Qt.rgba(0.4, 0.6, 1, 1),
      dimColor: Qt.rgba(0.67, 0.67, 0.67, 1),
      dimmerColor: Qt.rgba(0.47, 0.47, 0.47, 1),
      panelFontFamily: "monospace"
    }))
  }

  Flickable {
    y: 310
    width: 700
    height: 290
    contentHeight: page.implicitHeight
    Mail.SettingsPage {
      id: page
      width: 700
      service: settingsService
      textColor: Qt.rgba(0.1, 0.1, 0.1, 1)
      dimColor: Qt.rgba(0.45, 0.45, 0.45, 1)
      accentColor: Qt.rgba(0.8, 0.4, 0, 1)
      urgentColor: Qt.rgba(0.8, 0.1, 0.1, 1)
      panelFontFamily: "monospace"
    }
  }

  TestCase {
    name: "SyncEmptyText"
    when: windowShown

    function texts() {
      tryCompare(reader, "status", Loader.Ready)
      return [findChild(list, "message-list-empty").text, findChild(reader.item, "reader-empty-status").text]
    }

    function init() {
      offline.status = ({paused: true})
      offline.problem = ""
      offline.error = ""
      offline.available = true
      fakeService.searchQuery = ""
      fakeService.listLoading = false
      fakeService.localMailbox = offline
    }

    function test_an_empty_mailbox_says_why() {
      compare(texts(), ["Sync is paused. Resume it in Settings → Mailboxes.", "Sync is paused. Resume it in Settings → Mailboxes."])
      offline.status = ({inventoryComplete: false, error: ""})
      compare(texts(), ["Checking Gmail…", "Checking Gmail…"])
      offline.status = ({inventoryComplete: true, error: "gmail_rate_limited"})
      compare(texts(), ["Checking for mail. Saved messages will appear here.", "Checking for mail. Saved messages will appear here."])
      offline.problem = "Some mail downloads are still failing. Magpie will keep trying."
      compare(texts(), ["", ""], "the problem above the Inbox says it")
    }

    function test_the_usual_text_applies_otherwise() {
      offline.status = ({inventoryComplete: true, error: ""})
      compare(texts(), ["Nothing here", "Nothing here"])
      offline.status = ({paused: true})
      fakeService.searchQuery = "from:someone"
      compare(texts()[1], "No messages match. Try fewer filters or different words.", "a search keeps its text")
      fakeService.searchQuery = ""
      fakeService.localMailbox = null
      compare(texts(), ["Nothing here", "Nothing here"], "the All accounts view has no offline mailbox")
    }

    function test_settings_shows_the_chosen_mailbox() {
      var sync = findChild(page, "settings-sync")
      verify(sync)
      page.selectNameAccount("a@example.org")
      compare(sync.mailbox, offline)
      verify(sync.visible)
      compare(findChild(sync, "settings-sync-status").text, "Sync paused")
      page.selectNameAccount("b@example.net")
      compare(sync.mailbox, other)
      compare(findChild(sync, "settings-sync-changes").text, "3 waiting to sync")
    }
  }
}

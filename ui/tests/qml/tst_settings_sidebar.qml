import "../../settings"
import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail

Item {
  width: 1800
  height: 1300

  QtObject {
    id: fakeShell
    property var hidden: []
    function hide(id) {
      var next = hidden.slice()
      next.push(String(id || ""))
      hidden = next
    }
  }

  QtObject {
    id: fakeAuth

    property bool credentialsPresent: false
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
    property var settings: ({
      imapHost: "imap.example.org", imapPort: 993,
      smtpHost: "smtp.example.org", smtpPort: 465,
      username: "", aliases: [], insecure: false
    })

    function recheck() {}
    function saveCredentials() {}
  }

  QtObject {
    id: mailService

    property var displayPreferences: ({layout: "Split view"})
    property bool ready: true
    property bool anyAccountReady: true
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
    property bool canArchive: true
    property bool canStar: true
    property bool canSpam: true
    property bool canTrash: true
    property bool canMarkRead: true
    property bool canMarkUnread: true
    property bool accountDraftOpen: false
    property bool signInProgress: false
    property int sendSecondsRemaining: 10
    property int accountCount: 1
    property int inboxUnread: 0
    property real bodyZoom: 1
    property string bodyMode: "reader"
    property string providerId: "imap"
    property string pluginDir: ""
    property string accountEmail: "me@example.com"
    property string accountAddress: "me@example.com"
    property string activeAccountId: "me@example.com"
    property string mailboxKey: "inbox"
    property string searchQuery: ""
    property string rawQuery: ""
    property string selectedId: ""
    property string lastError: ""
    property string actionStatus: ""
    property string syncedLabel: ""
    property string recipientContactStatus: ""
    property var auth: fakeAuth
    property var accountSummaries: [{ provider: "imap", email: "me@example.com" }]
    property var mailboxes: []
    property var labels: []
    property var messages: [{ id: "message-1", subject: "One" }]
    property var selectedAttachments: []
    property var selectedInvite: null
    property var selectedResponse: ""
    property var recipientContacts: []
    property var sendAsAliases: []
    property var sendIdentities: []
    property var calendarController: null
    property var selectedBody: ({ text: "Original body", source: "plain" })
    property var selectedMessage: null

    signal accountAdded()
    signal replySent()

    function editingIndex() { return 0 }
    function addAccount(provider) {
      accountCount += 1
      accountAdded()
    }
    function configureCurrentAccount(values) {
      if (values.provider !== undefined) providerId = String(values.provider)
    }
    function discardCurrentDraft() {
      if (accountCount > 1) accountCount -= 1
    }
    function switchToIndex(_index) { return true }
    function selectMailbox(key) {
      mailboxKey = String(key || "")
    }
    function search(query) {
      searchQuery = String(query || "")
    }
    function preferredSendAs(_recipients) { return null }
    function refreshRecipientContacts() {}
    function cursorOffset(_id, _delta) { return "" }
    function clearSelection() {
      selectedId = ""
    }
    function select(id) {
      selectedId = String(id || "")
      selectedMessage = null
      selectedBody = ({ text: "", source: "" })
      selectedAttachments = []
      detailPainted = false
      detailLoading = true
    }
    function loadAttachments(_messageId, _attachments, callback) { callback([], "") }
    function send(_fields) { return true }
    function undoSend() { return false }
    function saveDraft(fields, callback) {
      callback("draft-1", "")
    }
    function refresh() {}
    function fail(text) { lastError = String(text || "") }
    function note(text) { actionStatus = String(text || "") }
  }

  Omamail.App {
    id: app
    service: mailService
    shell: fakeShell
  }

  TestCase {
    name: "SettingsSidebar"
    when: windowShown

    function settingsScroller() {
      var page = findChild(app, "settings-page")
      var item = page
      while (item && String(item.toString()).indexOf("QQuickFlickable") < 0) item = item.parent
      return item
    }

    // Invariant: size the real App window; the test root is not its layout viewport.
    function appWindow() {
      return findMatching(app, function(item) { return item.title === "🐦 Magpie" })
    }

    function findMatching(item, accept) {
      if (!item) return null
      if (accept(item)) return item
      var values = item.children || []
      for (var index = 0; index < values.length; index++) {
        var found = findMatching(values[index], accept)
        if (found) return found
      }
      return null
    }

    function init() {
      mailService.anyAccountReady = true
      mailService.hasSavedAccounts = true
      app.opened = true
      appWindow().width = MailStyle.space(980)
      app.backToList()
      app.resetNavigation()
      app.openSettings()
      waitForRendering(app)
    }

    // Invariant: find sections by stable keys so inserting another section does not shift assertions.
    function sectionY(page, key) {
      for (var index = 0; index < page.sections.length; index++)
        if (page.sections[index].key === key) return page.sections[index].y
      return -1
    }

    function test_the_settings_page_scrolls_a_notch_at_a_time() {
      app.openSettings()
      wait(50)
      var view = settingsScroller()
      verify(view, "the page scrolls inside a Flickable")
      view.contentY = 0

      mouseWheel(view, view.width / 2, view.height / 2, 0, -120)
      compare(view.contentY, 240, "one notch, in the real hierarchy")

      mouseWheel(view, view.width / 2, view.height / 2, 0, 120)
      compare(view.contentY, 0)
    }

    function test_the_rail_lists_the_pages_sections_in_order() {
      var rail = findChild(app, "settings-sidebar")
      verify(rail && rail.visible, "a wide window has a rail")
      var page = findChild(app, "settings-page")
      var keys = page.sections.map(function(section) { return section.key })
      compare(keys.join(","), "restart,display,backend,bar,reading,notifications,writing,mailboxes,calendars,oauth")
      for (var index = 1; index < page.sections.length; index++)
        verify(page.sections[index].y > page.sections[index - 1].y, "sections are laid out top to bottom")
      for (var keyIndex = 0; keyIndex < keys.length; keyIndex++)
        verify(findChild(rail, "settings-section-" + keys[keyIndex]), "the rail has a row for " + keys[keyIndex])
    }

    function test_a_click_scrolls_the_page_and_the_highlight_follows() {
      var rail = findChild(app, "settings-sidebar")
      var page = findChild(app, "settings-page")
      var view = settingsScroller()
      verify(view, "the page scrolls inside a Flickable")
      compare(view.contentY, 0)
      compare(rail.activeKey, "restart",
        "the top of the page is the first section, whichever that is")
      compare(app.navKinds.join(","), "list,settings")

      var area = rail.parent
      verify(Math.abs((rail.x + rail.width + MailStyle.space(18)) - page.x) < 1, "the rail is against the page's left edge")
      verify(Math.abs(rail.x - (area.width - page.x - page.width)) < 1, "and the block is centred")
      var back = findChild(app, "page-back")
      verify(back.visible)
      var railLeft = rail.mapToItem(back.parent, 0, 0).x
      verify(Math.abs(back.x - railLeft) < 1, "Back is aligned with the rail's left edge")

      var writing = findChild(rail, "settings-section-writing")
      mouseClick(writing)
      tryVerify(function() { return Math.abs(view.contentY - sectionY(page, "writing")) < 1 }, 1000,
        "the page slid until the Writing heading was at the top")
      compare(app.navKinds.join(","), "list,settings", "still one page in history")
      tryCompare(rail, "activeKey", "writing")

      // Invariant: bottom padding lets the final settings heading reach the viewport top.
      mouseClick(findChild(rail, "settings-section-oauth"))
      tryVerify(function() { return Math.abs(view.contentY - sectionY(page, "oauth")) < 1 }, 1000,
        "the last heading reaches the top too")
      tryCompare(rail, "activeKey", "oauth")

      view.contentY = 0
      tryCompare(rail, "activeKey", "restart")
      view.contentY = sectionY(page, "mailboxes") + 5
      tryCompare(rail, "activeKey", "mailboxes")
    }

    function test_back_button_is_clickable_data() {
      return [{tag:"wide",width:980},{tag:"compact",width:600}]
    }
    function test_back_button_is_clickable(data) {
      appWindow().width=data.width
      waitForRendering(app)
      var back=findChild(app,"page-back")
      verify(back.visible)
      compare(back.parent.childAt(back.x+back.width/2,back.y+back.height/2),back,"Back is above the scroll viewport")
      mouseClick(back,back.width/2,back.height/2)
      tryCompare(app,"showSettings",false)
    }

    function test_settings_viewport_reaches_header_and_content_inset_scrolls() {
      var view=settingsScroller()
      var page=findChild(app,"settings-page")
      var rail=findChild(app,"settings-sidebar")
      compare(view.mapToItem(rail.parent.parent,0,0).y,0)
      verify(page.y>0,"initial spacing belongs to scrollable content")
      view.contentY=page.y
      compare(page.mapToItem(view,0,0).y,0,"content can reach the header edge")
    }

    function test_a_narrow_window_has_no_rail() {
      appWindow().width = 600
      waitForRendering(app)
      var rail = findChild(app, "settings-sidebar")
      verify(rail && !rail.visible)
      var page = findChild(app, "settings-page")
      verify(page.visible, "the page itself is still drawn")
      var back=findChild(app,"page-back")
      var view=settingsScroller()
      var before=back.mapToItem(view,0,0).y
      view.contentY=40
      compare(back.mapToItem(view,0,0).y,before-40,"compact Back scrolls away with content")
    }
  }
}

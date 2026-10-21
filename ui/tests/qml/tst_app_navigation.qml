import "../../settings"
import QtQuick 2.15
import QtTest 1.3
import qs.Commons
import "../.." as Omamail

// Where the window is, is a history. Every page is an entry on it, every Back
// — the bar on a page, Escape, a draft closing — pops one, and the root is
// what the window closes on. These are the rules `App.qml` applies on top of
// `account/Navigation.js`, run against the real views with a fake service.
Item {
  width: 1700
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
    property bool diagnosing: false
    property int diagnosisCalls: 0
    function diagnoseError() { diagnosisCalls++; diagnosing = true }

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
    property var unavailableActions: []

    property var log: []
    property var lastSavedDraft: null
    property bool refuseMove: false

    signal accountAdded()
    signal replySent()

    function record(text) {
      var next = log.slice()
      next.push(text)
      log = next
    }
    function count(text) {
      var n = 0
      for (var i = 0; i < log.length; i++) if (log[i] === text) n++
      return n
    }
    function editingIndex() { return 0 }
    function addAccount(provider) {
      record("add:" + String(provider || ""))
      accountCount += 1
      accountAdded()
    }
    function configureCurrentAccount(values) {
      record("configure:" + String(values.provider || ""))
      if (values.provider !== undefined) providerId = String(values.provider)
    }
    function discardCurrentDraft() {
      record("discard")
      if (accountCount > 1) accountCount -= 1
    }
    function switchToIndex(_index) { return true }
    function selectMailbox(key) {
      mailboxKey = String(key || "")
      record("mailbox:" + mailboxKey)
    }
    function search(query) {
      searchQuery = String(query || "")
      record("search:" + searchQuery)
    }
    function preferredSendAs(_recipients) { return null }
    function refreshRecipientContacts() {}
    function cursorOffset(_id, _delta) { return "" }
    function clearSelection() {
      selectedId = ""
      record("clear")
    }
    function select(id) {
      selectedId = String(id || "")
      selectedMessage = null
      selectedBody = ({ text: "", source: "" })
      selectedAttachments = []
      detailPainted = false
      detailLoading = true
    }
    // What the fetch would deliver, delivered by the test when it wants it.
    function land() {
      detailLoading = false
      detailPainted = true
      selectedMessage = ({
        id: selectedId,
        messageId: "<" + selectedId + "@example.com>",
        threadId: "thread-1",
        subject: "One",
        from: ({ email: "sender@example.com", display: "Sender" }),
        replyTo: ({ email: "sender@example.com" }),
        to: [], cc: [], bcc: [],
        fullTime: "today"
      })
      selectedBody = ({ text: "Original body", source: "plain" })
    }
    function loadAttachments(_messageId, _attachments, callback) { callback([], "") }
    function send(_fields) { return true }
    function undoSend() { return false }
    function saveDraft(fields, callback) {
      lastSavedDraft = fields
      record("saveDraft")
      callback("draft-1", "")
    }
    function refresh() {}
    function fail(text) { lastError = String(text || "") }
    function note(text) { actionStatus = String(text || "") }
    function act(id, action) {
      record("act:" + String(action || "") + ":" + String(id || ""))
      return true
    }
    function refuseUnavailableAction(action) {
      record("guard:" + String(action || ""))
      if (!refuseMove) return false
      note("HEY has no destination you can name")
      return true
    }
  }

  Omamail.App {
    id: app
    service: mailService
    shell: fakeShell
  }

  TestCase {
    name: "AppNavigation"
    when: windowShown

    function named(item, objectName) {
      if (!item) return null
      if (item.objectName === objectName) return item
      var values = item.children || []
      for (var i = 0; i < values.length; i++) {
        var found = named(values[i], objectName)
        if (found) return found
      }
      return null
    }

    // The first descendant the predicate accepts, wherever it sits.
    function having(item, accept) {
      if (!item) return null
      if (accept(item)) return item
      var values = item.children || []
      for (var i = 0; i < values.length; i++) {
        var found = having(values[i], accept)
        if (found) return found
      }
      return null
    }

    function backBar(item) {
      return having(item, function(it) {
        return it.label === "Back" && typeof it.activated === "function"
      })
    }

    function page() {
      var loader = named(app, "setup-page")
      verify(loader, "the setup loader is on the page")
      return loader.item
    }

    function kinds() { return app.navKinds.join(",") }

    function init() {
      // A test that failed part way through its scales must not leave the next
      // one measuring at somebody else's.
      Style.spacingScale = 1
      mailService.displayPreferences = ({layout: "Split view"})
      mailService.log = []
      mailService.lastSavedDraft = null
      mailService.refuseMove = false
      mailService.accountCount = 1
      mailService.providerId = "imap"
      mailService.hasSavedAccounts = true
      mailService.anyAccountReady = true
      mailService.searchQuery = ""
      mailService.mailboxKey = "inbox"
      mailService.selectedId = ""
      mailService.selectedMessage = null
      mailService.unavailableActions = []
      mailService.selectedBody = ({ text: "Original body", source: "plain" })
      fakeAuth.credentialsPresent = false
      fakeShell.hidden = []
      app.opened = true
      app.cursorId = ""
      // The root a reset rebuilds is the one the window is on, so a test that
      // ended on the calendar has to leave it first.
      app.backToList()
      app.resetNavigation()
      waitForRendering(app)
      compare(kinds(), "list", "every test starts on the list")
    }

    function test_control_comma_opens_settings_data() {
      return [{ tag: "list", context: "list" },
              { tag: "reader", context: "reader" },
              { tag: "compose-subject", context: "compose", field: "compose-subject-field" },
              { tag: "compose-body", context: "compose", field: "compose-body-editor" }]
    }

    function test_control_comma_opens_settings(data) {
      if (data.context === "reader") app.openMessage("message-1")
      if (data.context === "compose") app.startCompose("new")
      var scope = having(app, function(item) { return item.keyContext !== undefined })
      verify(scope)
      tryCompare(scope, "keyContext", data.context)
      scope.applyContextFocus()
      wait(20)
      var field = data.field ? named(app, data.field) : null
      if (field) {
        field.text = "Keep this draft"
        field.forceActiveFocus()
        verify(field.activeFocus)
      }
      var before = kinds()
      keyClick(Qt.Key_Comma, Qt.ControlModifier)
      tryCompare(app, "page", "settings")
      compare(kinds(), before + ",settings", "the shortcut uses the existing settings route")
      tryCompare(scope, "keyContext", "page")
      if (field) {
        compare(field.text, "Keep this draft", "Ctrl+, must not insert a comma")
        tryCompare(field, "activeFocus", false)
      }
      app.back()
      compare(kinds(), before, "Back returns to the screen that opened settings")
      if (field) compare(field.text, "Keep this draft", "the draft survives the settings visit")
      if (field) {
        field.text = ""
        app.saveAndLeaveCompose()
        tryCompare(app, "composing", false)
      }
    }

    function test_settings_add_and_the_form_unwind_one_page_at_a_time() {
      app.openSettings()
      compare(kinds(), "list,settings")
      verify(app.showSettings)
      waitForRendering(app)
      var settingsBack = named(app, "page-back")
      verify(settingsBack && settingsBack.visible, "Settings always has a Back: it is never a root")

      app.addMailbox()
      compare(kinds(), "list,settings,picker")
      waitForRendering(app)
      verify(typeof page().chosen === "function", "the chooser is on the page")
      // `visible` reads effective visibility: a chooser that exists inside a
      // hidden page is a blank window, which is what Add a mailbox once was.
      verify(page().visible, "and is drawn")

      page().chosen("gmail")
      compare(kinds(), "list,settings,picker,setup")
      compare(mailService.count("add:gmail"), 1, "a saved account exists, so Add makes a row")
      compare(app.editingProvider, "gmail")
      verify(app.accountDraftOpen, "the row is a draft until it is saved")
      waitForRendering(app)
      var back = named(app, "page-back")
      verify(back && back.visible, "the form has a Back, because there is a chooser under it")

      back.activated()
      compare(kinds(), "list,settings,picker")
      compare(mailService.count("discard"), 1, "backing out of a draft discards its row")

      app.back()
      compare(kinds(), "list,settings")
      app.back()
      compare(kinds(), "list")
      compare(mailService.count("discard"), 1, "and only that once")
    }

    // Settings opens over Drafts, whether a draft is being previewed or the
    // list is showing, and stays open: nothing in the draft path resets the
    // stack under it.
    function test_settings_opens_over_the_drafts_folder() {
      mailService.mailboxKey = "drafts"
      app.cursorId = "draft-7"
      app.openMessage("draft-7")
      compare(app.currentView, "reader")
      app.openSettings()
      wait(30)
      compare(app.page, "settings", "settings over a previewed draft")
      compare(app.showSettings, true)
      app.back()
      wait(30)
      compare(app.currentView, "reader")
      app.backToList()
      app.openSettings()
      wait(30)
      compare(app.page, "settings", "settings over the drafts list")
      app.back()
      mailService.mailboxKey = "inbox"
    }

    // The menu's Settings row goes where the key goes. The row is activated
    // rather than clicked: the runner delivers no press into a popup's
    // overlay, so a click here would prove nothing either way.
    function test_the_menu_settings_row_opens_settings() {
      mailService.mailboxKey = "drafts"
      var menu = named(app, "app-menu")
      verify(menu, "the app menu is there")
      menu.openAt(40, 40)
      wait(60)
      verify(menu.opened)
      var row = null
      for (var i = 0; i < menu.menuRows.length; i++)
        if (menu.menuRows[i].objectName === "app-menu-settings") row = menu.menuRows[i]
      verify(row && row.visible, "the Settings row is drawn")
      row.activated()
      wait(60)
      compare(menu.opened, false, "the menu closed")
      compare(app.page, "settings", "and Settings opened")
      compare(mailService.mailboxKey, "drafts", "the mailbox was left alone")
      app.back()
      mailService.mailboxKey = "inbox"
    }

    function test_plugin_menu_does_not_offer_quit() {
      var menu = named(app, "app-menu")
      verify(menu)
      menu.openAt(40, 40)
      wait(20)
      var row = null
      for (var i = 0; i < menu.menuRows.length; i++)
        if (menu.menuRows[i].objectName === "app-menu-quit") row = menu.menuRows[i]
      verify(row, "the shared menu keeps one tested row")
      compare(app.standaloneWindowChrome, false)
      compare(menu.canQuit, false)
      compare(row.visible, false, "a plugin cannot terminate its shell")
      menu.close()
    }

    function test_a_draft_over_the_reader_returns_to_the_reader() {
      app.openMessage("message-1")
      compare(kinds(), "list,reader")
      compare(app.currentView, "reader")

      app.startCompose("new")
      compare(kinds(), "list,reader,compose")
      verify(app.composing)

      app.back()
      compare(kinds(), "list,reader", "Back closes the draft and leaves the message open")
      compare(app.currentView, "reader")
    }

    function test_a_reply_raised_from_the_list_leaves_the_message_with_it() {
      app.cursorId = "message-1"
      app.composeFromCursor("reply")
      compare(kinds(), "list,reader", "the message opens first, on the reply's behalf")
      // The draft waits for the fetch; the entry it makes must still remember
      // that the user was on the list.
      mailService.land()
      tryCompare(app, "composing", true)
      compare(kinds(), "list,reader,compose")
      compare(app.nav[2].returnTo, 1, "the draft returns to where it was raised")

      app.back()
      tryCompare(app, "composing", false)
      compare(kinds(), "list", "Back from the reply leaves the message it opened")
      compare(mailService.count("saveDraft"), 0, "an untouched reply leaves without saving")
    }

    function test_a_reply_raised_from_the_list_waits_for_the_body() {
      app.cursorId = "message-1"
      app.composeFromCursor("reply")
      // What selecting a listed row does: the summary at once, the body later.
      mailService.selectedMessage = ({
        id: "message-1", subject: "One",
        from: ({ email: "sender@example.com", display: "Sender" }), to: [], cc: []
      })
      wait(50)
      compare(app.composing, false, "the summary alone does not begin the draft")

      mailService.land()
      tryCompare(app, "composing", true)
      app.back()
      tryCompare(app, "composing", false)
    }

    function test_the_shortcut_sheet_closes_before_the_page_under_it() {
      app.openMessage("message-1")
      app.runShortcut("help", "")
      compare(kinds(), "list,reader,help")
      verify(app.shortcutHelpVisible)

      app.goBack()
      compare(kinds(), "list,reader", "Escape closes the sheet, not the message")
      verify(!app.shortcutHelpVisible)

      app.runShortcut("help", "")
      app.runShortcut("help", "")
      compare(kinds(), "list,reader", "the key toggles")
    }

    function test_the_calendar_is_the_other_root_and_back_on_a_root_closes() {
      app.runShortcut("calendarView", "")
      compare(kinds(), "calendar")
      verify(app.calendarVisible)

      app.goBack()
      compare(fakeShell.hidden.length, 1, "Back on a root hides the window")
      compare(kinds(), "calendar", "and leaves the stack alone")

      app.runShortcut("mailView", "")
      compare(kinds(), "list", "the list is not a step back from the calendar")
    }

    function test_the_header_account_button_opens_the_switcher() {
      var trigger = named(app, "header-account-button")
      verify(trigger && trigger.visible)
      var switcher = having(app, function(it) { return typeof it.openCentered === "function" && typeof it.accountChosen === "function" })
      mouseClick(trigger)
      tryCompare(switcher,"opened",true)
      compare(trigger.selected,true)
      switcher.close()
    }
    function test_folder_navigation_is_hidden_until_requested() {
      var toggle = named(app,"folder-button")
      verify(toggle && toggle.visible)
      compare(app.foldersVisible,false)
      toggle.clicked()
      compare(app.foldersVisible,true)
      toggle.clicked()
      compare(app.foldersVisible,false)
    }
    function test_notices_do_not_leave_a_permanent_footer() {
      var banner = named(app,"mail-notice")
      mailService.lastError=""; mailService.actionStatus=""; app.notice=""
      tryCompare(banner,"height",0)
      app.notice="Connection restored"
      tryVerify(function() { return banner.visible && banner.height>0 })
      app.notice=""
      tryCompare(banner,"height",0)
    }

    function test_notices_wrap_without_layout_cycles() {
      mailService.lastError = ""
      mailService.actionStatus = ""
      var banner = named(app, "mail-notice")
      var text = having(banner, function(item) { return typeof item.text === "string" })
      var host = having(app, function(item) { return item.title === "🐦 Magpie" })
      var oldWidth = host.width
      var oldPreferences = MailStyle.preferences
      failOnWarning(/Binding loop detected for property "height"/)
      try {
        for (var size of [12, 18]) {
          MailStyle.preferences = {interfaceSize: size}
          for (var width of [720, 360]) {
            host.width = width
            app.notice = ""
            wait(10)
            app.notice = "Magpie could not confirm this change. Check the message’s current state before trying again."
            waitForRendering(banner)
            verify(banner.height > 0)
            verify(text.paintedWidth <= text.width + 1)
            verify(text.paintedHeight <= text.height + 1)
            app.notice = ""
            tryCompare(banner, "height", 0)
          }
        }
      } finally {
        host.width = oldWidth
        MailStyle.preferences = oldPreferences
        app.notice = ""
      }
    }

    function test_header_shows_compose_for_mail_and_view_selector_for_calendar() {
      var compose = named(app, "compose-button")
      verify(compose && compose.visible)
      compare(compose.text, "Compose")
      compare(typeof compose.iconName, "undefined")

      app.showCalendar()
      waitForRendering(app)
      verify(!compose.visible)
      compare(named(app, "create-event-button"), null)
      var selector = named(app, "calendar-view-selector")
      verify(selector && selector.visible)
      app.runShortcut("calendarWeek")
      compare(selector.currentText, "Week (w)")
      app.runShortcut("calendarDay")
      compare(selector.currentText, "Day (d)")
    }
    function test_reader_toolbar_back_returns_to_list() {
      mailService.displayPreferences = ({layout: "Single pane"})
      var back = named(app, "reader-back-button")
      verify(back && !back.visible)
      app.openMessage("m1")
      waitForRendering(app)
      verify(back.visible)
      var compose = named(app, "compose-button")
      compare(back.height, compose.height)
      compare(back.bordered, compose.bordered)
      compare(back.fontSize, compose.fontSize)
      var search = named(app, "app-title-bar")
      verify(back.mapToItem(search, 0, 0).y >= 0)
      back.clicked()
      compare(kinds(), "list")
      verify(!back.visible)
      mailService.displayPreferences = ({layout: "Split view"})
      app.openMessage("m1")
      waitForRendering(app)
      verify(!back.visible)
    }

    function test_status_error_opens_external_diagnosis_once_data() {
      return [{tag: "mouse"}, {tag: "return", key: Qt.Key_Return},
              {tag: "keypad-enter", key: Qt.Key_Enter, modifiers: Qt.KeypadModifier},
              {tag: "space", key: Qt.Key_Space}]
    }

    function test_status_error_opens_external_diagnosis_once(data) {
      mailService.lastError = "Could not confirm AI started. Check the conversation before retrying."
      mailService.actionStatus = ""
      mailService.diagnosing = false
      mailService.diagnosisCalls = 0
      var button = named(app, "diagnose-error-button")
      verify(button !== null)
      verify(waitForRendering(app))
      verify(button.visible)
      verify(button.width > 0 && button.height > 0)
      if (data.key !== undefined) {
        button.forceActiveFocus()
        verify(button.activeFocus)
        keyClick(data.key, data.modifiers || Qt.NoModifier)
      } else {
        mouseClick(button, button.width / 2, button.height / 2)
      }
      compare(mailService.diagnosisCalls, 1)
      compare(button.enabled, false)
      mailService.diagnosing = false
      mailService.lastError = ""
      compare(button.visible, false)
    }

    function test_an_event_opened_for_reading_is_a_place() {
      app.runShortcut("calendarView", "")
      var calendar = having(app, function(it) { return typeof it.closeDetail === "function" })
      verify(calendar, "the calendar view is on the page")
      calendar.activateEvent({ uid: "e1", summary: "Standup",
        start: { ms: Date.now(), allDay: false }, end: { ms: Date.now() + 3600000 } })
      compare(kinds(), "calendar,calendarDetail")

      app.goBack()
      compare(kinds(), "calendar", "Escape closes the event, not the calendar")
      verify(!calendar.detailOpen)
    }

    function test_changing_the_list_drops_the_history_over_it() {
      app.openMessage("message-1")
      compare(kinds(), "list,reader")
      app.goMailbox("starred")
      compare(kinds(), "list", "another mailbox is another list, not a step")
      compare(mailService.mailboxKey, "starred")

      app.openMessage("message-1")
      app.openMessage("message-1")
      compare(kinds(), "list,reader", "reading the next message does not lengthen history")
    }

    // A click in the search field, then a row: the field kept the focus — a
    // MouseArea moves none — so the context stayed "search" with a message
    // open, and `e` typed itself into the query instead of archiving.
    function test_opening_a_message_takes_the_keyboard_back_from_search() {
      var field = having(app, function(it) {
        return it.placeholderText !== undefined
          && String(it.placeholderText).indexOf("Search...") === 0
      })
      verify(field, "the search field is on the page")
      var scope = having(app, function(it) {
        return typeof it.keyContext === "string" && typeof it.parkKeyboard === "function"
      })
      verify(scope, "the focus scope is on the page")
      var spot = field.mapToItem(app, field.width / 2, field.height / 2)
      mouseClick(app, spot.x, spot.y)
      tryCompare(scope, "keyContext", "search")

      app.openMessage("message-1")
      mailService.land()
      tryCompare(scope, "keyContext", "reader")
      keyClick(Qt.Key_E)
      compare(field.text, "", "the letter is a shortcut again, not text")
      compare(mailService.count("act:archive:message-1"), 1,
        "and the list's keys work with the reader open")
    }

    function test_back_on_the_root_clears_a_search_before_closing() {
      mailService.searchQuery = "invoice"
      app.goBack()
      compare(mailService.count("search:"), 1, "an active search is the nearer thing to leave")
      compare(fakeShell.hidden.length, 0)
      mailService.searchQuery = ""
      app.goBack()
      compare(fakeShell.hidden.length, 1)
    }

    function test_first_run_stacks_follow_what_the_service_knows() {
      mailService.anyAccountReady = false
      mailService.hasSavedAccounts = false
      waitForRendering(app)
      compare(kinds(), "picker", "nothing saved: the question is the whole window")
      var picker = page()
      verify(!named(app, "page-back").visible, "and there is nothing to go back to")

      // A row saved with a valid server but never signed in — the Gmail
      // address on the IMAP form — opens on its form, with the chooser under.
      mailService.hasSavedAccounts = true
      fakeAuth.credentialsPresent = true
      waitForRendering(app)
      compare(kinds(), "picker,setup")
      compare(app.editingProvider, "imap")
      var back = named(app, "page-back")
      verify(back && back.visible, "the form has a way back")

      back.activated()
      compare(kinds(), "picker")
      compare(mailService.count("discard"), 0, "a saved row is not a draft")

      // Backed out, the user is left alone even as the service learns more.
      mailService.providerId = "gmail"
      waitForRendering(app)
      compare(kinds(), "picker", "a root the user moved off is not rebuilt under them")

      mailService.anyAccountReady = true
      waitForRendering(app)
      compare(kinds(), "list", "a mailbox becoming usable starts over on it")
    }

    // "Manage accounts..." on the switcher is an entry into Settings, from
    // whichever root the switcher was opened over, and the page is entered at
    // its top. The page keeps its scroll while it is in history — Back from a
    // mailbox's form returns to the Mailboxes row it left — but a page that
    // was left and entered again is a new visit, and a new visit that opened
    // on the Calendars section because that is where the last one ended
    // looked like the calendar had been opened instead of settings.
    function test_manage_accounts_on_the_switcher_enters_settings_at_the_top() {
      app.openSettings()
      waitForRendering(app)
      var page = named(app, "settings-page")
      var view = page
      while (view && String(view.toString()).indexOf("QQuickFlickable") < 0) view = view.parent
      verify(view, "the settings page scrolls inside a Flickable")
      var calendars = -1
      for (var i = 0; i < page.sections.length; i++)
        if (page.sections[i].key === "calendars") calendars = page.sections[i].y
      verify(calendars > 0, "the Calendars section is some way down the page")
      view.contentY = calendars
      compare(view.contentY, calendars, "the previous visit ended on Calendars")
      app.back()
      compare(kinds(), "list")

      // The switcher opens over the calendar root as readily as over the list.
      app.showCalendar()
      compare(kinds(), "calendar")
      var switcher = having(app, function(it) {
        return typeof it.openCentered === "function" && typeof it.manageRequested === "function"
      })
      switcher.openCentered()
      tryCompare(switcher, "opened", true)
      var manage = having(switcher.menuRows, function(it) {
        return it.text === "Manage accounts..." && typeof it.activated === "function"
      })
      verify(manage && manage.visible, "the switcher offers Manage accounts...")
      mouseClick(manage)
      tryCompare(switcher, "opened", false)
      compare(app.page, "settings", "which opens Settings")
      compare(kinds(), "calendar,settings", "over the root it was opened on")
      compare(app.calendarVisible, false, "and the calendar stands down for it")
      verify(named(app, "settings-sidebar").visible, "the settings rail is up")
      compare(view.contentY, 0, "at the top of the page, not where the last visit ended")
      compare(named(app, "settings-sidebar").activeKey, page.sections[0].key)

      // Back from a page pushed over Settings returns to where Settings was.
      view.contentY = calendars
      app.editAccount(0)
      compare(kinds(), "calendar,settings,setup")
      app.back()
      compare(kinds(), "calendar,settings")
      compare(view.contentY, calendars, "a return keeps the scroll")
    }

    function test_editing_an_account_from_settings_returns_to_settings() {
      app.openSettings()
      app.editAccount(0)
      compare(kinds(), "list,settings,setup")
      compare(app.editingProvider, "imap")
      verify(!app.accountDraftOpen)
      app.back()
      compare(kinds(), "list,settings")
      compare(mailService.count("discard"), 0)
    }

    function test_an_unavailable_move_is_refused_before_the_picker_opens() {
      mailService.refuseMove = true
      app.cursorId = "message-1"

      app.runShortcut("moveToLabel", "v")

      compare(mailService.count("guard:label:destination"), 1,
        "the provider guard answers the key before a destination is requested")
      compare(named(app, "label-picker").opened, false)
      compare(mailService.actionStatus, "HEY has no destination you can name")
    }
  }
}

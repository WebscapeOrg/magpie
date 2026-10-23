import QtQuick
import "controls" as Widgets
import "settings"
import QtQuick.Controls
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "account/Model.js" as Model
import "components/MailboxIdentity.js" as MailboxIdentity
import "account" as Account
import "account/Accounts.js" as Accounts
import "account/Navigation.js" as Nav
import "account/Unified.js" as Unified
import "compose/Recovery.js" as Recovery
import "compose" as Compose
import "keys/Keymap.js" as Keymap
import "agent/Agent.js" as Agent
import "message/Mailto.js" as Mailto
import "message/Message.js" as Message
import "components"
import "compose"
import "calendar"
import "backend" as Backend
import "search" as Search

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  // Invariant: The standalone host enables client-side chrome; the Omarchy shell owns plugin chrome.
  property bool standaloneWindowChrome: false
  property bool opened: false
  property bool closingFromHost: false
  function syncWindowVisibility() {
    window.visible = root.opened
  }
  onOpenedChanged: Qt.callLater(syncWindowVisibility)
  property string draftSavedToast: ""
  property string composeRecoveryNotice: ""
  property bool composeRecoveryUpdateNoticePending: false
  readonly property string draftSavedNotice: composeRecoveryNotice || draftSavedToast
  readonly property bool backendUnavailable: !!service && !!service.backendRuntime
    && (service.backendRuntime.state !== "ready" || !service.backend.ready)

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "magpie"
  property var composeRecovery: Recovery.empty()
  property bool composeRecoveryLoaded: false
  property bool composeRecoveryRestoring: false
  property int composeRecoveryRevision: 0
  property bool composeDetachingForSave: false
  property string lastComposeRecoveryText: ""
  property string composeWritePayload: ""
  property bool composeWriteQueued: false
  property bool composeWriting: false
  property bool composeReading: false
  property bool composeRecoveryConflict: false
  property string composeStorageRevision: ""
  property bool composeReceiptChecking: false
  property int composeCommittedRevision: 0
  property var composeReceiptAcks: []
  property var composeReceiptAckBusy: ({})
  property var composeDeliveryStates: ({})
  readonly property bool restartBusy: restartController.busy
  readonly property string restartStatus: restartController.message
  readonly property bool restartFailed: restartController.failed
  readonly property bool restartWorkSaved: !!service && !service.persistencePending
    && !composeWriting && !composeWriteQueued && !composeReading && !composeReceiptChecking
    && !composeRecoveryConflict && !settings.importing
    && (!(compose.opened || compose.parkedForSend) || composeRecoveryLoaded)

  Backend.RestartController { id: restartController; objectName: "app-restart"; app: root }

  function prepareRestart() {
    settings.flushEdits()
    if (compose.opened || compose.parkedForSend) saveComposeRecovery()
    if (service && typeof service.saveWindowPrefs === "function") service.saveWindowPrefs()
  }

  function requestRestart() { return restartController.request() }

  // Invariant: Recovery accepts native-normalized records; live editor fields remain editor-owned.
  function loadComposeRecovery(record) {
    composeRecovery = record && typeof record === "object" ? record : Recovery.empty()
    lastComposeRecoveryText = composeRecovery.active === true ? JSON.stringify(composeRecovery) : ""
    composeRecoveryLoaded = true
    reconcileComposeReceipts()
  }

  RecoveryController {
    id: composeRecoveryController
    app: root
    composer: compose
    recoveryTimer: composeRecoveryTimer
  }
  function reconcileComposeReceipts() { composeRecoveryController.reconcileComposeReceipts() }
  function queueComposeReceiptAck(accountId, sendId, revision) {
    composeRecoveryController.queueComposeReceiptAck(accountId, sendId, revision)
  }
  function acknowledgeComposeReceipts() { composeRecoveryController.acknowledgeComposeReceipts() }

  function readComposeRecovery() { return composeRecoveryController.readComposeRecovery() }
  function restoreComposeRecovery() { return composeRecoveryController.restoreComposeRecovery() }
  function parkedBesides(draft) { return composeRecoveryController.parkedBesides(draft) }
  function saveComposeRecovery(saved) { return composeRecoveryController.saveComposeRecovery(saved) }
  function scheduleComposeRecovery() { return composeRecoveryController.scheduleComposeRecovery() }
  function clearComposeRecovery(expectedRevision) { return composeRecoveryController.clearComposeRecovery(expectedRevision) }
  function writeComposeRecovery(raw) { return composeRecoveryController.writeComposeRecovery(raw) }
  function drainComposeRecovery() { return composeRecoveryController.drainComposeRecovery() }

  Connections {
    target: root.service ? root.service.backend : null
    ignoreUnknownSignals: true
    function onReadyChanged() {
      if (root.service.backend.ready) { root.readComposeRecovery(); root.acknowledgeComposeReceipts() }
    }
  }
  onServiceChanged: Qt.callLater(readComposeRecovery)

  Timer {
    id: composeRecoveryTimer
    interval: 300
    repeat: false
    onTriggered: root.saveComposeRecovery()
  }

  readonly property color foreground: Commons.Color.foreground
  readonly property color background: Commons.Color.background
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property color danger: Commons.Color.urgent
  readonly property color popupBackground: Commons.Color.popups.background
  readonly property color popupBorder: Commons.Color.popups.border
  readonly property color borderColor: Style.normalBorderColor
  readonly property int borderWidth: Style.normalBorderWidth
  readonly property color calendarBorder: Style.normalBorderColor
  readonly property color calendarTodayBackground: Qt.alpha(root.accent, 0.035)
  readonly property int calendarBorderWidth: Style.normalBorderWidth
  readonly property color dim: Qt.rgba(
    foreground.r * 0.68 + background.r * 0.32,
    foreground.g * 0.68 + background.g * 0.32,
    foreground.b * 0.68 + background.b * 0.32, 1)
  readonly property color dimmer: Qt.rgba(
    foreground.r * 0.45 + background.r * 0.55,
    foreground.g * 0.45 + background.g * 0.55,
    foreground.b * 0.45 + background.b * 0.55, 1)
  readonly property color link: Qt.hsla(accent.hslHue,
    Math.min(accent.hslSaturation, 0.55),
    accent.hslLightness, 1.0)

  readonly property string fontFamily: MailStyle.family

  function copyText(text) {
    return service && typeof service.copyText === "function"
      ? service.copyText(String(text || "")) : false
  }

  readonly property var agentPrompt: agentPromptLoader.item || inactiveAgentPrompt
  readonly property var composeAgent: composeAgentLoader.item || inactiveComposeAgent
  QtObject {
    id: inactiveAgentPrompt
    property bool opened: false
    property bool activeFocus: false
    property string messageId: ""
    function close() {}
    function openCenteredFor() {}
    function openFor() {}
    function openForSelection() {}
    function takeFocus() {}
  }
  QtObject {
    id: inactiveComposeAgent
    property bool opened: false
    property bool activeFocus: false
    property bool working: false
    property var job: null
    function close() {}
    function open() {}
    function openAt() {}
    function takeFocus() {}
  }

  readonly property bool assistantOpen: agentPrompt.opened || composeAgent.opened
  readonly property var activeAssistant: composeAgent.opened ? composeAgent : (agentPrompt.opened ? agentPrompt : null)
  property real preferredAssistantWidth: 0
  readonly property real assistantMaxWidth: Math.max(0, Math.min(window.width * 0.65, window.width - MailStyle.space(320)))
  readonly property real assistantMinWidth: Math.min(MailStyle.space(280), assistantMaxWidth)
  readonly property real assistantWidth: assistantOpen ? Math.max(assistantMinWidth, Math.min(assistantMaxWidth,
    preferredAssistantWidth > 0 ? preferredAssistantWidth : Math.min(MailStyle.space(420), window.width * 0.45))) : 0
  property bool assistantEditing: false
  readonly property real mailWidth: window.width - assistantWidth
  readonly property bool wide: mailWidth >= Style.space(1000)
  property bool foldersVisible: false
  readonly property bool singlePane: !service || !service.displayPreferences || service.displayPreferences.layout !== "Split view"
  readonly property bool compact: mailWidth < Style.space(760)
  readonly property bool singleContent: singlePane || compact

  property string cursorId: ""
  // Invariant: Selection belongs to the window. Reader-only actions target the open message.
  property var checkedIds: []
  // Invariant: IMAP message IDs are account-local; clear checked IDs before acting through another account.
  property string checkedAccountId: ""
  // Invariant: Visible list selections remain active beside the reader in split view.
  readonly property bool listOnScreen: currentView === "list"
    || (currentView === "reader" && !singleContent)
  readonly property bool selectionActive: checkedIds.length > 0 && listOnScreen

  function toggleCheck(id) {
    var key = String(id || "")
    if (key === "") return false
    claimChecks()
    checkedIds = Model.toggleId(checkedIds, key)
    return true
  }

  function claimChecks() {
    var owner = service ? String(service.activeAccountId || "") : ""
    if (checkedAccountId !== owner) checkedIds = []
    checkedAccountId = owner
  }

  function clearChecksIfForeign() {
    var owner = service ? String(service.activeAccountId || "") : ""
    if (checkedIds.length > 0 && checkedAccountId !== owner) checkedIds = []
    checkedAccountId = owner
  }

  // Invariant: Shift selection uses the endpoint's next state and makes that endpoint the next range anchor.
  function checkRange(id) {
    if (!service) return false
    var key = String(id || "")
    if (key === "") return false
    claimChecks()
    checkedIds = Model.toggleRange(checkedIds, service.messages, cursorId, key)
    cursorId = key
    return true
  }

  function checkAll() {
    if (!service) return false
    claimChecks()
    var all = Model.allIds(service.messages)
    checkedIds = Model.retainIds(checkedIds, service.messages).length === all.length ? [] : all
    return true
  }

  Account.UnifiedBatchSelection { id: batchSelection; app: root; service: root.service }
  function actOnChecked(action) {
    if (!service || checkedIds.length === 0) return false
    if (checkedAccountId !== String(service.activeAccountId || "")) {
      checkedIds = []
      return false
    }
    var ids = checkedIds.slice()
    var leaves = !Model.survivesAction(service.mailboxKey, action,
      service.rawQuery, service.hasLabels, service.rawLabelId)
    var next = leaves ? Model.cursorAfterRemovals(service.messages, ids, cursorId) : cursorId
    var wasOpen = currentView === "reader" && ids.indexOf(service.selectedId) >= 0
    var scope = batchSelection.scope
    var completion = service.unified ? function(result) {
      Qt.callLater(function() { batchSelection.restore(result.failedIds, scope) })
    } : undefined
    if (!service.actMany(ids, action, completion)) return false
    checkedIds = []
    if (!leaves) return true
    if (wasOpen) {
      if (next !== "") openMessage(next)
      else backToList()
      return true
    }
    cursorId = next
    revealCursorRow()
    return true
  }

  // Invariant: The service persists reading mode and zoom across messages and window lifetimes.
  readonly property string bodyMode: service ? service.bodyMode : "reader"
  readonly property real bodyZoom: service ? service.bodyZoom : 1.0
  // Invariant: Zero selects the proportional pane width; positive widths persist completed drags.
  property real listWidth: 0
  property real sidebarWidth: 0
  readonly property real sidebarMinWidth: MailStyle.space(110)
  readonly property real sidebarMaxWidth: MailStyle.space(360)

  function persistPaneWidths() {
    if (service) service.setPaneWidths(sidebarWidth, listWidth)
  }

  function zoomBy(step) {
    if (service) service.setBodyZoom(Model.zoomAfterStep(service.bodyZoom, step))
  }
  // Invariant: Views own overlay open state; navigation follows their open/close signals.
  property var nav: Nav.rootFor(({}))
  readonly property var navKinds: Nav.kinds(nav)
  readonly property var navPage: Nav.page(nav)
  readonly property var navOverlay: Nav.overlay(nav)
  readonly property string page: navPage.kind
  readonly property string overlay: navOverlay ? navOverlay.kind : ""
  readonly property string currentView: page === "reader" ? "reader"
    : ((page === "calendar" || page === "calendarDetail") ? "calendar" : "list")
  readonly property bool calendarVisible: currentView === "calendar"
  readonly property bool showSettings: page === "settings"
  readonly property bool showSetup: page === "setup"
  readonly property bool showPage: showSettings || showSetup
  onComposingChanged: { if (!composing) composeAgent.close(); else agentPrompt.close() }
  onShowPageChanged: if (showPage) { agentPrompt.close(); composeAgent.close() }
  readonly property bool composing: overlay === "compose" || overlay === "eventComposer"
  readonly property bool shortcutHelpVisible: overlay === "help"
  readonly property bool accountDraftOpen: page === "setup" && navPage.draft === true

  // Invariant: Pre-sign-in account changes rebuild only untouched navigation, so saving an address cannot reopen a dismissed form.
  readonly property var rootState: ({
    anyReady: anyReady,
    accountReady: ready,
    hasSavedAccounts: !!service && service.hasSavedAccounts === true,
    setupUnderway: setupUnderway,
    view: currentView
  })
  property bool navUntouched: true
  property bool wasReady: false
  property bool wasAccountReady: false
  onRootStateChanged: {
    var flipped = rootState.anyReady !== wasReady
    var signedIn = rootState.accountReady && !wasAccountReady
    wasReady = rootState.anyReady
    wasAccountReady = rootState.accountReady
    var editingUnreadyAccount = page === "setup" && !ready
    var completedSetup = signedIn && page === "setup"
    if ((flipped && !editingUnreadyAccount) || completedSetup || (!rootState.anyReady && navUntouched)) resetNavigation()
  }
  function resetNavigation() {
    var next = Nav.rootFor(rootState)
    // Invariant: Already-open drafts emit no openedChanged during root reset; restore their navigation entries explicitly.
    if (compose && compose.opened) next = Nav.push(next, Nav.entry("compose"))
    if (eventComposer && eventComposer.opened) next = Nav.push(next, Nav.entry("eventComposer"))
    nav = next
    navUntouched = true
    pendingComposeReturnTo = -1
  }
  function rootKind() {
    return nav.length > 0 && nav[0].kind === "calendar" ? "calendar" : "list"
  }

  function pushEntry(kind, fields) {
    navUntouched = false
    nav = Nav.push(nav, Nav.entry(kind, fields))
  }

  // Invariant: Mouse navigation does not move focus; release the search field before mailbox shortcuts resume.
  onNavChanged: if (searchBar.fieldFocused) focusScope.parkKeyboard()

  // Invariant: Closing an underlying overlay also removes overlays opened above it.
  function dropOverlay(kind) {
    var stack = nav
    if (Nav.top(stack).kind === kind) {
      navUntouched = false
      nav = Nav.pop(stack)
      return
    }
    for (var entryIndex = stack.length - 1; entryIndex >= 0; entryIndex--) {
      if (stack[entryIndex].kind !== kind) continue
      var keep = typeof stack[entryIndex].returnTo === "number" ? stack[entryIndex].returnTo : entryIndex
      navUntouched = false
      nav = stack.slice(0, Math.max(1, Math.min(keep, entryIndex)))
      return
    }
  }

  function back() {
    var leaving = Nav.top(nav)
    pendingComposeReturnTo = -1
    if (leaving.kind === "compose") return requestLeaveCompose()
    if (leaving.kind === "eventComposer") return eventComposer.close()
    if (leaving.kind === "calendarDetail") return calendarView.closeDetail()
    if (leaving.kind === "reader") {
      pendingComposeMode = ""
      pendingDraftId = ""
      if (service) service.clearSelection()
    }
    if (leaving.kind === "setup" && leaving.draft === true && service)
      service.discardCurrentDraft()
    var next = Nav.pop(nav)
    if (next === nav) {
      if (service && service.searchQuery !== "") service.search("")
      else requestClose()
      return
    }
    navUntouched = false
    nav = next
    Qt.callLater(function() { focusScope.applyContextFocus() })
  }

  function openHelp() {
    if (overlay !== "help") pushEntry("help")
  }
  function dismissHelp() {
    if (overlay === "help") dropOverlay("help")
  }
  function toggleHelp() {
    if (overlay === "help") dismissHelp()
    else openHelp()
  }

  function addMailbox() {
    dismissHelp()
    if (!service) return
    var draft = service.hasSavedAccounts === true
    if (draft && service.addAccount() === false) return
    pushEntry("setup", { draft: draft })
  }
  function openClientSetup() {
    if (!service) return
    var gmailId = service.gmailAccountId()
    if (gmailId === "") return addMailbox()
    service.switchTo(gmailId)
    pushEntry("setup", { draft: false })
  }
  property string notice: ""
  onNoticeChanged: if (notice !== "") noticeTimer.restart()
  // Invariant: Sidebar visibility belongs to the persistent service, not the window lifetime.
  readonly property bool sidebarCollapsed: !!service && service.sidebarCollapsed
  function toggleSidebar() {
    if (service) service.setSidebarCollapsed(!service.sidebarCollapsed)
  }

  // Invariant: A new Settings visit starts at the top; returning through history preserves its scroll position.
  function openSettings() {
    dismissHelp()
    if (page === "settings") return
    settingsScroll.stop()
    settingsFlick.contentY = 0
    pushEntry("settings")
  }

  readonly property bool ready: !!service && service.ready
  // Invariant: An added but unsigned-in mailbox belongs in Settings rather than first-run setup.
  readonly property bool anyReady: !!service && service.anyAccountReady
  // Invariant: Existing credentials indicate that account setup is underway.
  readonly property bool setupUnderway: !!service && !!service.auth
    && service.auth.credentialsPresent === true

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(String(payloadJson || "{}")) || ({}) } catch (error) {}
    closingFromHost = false
    opened = true
    if (service) service.windowOpen = true
    var targetAccount = String(payload.accountId || "")
    var acceptedAccount = targetAccount === ""
      || (!!service && service.switchTo(targetAccount) === true)
    if (acceptedAccount && payload.mailbox && service)
      service.selectMailbox(String(payload.mailbox))
    if (acceptedAccount && payload.messageId && service) {
      var targetService = service
      var selectedAccount = String(service.activeAccountId || "")
      Qt.callLater(function() {
        if (root.service !== targetService
            || String(targetService.activeAccountId || "") !== selectedAccount) return
        var messageId = String(payload.messageId)
        if (targetService.unified && targetAccount !== "")
          messageId = Unified.unifiedId(targetAccount, messageId)
        root.openMessage(messageId)
      })
    }
    if (payload.view === "calendar") {
      showCalendar()
      Qt.callLater(function() {
        calendarView.showEvent(String(payload.eventId || ""), Number(payload.eventStart || 0))
      })
    }
    var draft = Mailto.draftFromPayload(payload)
    if (draft) root.openDraft(draft)
    Qt.callLater(root.restoreComposeRecovery)
    // Invariant: The service may load the list while this window is closed; seed the cursor without waiting for another change.
    cursorId = Model.cursorAfterReload(service ? service.messages : [], cursorId)
    if (service && service.sidebarWidth !== undefined) {
      sidebarWidth = service.sidebarWidth
      listWidth = service.listWidth
    }
    // Invariant: Jobs can finish while the window is closed; refresh their state on open.
    if (service && typeof service.refreshAgentJobs === "function") service.refreshAgentJobs()
    Qt.callLater(function() { focusScope.applyContextFocus() })
  }

  function close() {
    closingFromHost = true
    composeExitDialog.close()
    // Invariant: A preview is not a saved reader location; clear it when closing from the list root.
    if (service && service.selectionIsPreview) service.clearSelection()
    if (compose.opened || compose.parkedForSend) saveComposeRecovery()
    opened = false
    if (service) service.windowOpen = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  // Invariant: The rich-document override applies to one message only.
  function openMessage(id) {
    if (!service) return
    pendingComposeMode = ""
    pendingDraftId = ""
    reader.forceRichAnyway = false
    cursorId = String(id || "")
    service.select(cursorId)
    // Invariant: Opening a message from another page creates a list return target.
    if (page !== "list" && page !== "reader") nav = Nav.resetTo(nav, "list")
    pushEntry("reader", { id: cursorId })
  }

  // Invariant: Conversation members have no list row; preserve the list cursor while replacing the reader entry.
  function openMember(id) {
    var member = String(id || "")
    if (!service || member === "") return
    var cursor = cursorId
    openMessage(member)
    cursorId = cursor
  }

  function stepMember(delta) {
    if (!service || !service.showsRail) return
    var projection = service.conversationProjection || ({})
    var navigation = projection.navigation || ({})
    var stop = navigation[service.selectedId]
    var next = stop ? (delta < 0 ? stop.previous : stop.next)
      : (delta < 0 ? projection.last : projection.first)
    next = String(next || "")
    if (next !== "" && next !== service.selectedId) openMember(next)
  }

  function openOrEdit(id) {
    if (service && service.mailboxKey === "drafts" && editDraft(id)) return true
    return openMessage(id)
  }

  function editDraft(id) {
    if (!service || service.mailboxKey !== "drafts") return false
    var draftId = String(id || "")
    if (draftId === "") return false
    pendingComposeMode = ""
    pendingDraftId = draftId
    if (service.selectedId !== draftId || service.detailLoading
        || !service.detailPainted || !service.selectedMessage) service.select(draftId)
    resumeHeldDraft()
    if (pendingDraftId !== "") Qt.callLater(root.resumeHeldDraft)
    return true
  }

  // Invariant: A changed mailbox or query invalidates reader history; return to a fresh list.
  function backToList() {
    pendingComposeMode = ""
    pendingDraftId = ""
    pendingComposeReturnTo = -1
    if (service) service.clearSelection()
    navUntouched = false
    nav = Nav.resetTo(nav, "list")
    Qt.callLater(function() { focusScope.applyContextFocus() })
  }

  function showCalendar() {
    navUntouched = false
    nav = Nav.replaceRoot(nav, "calendar")
  }

  function revealCursorRow() {
    if (list.visible) list.reveal(cursorId)
  }

  // Invariant: Keyboard navigation explicitly opens and marks the message read; it is not a preview.
  function moveCursor(delta) {
    if (!service || (focusScope.keyContext !== "list" && focusScope.keyContext !== "reader")
        || labelPicker.opened) return
    var next = service.cursorOffset(cursorId, delta)
    if (next === "") return
    cursorId = next
    revealCursorRow()
    if (service.selectedId !== next || service.selectionIsPreview || currentView !== "reader")
      openMessage(next)
  }

  // Invariant: Selecting a message clears its old summary and body; defer reply creation until both new values arrive.
  property string pendingComposeMode: ""
  property string pendingDraftId: ""
  // Invariant: Capture the return depth before opening a reply's reader. A value of -1 uses the depth when the draft opens.
  property int pendingComposeReturnTo: -1

  // Invariant: The opened signal owns the navigation push; deferred replies already captured their return depth.
  function trackComposeOpened() {
    var fields = {}
    if (pendingComposeReturnTo >= 0) fields.returnTo = pendingComposeReturnTo
    pendingComposeReturnTo = -1
    pushEntry("compose", fields)
  }

  function composeReturnView() {
    for (var entryIndex = nav.length - 1; entryIndex >= 0; entryIndex--) {
      if (nav[entryIndex].kind !== "compose") continue
      var keep = typeof nav[entryIndex].returnTo === "number" ? nav[entryIndex].returnTo : entryIndex
      return keep >= 2 && nav[keep - 1].kind === "reader" ? "reader" : "list"
    }
    return currentView === "reader" ? "reader" : "list"
  }

  Compose.PendingCompose {
    id: pendingCompose
    app: root
    composer: compose
    assistant: root.agentPrompt
    composeAssistant: root.composeAgent
  }
  function startCompose(mode) { pendingCompose.start(mode) }

  // Invariant: openDraft receives payloads after the window has opened.
  function openDraft(draft) {
    if (!draft) return
    pendingDraftId = ""
    compose.beginDraft(draft)
  }

  function resumeHeldCompose() { pendingCompose.resume() }

  function resumeHeldDraft() {
    if (pendingDraftId === "" || !service) return
    if (service.selectedId !== pendingDraftId || service.detailLoading
        || !service.detailPainted || !service.selectedMessage) return
    var messageId = pendingDraftId
    pendingDraftId = ""
    compose.beginDraft(Message.draftFields(service.selectedMessage,
      service.selectedBody.text), messageId, service.selectedAttachments)
  }

  // Performance: Keep an already-open message selected; selecting it again discards and refetches its body.
  function composeFromCursor(mode) {
    if (!service || cursorId === "") return
    pendingComposeReturnTo = Nav.depth(nav)
    // Invariant: A matching preview must become a reader entry before replying, so mark-read and the draft return target are established.
    if (service.selectedId !== cursorId || service.selectionIsPreview)
      openMessage(cursorId)
    startCompose(mode)
  }

  function leaveCompose() {
    pendingComposeReturnTo = -1
    dropOverlay("compose")
  }

  function requestLeaveCompose() {
    if (!compose.opened) return
    if (!compose.hasUserChanges()) {
      compose.finish()
      return
    }
    composeExitDialog.open()
  }

  function saveAndLeaveCompose(force) {
    if (!compose.opened) return
    if (!service) return
    if (!compose.attachmentsReady) {
      var attachmentError = String(compose.forwardAttachmentError || compose.attachmentRecoveryError || "")
      service.fail(attachmentError !== "" ? "Resolve the attachment error before saving this draft"
        : "Wait for attachments to finish loading before saving this draft")
      return
    }
    if (force !== true && !compose.hasMeaningfulDraft()) {
      compose.finish()
      return
    }
    var saved = compose.snapshotDraft()
    var recoveryRevision = saveComposeRecovery(saved)
    composeDetachingForSave = true
    compose.detachForSave()
    composeDetachingForSave = false
    var fields = compose.fieldsForDraft(saved)
    service.saveDraft(fields, function(result, error) {
      if (!root) return
      if (error) {
        compose.recoverDetachedSave(saved)
        if (root.composeRecoveryRevision === recoveryRevision)
          root.saveComposeRecovery(saved)
        service.fail("Could not save draft: " + String(error))
        return
      }
      compose.completeDetachedSave(saved)
      if (compose.opened) root.scheduleComposeRecovery()
      else root.clearComposeRecovery(recoveryRevision)
      var warning = String(result && result.warning || "")
      root.draftSavedToast = warning === "" ? "Draft saved" : warning
      if (warning !== "" && service && typeof service.note === "function")
        service.note(warning)
      draftSavedTimer.restart()
      if (service.mailboxKey === "drafts") service.refresh()
    })
  }

  function restoreParkedDraft(sendId, oldest) {
    var named = (compose.parkedDrafts || []).filter(function(entry) { return entry.sendId === String(sendId || "") })
    var receiptAccount = named.length && named[0].draft ? String(named[0].draft.accountId || "") : ""
    if (!compose.resumePendingSend(sendId, oldest)) return false
    var recoveryRevision = saveComposeRecovery()
    if (receiptAccount !== "") queueComposeReceiptAck(receiptAccount, String(sendId), recoveryRevision)
    var interrupted = compose.interruptedDraft
    var fields = compose.interruptedFields()
    if (!interrupted || !fields || !service) return true
    service.saveDraft(fields, function(saved, error) {
      if (!root) return
      if (error) {
        service.fail("Could not save the newer draft: " + String(error))
        return
      }
      if (!compose.completeInterruptedSave(interrupted)) return
      root.draftSavedToast = "Draft saved"
      draftSavedTimer.restart()
    })
    return true
  }

  function undoPendingSend() {
    if (!service) return false
    return service.undoSend(function(id) {
      if (root && id) root.restoreParkedDraft(id === true ? "" : String(id), false)
    })
  }

  Timer {
    id: draftSavedTimer
    interval: 4000
    repeat: false
    onTriggered: root.draftSavedToast = ""
  }

  // Invariant: A label picker opened outside the checked selection acts on that message alone.
  property bool labelPickerOnlyCursor: false

  function openLabelPicker(onlyCursor) {
    if (!service || (cursorId === "" && !selectionActive)) return false
    labelPickerOnlyCursor = onlyCursor === true
    // Invariant: Label operations target one account; provider-specific refusals remain with the provider guard.
    if (service.unified) {
      service.fail("Moving to a label needs one mailbox on screen")
      return false
    }
    if (service.refuseUnavailableAction("label:destination", cursorId)) return false
    labelPicker.open()
    return true
  }

  // Invariant: Row actions target the checked selection only when that row belongs to it.
  function actFromRow(id, action) {
    if (!service) return false
    var outside = checkedIds.indexOf(id) < 0
    cursorId = id
    if (action === "star") {
      if (selectionActive && !outside)
        return actOnChecked(Model.starActionFor(Model.summariesById(service.messages, checkedIds)))
      service.toggleStar(id)
      return true
    }
    return actOnCursor(action, outside)
  }

  function agentSubjectFor(id) {
    if (!service) return ""
    var index = Model.indexById(service.messages, id)
    if (index >= 0) return String(service.messages[index].subject || "")
    if (service.selectedId === id && service.selectedMessage)
      return String(service.selectedMessage.subject || "")
    return ""
  }

  function openAgentAt(id, sceneX, sceneY) {
    if (!service || !service.hasAgent || service.agentAvailable === false) return false
    if (selectionActive && checkedIds.indexOf(String(id || "")) >= 0) {
      agentPrompt.openForSelection(checkedIds, sceneX, sceneY)
      return true
    }
    if (String(id || "") === "") return false
    agentPrompt.openFor(id, agentSubjectFor(id), sceneX, sceneY)
    return true
  }

  function openAgentCentered(id) {
    if (!service || !service.hasAgent || service.agentAvailable === false) return false
    if (selectionActive) {
      var centre = root.mapToGlobal(Math.max(0, root.width / 2 - MailStyle.space(190)),
        Math.max(0, root.height / 2 - MailStyle.space(90)))
      agentPrompt.openForSelection(checkedIds, centre.x, centre.y)
      return true
    }
    if (String(id || "") === "") return false
    agentPrompt.openCenteredFor(id, agentSubjectFor(id))
    return true
  }

  function openAgentFromRow(id, sceneX, sceneY) {
    return openAgentAt(id, sceneX, sceneY)
  }

  // Invariant: onlyCursor limits an action to a row outside the checked selection.
  function actOnCursor(action, onlyCursor) {
    if (!service) return false
    if (selectionActive && onlyCursor !== true) return actOnChecked(action)
    if (cursorId === "") return false
    var acted = cursorId
    var row = service.messages[Model.indexById(service.messages, acted)]
    // Invariant: An open reader can show a member of the acted conversation. A preview must not open and mark the next row read after a mutation.
    var wasOpen = currentView === "reader" && !service.selectionIsPreview
      && (service.selectedId === acted || Model.rowHoldsMember(row, service.selectedId))
    // Invariant: Resolve the next row before the action removes its current neighbor.
    var next = Model.cursorAfterRemoval(service.messages, acted)
    // Invariant: Cursor repair must use the same mailbox, query, label, provider, and conversation facts as MailAccount.act.
    var leaves = !Model.survivesAction(service.mailboxKey, action,
      service.rawQuery, service.hasLabels, service.rawLabelId, row)
    if (!service.act(acted, action)) return false
    if (!leaves) return true
    // Invariant: Repair a departing cursor before the next keyboard move tries to locate it.
    if (wasOpen) {
      if (next !== "") openMessage(next)
      else backToList()
      return true
    }
    cursorId = next
    revealCursorRow()
    return true
  }

  // Invariant: Member actions target one message. If it leaves, prefer the newer neighbor, then the older neighbor, then the list.
  function actOnMember(action, id) {
    var member = String(id || "")
    if (!service || member === "") return false
    var wasOpen = currentView === "reader" && service.selectedId === member
    // Invariant: Resolve the adjacent member before the action changes the conversation.
    var projection = service.conversationProjection || ({})
    var stop = (projection.navigation || ({}))[member]
    var next = stop ? String(stop.neighbor || "") : ""
    var members = service.memberSummaries
    var summary = members && typeof members === "object" ? members[member] : null
    var leaves = !Model.survivesAction(service.mailboxKey, action,
      service.rawQuery, service.hasLabels, service.rawLabelId, summary || null)
    if (!service.act(member, action, false, true)) return false
    if (!leaves || !wasOpen) return true
    if (next !== "") openMember(next)
    else backToList()
    return true
  }

  function goMailbox(key) {
    if (!service) return
    searchBar.setQuery("")
    service.selectMailbox(key)
    backToList()
  }

  // Invariant: Rail badges and numeric shortcuts share the same ordered slots.
  readonly property var sidebarSlots: service
    ? Model.sidebarSlots(service.mailboxes, service.visibleLabels, 9) : []

  function goSlot(index) {
    if (!service || index < 0 || index >= sidebarSlots.length) return
    var slot = sidebarSlots[index]
    if (slot.kind === "mailbox") return goMailbox(slot.key)
    // Invariant: Label selection keeps the Gmail label ID with its display name.
    searchBar.setQuery("")
    service.selectLabel(slot.name, slot.id)
    backToList()
  }

  // Invariant: Key IDs come from keys/Keymap.js; sequence distinguishes bindings sharing an ID.
  function runShortcut(id, sequence) {
    if (restartBusy) {
      if (id === "back") restartController.cancel()
      return
    }
    if (id === "assistantSend") return activeAssistant ? activeAssistant.submitCurrent() : false
    if (id === "assistantChooseCommand") return activeAssistant ? activeAssistant.chooseCommand() : false
    if (id === "assistantCommandNext") return activeAssistant ? activeAssistant.moveCommand(1) : false
    if (id === "assistantCommandPrevious") return activeAssistant ? activeAssistant.moveCommand(-1) : false
    // Invariant: The help sheet is an overlay; QQC popups route their own keys.
    if (shortcutHelpVisible) {
      if (id === "cursorDown") return shortcutHelp.scrollBy(1)
      if (id === "cursorUp") return shortcutHelp.scrollBy(-1)
      if (id === "scrollDown") return shortcutHelp.scrollBy(1)
      if (id === "scrollUp") return shortcutHelp.scrollBy(-1)
    }
    if (id === "cursorDown") return moveCursor(1)
    if (id === "cursorUp") return moveCursor(-1)
    if (id === "scrollDown") return reader.scrollBy(1)
    if (id === "scrollUp") return reader.scrollBy(-1)
    // Invariant: Opening Drafts from the keyboard edits the draft; clicking a row can still preview it.
    if (id === "open") return openOrEdit(cursorId)
    if (id === "openReader") return openOrEdit(cursorId)
    if (id === "backToList") return backToList()
    if (id === "nextMember") return stepMember(1)
    if (id === "previousMember") return stepMember(-1)
    if (id === "archive") return actOnCursor("archive")
    if (id === "trash") return actOnCursor("trash")
    // Invariant: Reader starring targets the selected member; list starring targets the cursor or checked selection.
    if (id === "star") {
      if (selectionActive)
        return actOnChecked(Model.starActionFor(Model.summariesById(service.messages, checkedIds)))
      var starred = currentView === "reader" && service && service.selectedId !== ""
        ? service.selectedId : cursorId
      if (service && starred !== "") service.toggleStar(starred)
      return
    }
    if (id === "toggleCheck") return toggleCheck(cursorId)
    if (id === "askAgent") {
      if (!service || !service.hasAgent || service.agentAvailable === false) return false
      if (root.composing) { composeAgent.open(); return true }
      var target = currentView === "reader" && service ? service.selectedId : cursorId
      return openAgentCentered(target)
    }
    if (id === "checkAll") return checkAll()
    if (id === "moveToLabel") return openLabelPicker()
    if (id === "markRead") return actOnCursor("markRead")
    if (id === "markUnread") return actOnCursor("markUnread")
    if (id === "reply") return composeFromCursor("reply")
    if (id === "replyAll") return composeFromCursor("replyAll")
    if (id === "forward") return composeFromCursor("forward")
    if (id === "compose") {
      if (service && service.mailboxKey === "drafts" && editDraft(cursorId)) return
      return startCompose("new")
    }
    if (id === "createEvent") return eventComposer.begin()
    if (id === "calendarNext") return calendarView.moveSelection(1)
    if (id === "calendarPrevious") return calendarView.moveSelection(-1)
    if (id === "openCalendarEvent") return calendarView.activateSelection()
    if (id === "calendarPreviousPeriod") return calendarView.movePeriod(-1)
    if (id === "calendarNextPeriod") return calendarView.movePeriod(1)
    if (id === "calendarToday") return calendarView.goToday()
    if (id === "calendarWeek") return calendarView.setView("week")
    if (id === "calendarDay") return calendarView.setView("day")
    if (id === "calendarAgenda") return calendarView.setView("agenda")
    if (id === "calendarUndo") return root.service.calendarController.undoLastChange()
    if (id === "calendarMonth") return calendarView.setView("month")
    if (id === "send") return compose.submit()
    if (id === "saveEvent") return eventComposer.submit("all")
    if (id === "guestNext") return eventComposer.moveGuestSuggestion(1)
    if (id === "guestPrevious") return eventComposer.moveGuestSuggestion(-1)
    if (id === "guestChoose") return eventComposer.chooseGuestSuggestion()
    if (id === "undoSend") { undoPendingSend(); return }
    if (id === "search") return searchBar.focusField()
    if (id === "searchSuggestionNext") return searchBar.moveSuggestion(1)
    if (id === "searchSuggestionPrevious") return searchBar.moveSuggestion(-1)
    if (id === "searchSuggestionComplete") return searchBar.completeSuggestion()
    if (id === "searchSuggestionAccept") return searchBar.accept()
    if (id === "goMailbox") return goSlot(Keymap.slotFor(id, sequence))
    if (id === "goAccount") {
      var accountIndex = Keymap.slotFor(id, sequence)
      if (service && accountIndex >= 0 && accountIndex < service.accountCount)
        root.switchAccount(accountIndex)
      return
    }
    if (id === "switchAccount") return accountSwitcher.openCentered()
    if (id === "calendar") {
      if (calendarVisible) backToList()
      else {
        showCalendar()
        calendarView.refresh()
      }
      return
    }
    if (id === "mailView") return backToList()
    if (id === "calendarView") {
      showCalendar()
      calendarView.refresh()
      return
    }
    if (id === "toggleSidebar") return toggleSidebar()
    if (id === "zoomIn") return zoomBy(0.1)
    if (id === "zoomOut") return zoomBy(-0.1)
    if (id === "zoomReset") { if (service) service.setBodyZoom(1.0); return }
    if (id === "refresh") {
      if (calendarVisible) calendarView.refresh()
      else if (service) service.refresh()
      return
    }
    if (id === "settings") return openSettings()
    if (id === "help") return toggleHelp()
    if (id === "back") return goBack()
  }

  // Invariant: QQC.Popup with CloseOnEscape consumes Escape before this handler.
  function goBack() {
    if (searchBar.dismissAssistance()) return
    if (eventComposer.guestSuggestionsOpen) { eventComposer.dismissGuestSuggestions(); return }
    if (calendarView.dismissPreview()) return
    if (activeAssistant && activeAssistant.commandsOpen) { activeAssistant.dismissCommands(); return }
    if (activeAssistant && activeAssistant.historyMode) { activeAssistant.leaveHistory(); return }
    if (activeAssistant && activeAssistant.interrupt()) return
    if (composeAgent.opened) { composeAgent.close(); return }
    if (agentPrompt.opened) { agentPrompt.close(); return }
    // Invariant: Park focus directly after leaving search; applyContextFocus still sees search until the field loses focus.
    if (searchBar.fieldFocused) {
      if (searchBar.queryText !== "") searchBar.clear()
      focusScope.parkKeyboard()
      return
    }
    if (selectionActive) {
      checkedIds = []
      return
    }
    back()
  }

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onReplySent(sendId) {
      if (!compose.completePendingSend(sendId)) return
      // Invariant: Other parked sends still own their recovery records.
      if (compose.opened || compose.parkedForSend) root.scheduleComposeRecovery()
      else root.clearComposeRecovery()
    }
    function onReplyFailed(sendId) {
      if (!root.restoreParkedDraft(sendId, true)) return
      root.scheduleComposeRecovery()
    }
    // Invariant: A deferred reply needs both summary and body, whichever arrives last.
    function onSelectedBodyChanged() { Qt.callLater(function() {
      root.resumeHeldCompose()
      root.resumeHeldDraft()
    }) }
    function onSelectedMessageChanged() { Qt.callLater(function() {
      root.resumeHeldCompose()
      root.resumeHeldDraft()
    }) }

    // Invariant: IMAP cursor IDs are account-local; clear the cursor before shortcuts can act through another account.
    function onActiveAccountIdChanged() {
      searchBar.dismissAssistance()
      searchBar.setQuery(root.service ? root.service.searchQuery : "")
      root.clearChecksIfForeign()
      root.cursorId = ""
      root.closeLabelPopups()
      // Invariant: Assistant popups remain bound to the account that opened them.
      agentPrompt.close()
      composeAgent.close()
      composeExitDialog.close()
    }
    function onSidebarWidthChanged() { root.sidebarWidth = root.service.sidebarWidth }
    function onSearchQueryChanged() {
      if (!searchBar.fieldFocused) searchBar.setQuery(root.service ? root.service.searchQuery : "")
    }
    function onSearchGenerationChanged() { statusViewport.contentY = 0 }
    function onListWidthChanged() { root.listWidth = root.service.listWidth }
    function onMessagesChanged() {
      root.clearChecksIfForeign()
      root.cursorId = Model.cursorAfterReload(
        root.service ? root.service.messages : [], root.cursorId)
      root.checkedIds = Model.retainIds(root.checkedIds,
        root.service ? root.service.messages : [])
    }
    function onDuplicateAccount(email) {
      root.notice = email + " is already added"
    }
    // Invariant: Account setup opens before asynchronous account creation finishes; do not push again on accountAdded.
  }

  Component {
    id: gmailSetupPage

    SetupPage {
      service: root.service
      textColor: root.foreground
      dimColor: root.dim
      dangerColor: root.danger
      accentColor: root.accent
      panelFontFamily: root.fontFamily
      accountCount: root.service ? root.service.accountCount : 1
      onRemoveRequested: root.removeCurrentAccountFromEditor()
    }
  }

  // Invariant: Unified view selects a mailbox available across its accounts.
  function chooseUnified() {
    if (!service) return false
    var keepCalendar = calendarVisible
    var mailbox = service.mailboxKey
    service.setUnifiedMailboxes(true)
    // Invariant: Select the new mailbox even while Calendar is visible, so the rail and returning list agree.
    var target = Model.mailboxAfterAccountSwitch(mailbox, service.mailboxes)
    service.selectMailbox(target !== "" ? target : "inbox")
    if (keepCalendar) {
      showCalendar()
      return true
    }
    backToList()
    return true
  }

  function switchAccount(index) {
    if (!service) return false
    var keepCalendar = calendarVisible
    var mailbox = service.mailboxKey
    if (service.unifiedMailboxes) service.setUnifiedMailboxes(false)
    if (service.switchToIndex(index) !== true) return false
    if (keepCalendar) {
      showCalendar()
      return true
    }
    var target = Model.mailboxAfterAccountSwitch(mailbox, service.mailboxes)
    if (target !== "") service.selectMailbox(target)
    backToList()
    return true
  }

  function editAccount(index) {
    if (!service) return false
    if (!service.switchToIndex(index)) return false
    pushEntry("setup", { draft: false })
    return true
  }

  // Invariant: Remove the row being edited; a pending draft can share an account ID with a saved row.
  function removeCurrentAccountFromEditor() {
    if (!service || service.accountCount <= 1) return
    var index = service.editingIndex()
    if (index < 0) return
    var values = service.accountSummaries || []
    var request = Accounts.removalRequest({ accounts: values }, index)
    if (request) {
      accountRemovalDialog.openFor(request)
      return
    }
    // Invariant: An unnamed pending row may be discarded. An unnamed persisted account remains available for repair.
    if (service.discardCurrentDraft() !== true) return
    navUntouched = false
    nav = Nav.push(Nav.resetTo(nav, rootKind()), Nav.entry("settings"))
  }

  function confirmAccountRemoval(request) {
    if (!service) return
    var index = Accounts.confirmRemoval({ accounts: service.accountSummaries || [] }, request)
    if (index < 0) return
    service.removeAccountAt(index)
    // Invariant: Account removal invalidates its editor and underlying mailbox history.
    navUntouched = false
    nav = Nav.push(Nav.resetTo(nav, rootKind()), Nav.entry("settings"))
  }

  function requestEventDelete(sourceId, event) {
    if (event && service) confirmDeleteDialog.openFor(service.calendarController.deleteRequest(sourceId, event))
  }

  function confirmDelete(request) {
    if (!service) return
    if (request.kind === "event" && request.event) {
      service.calendarController.confirmDelete(request)
      calendarView.closeDetail()
    }
    if (request.kind === "label" && request.labelId) service.deleteLabel(request.labelId, request.accountId)
  }

  // Invariant: Label popups retain their opening account ID and close on account switches; IMAP folder IDs can collide across accounts.

  function openLabelMenu(labelId, path, sceneX, sceneY) {
    if (!service) return
    labelMenu.accountId = service.activeAccountId
    labelMenu.canManage = service.canManageLabels
    labelMenu.monitored = service.monitoredLabelIds.indexOf(labelId) >= 0
    labelMenu.openAt(labelId, path, sceneX, sceneY)
  }

  function closeLabelPopups() {
    labelMenu.close()
    namePrompt.close()
    labelMovePicker.close()
    if (confirmDeleteDialog.request && confirmDeleteDialog.request.kind === "label") confirmDeleteDialog.close()
  }

  function labelPathFor(id, accountId) {
    var label = service ? service.labelById(id, accountId) : null
    return label ? String(label.name || "") : ""
  }

  function askLabelName(kind, subject, title, initial, hint, accountId) {
    namePrompt.accountId = String(accountId || "")
    namePrompt.openFor(kind, subject, title, initial, hint)
  }

  function labelNamed(kind, subject, text, accountId) {
    if (!service) return
    if (kind === "rename") service.renameLabel(subject, text, accountId)
    else if (kind === "create") service.createLabel(subject, text, accountId)
  }

  function copyAddress(address) {
    var text = String(address || "").trim()
    // Invariant: Refuse leading-dash addresses before passing them to the host clipboard boundary.
    if (text === "" || text.charAt(0) === "-") return
    if (service && typeof service.copyText === "function") service.copyText(text)
    notice = "Copied " + text
    noticeTimer.restart()
  }

  function searchAddress(field, address) {
    if (!service) return
    if (!service.backend || !service.backend.ready) return
    var account = service.current
    var accountId = account ? account.accountId : ""
    service.backend.call("providers.resolve", {provider: "gmail", operation: "addressQuery", field: field, value: String(address || "")}, function(result, error) {
      if (error || !root.service || root.service.current !== account
          || (account && account.accountId !== accountId)) return
      var query = String((result || {}).value || "")
      if (query === "") return
      var text = (field === "to" ? "to: " : "from: ") + String(address || "").trim()
      root.service.searchAddress(query, text)
      searchBar.setQuery(text)
      root.backToList()
    })
  }

  FloatingWindow {
    id: window
    title: "🐦 Magpie"
    color: root.background
    implicitWidth: MailStyle.space(980)
    implicitHeight: MailStyle.space(720)
    minimumSize: Qt.size(Style.space(640), Style.space(480))

    Component.onCompleted: root.syncWindowVisibility()

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost) root.requestClose()
    }

    Widgets.Button {
      objectName: "cancel-restart"
      z: 300
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: MailStyle.space(18)
      visible: restartController.canCancel
      text: "Cancel restart"
      focusable: true
      bordered: true
      foreground: root.foreground
      background: root.background
      accent: root.accent
      onClicked: restartController.cancel()
    }

    Rectangle {
      anchors.fill: parent
      z: 200
      visible: root.backendUnavailable && !root.restartBusy && !root.showSettings
      color: root.background
      BackendSetup {
        anchors.centerIn: parent
        width: Math.min(parent.width - MailStyle.space(48), MailStyle.space(480))
        runtime: root.service ? root.service.backendRuntime || null : null
        backendError: root.service && root.service.backend ? root.service.backend.failure : ""
        diagnosisAvailable: !!root.service && root.service.hasAgent === true
          && typeof root.service.diagnoseError === "function"
        diagnosing: !!root.service && !!root.service.diagnosing
        onDiagnosisRequested: root.service.diagnoseError()
        textColor: root.foreground
        dimColor: root.dim
        accentColor: root.accent
        panelFontFamily: root.fontFamily
      }
    }

    FocusScope {
      id: focusScope
      enabled: (!root.backendUnavailable || root.showSettings) && !root.restartBusy
      anchors.fill: parent
      anchors.margins: MailStyle.space(6)
      focus: true

      // Invariant: A modifier alone cannot use Shortcut; observe Ctrl without accepting its key events.
      // Invariant: Clear Ctrl state on focus loss because its release may arrive in another window.
      property bool ctrlDown: false
      readonly property bool ctrlHeld: ctrlDown && activeFocus
        && (keyContext === "list" || keyContext === "reader")

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Control) focusScope.ctrlDown = true
      }
      Keys.onReleased: function(event) {
        if (event.key === Qt.Key_Control) focusScope.ctrlDown = false
      }
      onActiveFocusChanged: if (!activeFocus) ctrlDown = false

      readonly property string keyContext: Keymap.contextFor(({
        assistantEditing: root.assistantOpen && root.assistantEditing,
        assistantCommands: !!root.activeAssistant && root.activeAssistant.commandsOpen,
        showPage: root.showPage,
        composing: root.composing,
        eventComposing: eventComposer.opened,
        guestSuggestions: eventComposer.guestSuggestionsOpen,
        searchFocused: searchBar.fieldFocused,
        searchSuggestions: searchBar.suggestionsOpen,
        calendarVisible: root.calendarVisible,
        currentView: root.currentView,
        sendPending: !!root.service && root.service.sendPending
      }))

      onKeyContextChanged: Qt.callLater(applyContextFocus)
      function focusWithin(container) {
        var item = focusScope.Window.activeFocusItem
        while (item) { if (item === container) return true; item = item.parent }
        return false
      }
      function applyContextFocus() {
        if (composeExitDialog.opened || searchBar.helpOpened || searchBar.controlsFocused) return
        if ((keyContext === "list" || keyContext === "reader")
            && statusViewport.visible && focusWithin(statusViewport)) return
        if (keyContext === "assistant" || keyContext === "assistantCommands") {
          if (composeAgent.opened && !composeAgent.activeFocus) composeAgent.takeFocus()
          else if (agentPrompt.opened && !agentPrompt.activeFocus) agentPrompt.takeFocus()
        }
        else if (keyContext === "eventCompose" || keyContext === "eventGuests") {
          if (!focusWithin(eventComposer)) eventComposer.takeFocus()
        }
        else if (keyContext === "compose") {
          if (focusWithin(compose)) return
          if (eventComposer.opened) eventComposer.takeFocus()
          else compose.takeFocus()
        }
        else if (keyContext === "search" || keyContext === "searchSuggestions") searchBar.takeFocus()
        else parkKeyboard()
      }

      // Invariant: Focusing a FocusScope reselects its current field; use a plain Item to release that field's focus.
      function parkKeyboard() {
        keyboardHome.forceActiveFocus()
      }

      Item {
        id: keyboardHome
        width: 1
        height: 1
      }


      Item {
        id: header
        objectName: "app-title-bar"
        readonly property bool searchVisible: !root.showPage && !root.composing && !root.calendarVisible
        readonly property bool searchStacked: searchVisible
          && width - headerLeft.width - headerRight.width - MailStyle.space(52) < MailStyle.space(220)
        readonly property real topRowHeight: Math.max(MailStyle.space(48),headerLeft.height + MailStyle.space(12),headerRight.height + MailStyle.space(12))
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: calendarHeaderSlot.visible && calendarHeaderSlot.stacked
          ? MailStyle.space(60) + calendarView.toolbarHeight
          : searchStacked ? topRowHeight + searchBar.implicitHeight + MailStyle.space(16)
          : Math.max(topRowHeight,calendarHeaderSlot.visible ? calendarView.toolbarHeight + MailStyle.space(12) : 0)
        visible: !root.composing

        WindowMoveArea {
          anchors.fill: parent
          enabled: root.standaloneWindowChrome
          nativeWindow: header.Window.window
        }

        Row {
          id: headerLeft
          anchors.left: parent.left
          anchors.leftMargin: MailStyle.space(14)
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: calendarHeaderSlot.visible && calendarHeaderSlot.stacked ? (MailStyle.space(48) - header.height) / 2
            : header.searchStacked ? (header.topRowHeight - header.height) / 2 : 0
          spacing: MailStyle.space(8)

          IconButton {
            id: menuButton
            objectName: "app-menu-button"
            iconSize: Style.font.icon * 2
            anchors.verticalCenter: parent.verticalCenter
            iconName: "menu"
            tooltipText: "Menu"
            foreground: root.dim
            hoverColor: root.foreground
            fontFamily: root.fontFamily
            selected: appMenu.opened
            onClicked: {
              var scene = mapToGlobal(0, height)
              appMenu.openAt(scene.x, scene.y)
            }
          }

          Widgets.Button {
            objectName: "reader-back-button"
            anchors.verticalCenter: parent.verticalCenter
            visible: root.singleContent && root.currentView === "reader"
              && !root.showPage && !root.composing && !root.calendarVisible
            text: "← Back"
            Accessible.name: "Back"
            tooltipText: "Back · esc"
            foreground: root.dim
            bordered: true
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: MailStyle.caption
            focusable: true
            onClicked: root.back()
          }
        }

        // Invariant: Search uses the space between control clusters, whose widths can differ.
        Item {
          id: searchSlot
          anchors.left: header.searchStacked ? parent.left : headerLeft.right
          anchors.right: header.searchStacked ? parent.right : headerRight.left
          anchors.leftMargin: MailStyle.space(14)
          anchors.rightMargin: MailStyle.space(14)
          y: header.searchStacked ? header.topRowHeight + MailStyle.space(4) : (header.topRowHeight - height) / 2
          height: searchBar.implicitHeight

          SearchBar {
            id: searchBar
            objectName: "search-bar"
            anchors.verticalCenter: parent.verticalCenter
            // Invariant: Center search on the header, then clamp it to the available slot to avoid overlapping controls.
            x: header.searchStacked ? 0 : Math.max(0, Math.min(parent.width - width,
              (header.width - width) / 2 - parent.x))
            width: header.searchStacked ? parent.width : Math.min(MailStyle.space(340),parent.width)
            visible: header.searchVisible
          textColor: root.foreground
          accentColor: root.accent
          dimColor: root.dim
          popupBackgroundColor: root.popupBackground
          popupBorderColor: root.popupBorder
          panelFontFamily: root.fontFamily
          overlayParent: focusScope
          assistanceAvailable: !!root.service && root.service.searchAssistanceAvailable === true
          operators: root.service && root.service.searchOperators ? root.service.searchOperators : []
          labels: root.service && root.service.searchLabels ? root.service.searchLabels : []
          serverSearching: !!root.service && root.service.serverSearchLoading === true && !assistanceAvailable
          onKeyPressed: function(event) { keyRouter.routeKeyEvent(event) }
          // Invariant: Search replaces the list and invalidates its open reader history.
          onSubmitted: function(query) {
            if (!root.service) return
            root.service.search(query)
            root.backToList()
          }
          onCleared: {
            if (!root.service) return
            root.service.search("")
            root.backToList()
          }
          }
        }

        Item {
          id: calendarHeaderSlot
          objectName: "calendar-header-slot"
          readonly property bool stacked: header.width < MailStyle.space(1100)
          visible: root.calendarVisible && !root.showPage && !root.composing && !calendarView.detailOpen
          x: stacked ? MailStyle.space(14) : headerLeft.x + headerLeft.width + MailStyle.space(20)
          y: stacked ? MailStyle.space(48) : (header.height - height) / 2
          width: Math.max(0, (stacked ? header.width - MailStyle.space(14) : headerRight.x - MailStyle.space(20)) - x)
          height: calendarView.toolbarHeight
        }

        Row {
          id: headerRight
          anchors.right: parent.right
          anchors.rightMargin: MailStyle.space(14)
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: calendarHeaderSlot.visible && calendarHeaderSlot.stacked ? (MailStyle.space(48) - header.height) / 2
            : header.searchStacked ? (header.topRowHeight - header.height) / 2 : 0
          spacing: MailStyle.space(8)

          Widgets.Button {
            id: folderButton
            objectName: "folder-button"
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.showPage && !root.composing && !root.calendarVisible
            text: folderNameMetrics.elidedText
            Accessible.name: folderNameMetrics.text
            bordered: true
            tooltipText: folderNameMetrics.text + " · " + (root.foldersVisible ? "Hide folders" : "Show folders")
            tooltipMaximumWidth: Math.max(1, Math.min(MailStyle.space(320), window.width - MailStyle.space(32)))
            tooltipBelow: true
            foreground: root.dim
            accent: root.accent
            selected: root.foldersVisible
            fontFamily: root.fontFamily
            fontSize: MailStyle.caption
            focusable: true
            onClicked: root.foldersVisible = !root.foldersVisible

            TextMetrics {
              id: folderNameMetrics
              text: Model.currentFolderName(root.service)
              font.family: folderButton.fontFamily
              font.pixelSize: folderButton.fontSize
              font.bold: folderButton.selected
              elide: Text.ElideMiddle
              elideWidth: Math.max(MailStyle.space(36), Math.min(MailStyle.space(160),
                header.width - headerLeft.width - headerComposeButton.width - MailStyle.space(90)
                  - folderButton.horizontalPadding * 2))
            }
          }

          Widgets.Button {
            id: headerComposeButton
            objectName: "compose-button"
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.showPage && !root.composing && !root.calendarVisible
            text: "Compose"
            tooltipText: "Compose · c"
            foreground: root.dim
            bordered: true
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: MailStyle.caption
            enabled: root.ready
            onClicked: root.startCompose("new")
          }

          Widgets.Button {
            id: headerAccountButton
            parent: !root.calendarVisible && root.currentView === "list" ? headerLeft : headerRight
            objectName: "header-account-button"
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.showPage && !root.composing
            text: root.service && root.service.unified ? "All" : ""
            width: Math.max(implicitWidth, headerComposeButton.implicitHeight)
            height: headerComposeButton.implicitHeight
            foreground: root.dim
            bordered: true
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: MailStyle.caption
            focusable: true
            selected: accountSwitcher.opened
            tooltipText: "Choose mailboxes... · Alt+A"
            Accessible.name: root.service && root.service.unified ? "All mailboxes" : root.service ? root.service.accountEmail : "Choose mailboxes"
            ActionIcon {
              anchors.centerIn: parent
              visible: !root.service || !root.service.unified
              name: MailboxIdentity.icon(root.service ? root.service.accountLabel : "")
              iconSize: Style.font.icon
              color: root.foreground
            }
            onClicked: { var scene = mapToGlobal(0, height); accountSwitcher.openAt(scene.x, scene.y) }
          }


        }

        PanelSeparator {
          anchors.bottom: parent.bottom
          width: parent.width
          foreground: root.foreground
        }
      }

      Item {
        id: composeAiSlot
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(14)
        height: MailStyle.space(44)
        width: MailStyle.space(32)
        visible: root.composing
        z: 30
        IconButton {
          objectName: "compose-menu-button"
          anchors.centerIn: parent
          iconName: "menu"
          tooltipText: "Menu"
          foreground: root.foreground
          fontFamily: root.fontFamily
          selected: appMenu.opened
          onClicked: { var scene = mapToGlobal(0,height); appMenu.openAt(scene.x,scene.y) }
        }
      }


      Item {
        id: body
        anchors.rightMargin: root.assistantWidth
        anchors.top: header.visible ? header.bottom : parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        MailboxSidebar {
          id: sidebar
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: root.sidebarCollapsed ? MailStyle.space(44)
            : (root.sidebarWidth > 0
              ? Math.max(root.sidebarMinWidth, Math.min(root.sidebarMaxWidth, root.sidebarWidth))
              : MailStyle.space(148))
          visible: root.foldersVisible && !root.singleContent && !root.showPage && !root.composing
          collapsed: root.sidebarCollapsed
          calendarSelected: root.calendarVisible
          menuLabelPath: labelMenu.opened && !!root.service
            && labelMenu.accountId === root.service.activeAccountId ? labelMenu.labelPath : ""
          service: root.service
          textColor: root.foreground
          accentColor: root.accent
          dimColor: root.dim
          panelFontFamily: root.fontFamily
          slots: root.sidebarSlots
          numbersVisible: focusScope.ctrlHeld
          onMailboxSelected: function(key) { root.goMailbox(key) }
          onCalendarRequested: {
            root.showCalendar()
            calendarView.refresh()
          }
          // Invariant: Label selection keeps the Gmail label ID with its display name.
          onLabelSelected: function(labelId, name) {
            searchBar.setQuery("")
            root.service.selectLabel(name, labelId)
            root.backToList()
          }
          onFolderToggled: function(path) { root.service.toggleFolder(path) }
          onLabelMenuRequested: function(labelId, path, sceneX, sceneY) {
            root.openLabelMenu(labelId, path, sceneX, sceneY)
          }
        }

        MailboxTabs {
          id: tabs
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: MailStyle.space(14)
          visible: root.foldersVisible && root.singleContent && !root.showPage && !root.composing && root.currentView === "list"
          textColor: root.foreground
          accentColor: root.accent
          panelFontFamily: root.fontFamily
          // Invariant: Compact tabs and the sidebar use the same provider mailbox list.
          allMailboxes: root.service ? root.service.mailboxes : []
          current: root.service ? root.service.mailboxKey : "inbox"
          unread: root.service ? root.service.inboxUnread : 0
          onSelected: function(key) { root.goMailbox(key) }
        }

        Item {
          id: sidebarSplitter
          anchors.left: sidebar.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: MailStyle.space(5)
          visible: sidebar.visible && !root.sidebarCollapsed
          z: 5

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.SplitHCursor
            property real grabbedAt: 0
            property real grabbedWidth: 0

            onPressed: function(mouse) {
              grabbedAt = mapToItem(body, mouse.x, mouse.y).x
              grabbedWidth = sidebar.width
            }
            onPositionChanged: function(mouse) {
              if (!pressed) return
              var moved = mapToItem(body, mouse.x, mouse.y).x - grabbedAt
              root.sidebarWidth = Math.max(root.sidebarMinWidth,
                Math.min(root.sidebarMaxWidth, grabbedWidth + moved))
            }
            onReleased: root.persistPaneWidths()
            onDoubleClicked: {
              root.sidebarWidth = 0
              root.persistPaneWidths()
            }
          }
        }

        Item {
          id: listColumn
          // Invariant: The splitter hit target overlaps the list edge so it adds no gap before row selection controls.
          anchors.left: sidebar.visible ? sidebar.right : parent.left
          anchors.top: tabs.visible ? tabs.bottom : parent.top
          anchors.bottom: parent.bottom
          anchors.topMargin: tabs.visible ? MailStyle.space(8) : 0
          width: root.singleContent
            ? (root.currentView === "list" ? parent.width : 0)
            : Math.max(MailStyle.space(100),
                Math.min(parent.width - (sidebar.visible ? sidebar.width : 0)
                  - listSplitter.width - MailStyle.space(200),
                  root.listWidth > 0 ? root.listWidth
                    : Math.min(MailStyle.space(460), Math.round(parent.width * 0.34))))
          visible: width > 0 && !root.showPage && !root.composing
            && !root.calendarVisible

          Flickable {
            id: statusViewport
            objectName: "mail-status-viewport"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: MailStyle.space(8)
            height: Math.min(contentHeight,Math.max(0,listColumn.height * 0.45))
            contentHeight: statusContents.implicitHeight
            onContentHeightChanged: Qt.callLater(revealFocusedControl)
            onHeightChanged: Qt.callLater(revealFocusedControl)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            function revealFocusedControl() {
              var focused = statusViewport.Window.activeFocusItem
              var ancestor = focused
              while (ancestor && ancestor !== statusContents) ancestor = ancestor.parent
              if (!ancestor || !focused) return
              var top = focused.mapToItem(statusContents,0,0).y
              var bottom = top + focused.height
              if (top < contentY) contentY = top
              else if (bottom > contentY + height) contentY = Math.max(0,Math.min(contentHeight - height,bottom - height))
            }
            Connections {
              target: statusViewport.Window.window
              function onActiveFocusItemChanged() { statusViewport.revealFocusedControl() }
            }
            Column {
              id: statusContents
              width: statusViewport.width - MailStyle.space(8)
              spacing: MailStyle.space(8)
              LocalMailStatus {
                id: localStatus
                width: parent.width
                mailbox: root.service.localMailbox || null
                searchActive: searchStatus.visible
                textColor: root.foreground
                dimColor: root.dim
                panelFontFamily: MailStyle.listFamily
              }
              Search.SearchStatus {
                id: searchStatus
                width: parent.width
                service: root.service
                textColor: root.foreground
                accentColor: root.accent
                dimColor: root.dim
                panelFontFamily: MailStyle.listFamily
              }
            }
          }
          MessageList {
              id: list
              anchors.top: statusViewport.height > 0 ? statusViewport.bottom : parent.top
              anchors.topMargin: statusViewport.height > 0 ? MailStyle.space(6) : 0
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              WheelScroller { view: list }
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
              service: root.service
              textColor: root.foreground
              accentColor: root.accent
              dimColor: root.dim
              panelFontFamily: MailStyle.listFamily
              cursorId: root.cursorId
              checkedIds: root.checkedIds
              ctrlHeld: focusScope.ctrlHeld
              urgentColor: root.urgent
              onMessageActivated: function(id) { root.openMessage(id) }
              onAgentRequested: function(id, sceneX, sceneY) { root.openAgentFromRow(id, sceneX, sceneY) }
              onSnoozeRequested: function(id,sceneX,sceneY) { snoozePicker.openAt(id,sceneX,sceneY) }
              snoozeId: snoozePicker.opened ? snoozePicker.messageId : ""
              onRowActionRequested: function(id, action) { root.actFromRow(id, action) }
              onCheckToggled: function(id) { root.toggleCheck(id) }
              onCheckRangeRequested: function(id) { root.checkRange(id) }
              onMenuRequested: function(id, sceneX, sceneY) {
                root.cursorId = id
                rowMenu.openAt(id, sceneX, sceneY)
              }
            }

        }

        // Invariant: The divider hit target is wider than its visible line.
        Item {
          id: listSplitter
          anchors.left: listColumn.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: MailStyle.space(5)
          visible: listColumn.visible && !root.singleContent
          z: 5

          PanelSeparator {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            foreground: root.foreground
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.SplitHCursor
            property real grabbedAt: 0
            property real grabbedWidth: 0

            onPressed: function(mouse) {
              grabbedAt = mapToItem(body, mouse.x, mouse.y).x
              grabbedWidth = listColumn.width
            }
            onPositionChanged: function(mouse) {
              if (!pressed) return
              var moved = mapToItem(body, mouse.x, mouse.y).x - grabbedAt
              root.listWidth = grabbedWidth + moved
            }
            onReleased: root.persistPaneWidths()
            onDoubleClicked: {
              root.listWidth = 0
              root.persistPaneWidths()
            }
          }
        }

        MessageReader {
          id: reader
          anchors.left: listSplitter.visible ? listSplitter.right : parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          visible: !root.showPage && !root.composing && !root.calendarVisible
            && (!root.singleContent || root.currentView === "reader")
          service: root.service
          textColor: root.foreground
          backgroundColor: root.background
          accentColor: root.accent
          linkColor: root.link
          dimColor: root.dim
          dimmerColor: root.dimmer
          popupBackgroundColor: root.popupBackground
          popupBorderColor: root.popupBorder
          leadingBoundaryOverlap: listSplitter.visible ? listSplitter.width : 0
          panelFontFamily: root.fontFamily
          zoom: root.bodyZoom
          bodyMode: root.bodyMode
          alwaysRenderHeavyMessages: !!root.service && root.service.alwaysRenderHeavyMessages
          contentDirection: root.service ? root.service.contentDirection : ""
          onBodyModeRequested: function(mode) {
            if (root.service) root.service.setBodyMode(mode)
          }
          onZoomRequested: function(step) { root.zoomBy(step) }
          onZoomResetRequested: if (root.service) root.service.setBodyZoom(1.0)
          onMemberRequested: function(id) { root.openMember(id) }
          onMemberMenuRequested: function(id, sceneX, sceneY) {
            rowMenu.openForMember(id, sceneX, sceneY)
          }
          onSnoozeRequested: function(sceneX,sceneY) { snoozePicker.openAt(root.service.selectedId,sceneX,sceneY) }
          onComposeRequested: function(mode) {
            if (mode === "draft" && root.service) root.editDraft(root.service.selectedId)
            else root.startCompose(mode)
          }
          onMailtoRequested: function(url) {
            root.openDraft(Mailto.parse(url))
          }
          onAgentRequested: function(sceneX, sceneY) { root.openAgentAt(root.service.selectedId, sceneX, sceneY) }
          agentOpen: agentPrompt.opened && !!root.service && agentPrompt.messageId === root.service.selectedId
          agentWorking: !!root.service && root.service.selectedId !== ""
            && Agent.isActive((root.service.agentJobs || {})[root.service.selectedId])
          agentAttention: !!root.service && root.service.selectedId !== ""
            && (root.service.agentAttentionByMessage || {})[root.service.selectedId] === true
          onAddressMenuRequested: function(addresses, sceneX, sceneY) {
            addressMenu.openAt(addresses, sceneX, sceneY)
          }
          onActionRequested: function(action) {
            if (!root.service || root.service.selectedId === "") return
            // Invariant: Conversation members have no list row; toolbar actions keep the list cursor on the conversation representative.
            var outside = root.checkedIds.indexOf(root.service.selectedId) < 0
            // Invariant: Star the open member unless it belongs to the visible selection; preserve the list cursor.
            if (action === "star") {
              if (root.selectionActive && !outside)
                root.actOnChecked(Model.starActionFor(Model.summariesById(
                    root.service.messages, root.checkedIds)))
              else
                root.service.toggleStar(root.service.selectedId)
              return
            }
            if (((root.service.conversationProjection || ({})).memberIds || []).indexOf(root.service.selectedId) < 0
                || root.cursorId === "")
              root.cursorId = root.service.selectedId
            if (action === "moveToLabel") return root.openLabelPicker(outside)
            root.actOnCursor(action, outside)
          }
        }

        // Invariant: Compose stays in this window; a second Omarchy panel would receive a separate region.
        ComposeView {
          id: compose
          anchors.fill: parent
          visible: opened && !root.showPage
          agentOpen: composeAgent.opened
          agentWorking: composeAgent.working
          agentAttention: !!root.service && !!root.service.hasAgent
            && root.service.agentJobWantsAttention(composeAgent.job) && !composeAgent.opened
          onAgentRequested: function(sceneX, sceneY) { composeAgent.openAt(sceneX, sceneY) }
          service: root.service
          textColor: root.foreground
          backgroundColor: root.background
          accentColor: root.accent
          dimColor: root.dim
          dimmerColor: root.dimmer
          popupBackgroundColor: root.popupBackground
          popupBorderColor: root.popupBorder
          panelFontFamily: root.fontFamily
          contentDirection: root.service ? root.service.contentDirection : ""
          // Invariant: Parked sends close without emitting closed; navigation follows opened.
          onOpenedChanged: {
            if (opened) root.trackComposeOpened()
            else root.leaveCompose()
          }
          onClosed: {
            if (!root.composeDetachingForSave) root.clearComposeRecovery()
          }
          onCloseRequested: root.requestLeaveCompose()
          onSendQueued: {
            root.saveComposeRecovery(compose.pendingDraft)
            root.backToList()
          }
          onDraftChanged: root.scheduleComposeRecovery()
        }

        CalendarEventComposer {
          id: eventComposer
          anchors.fill: parent
          z: 20
          visible: opened && !root.showPage
          onOpenedChanged: {
            if (opened) root.pushEntry("eventComposer", {})
            else root.dropOverlay("eventComposer")
          }
          controller: root.service ? root.service.calendarController : null
          textColor: root.foreground
          backgroundColor: root.background
          accentColor: root.accent
          urgentColor: root.urgent
          dimColor: root.dim
          panelFontFamily: root.fontFamily
        }


        Rectangle {
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.left: sidebarSplitter.visible ? sidebarSplitter.right
            : (sidebar.visible ? sidebar.right : parent.left)
          visible: root.calendarVisible && !root.showPage && !root.composing
          color: root.background
          z: 10

          CalendarView {
            toolbarHost: calendarHeaderSlot
            id: calendarView
            anchors.fill: parent
            controller: root.service ? root.service.calendarController : null
            textColor: root.foreground
            backgroundColor: root.background
            accentColor: root.accent
            urgentColor: root.urgent
            dimColor: root.dim
            calendarBorderColor: root.calendarBorder
            calendarTodayBackgroundColor: root.calendarTodayBackground
            calendarBorderWidth: root.calendarBorderWidth
            panelFontFamily: root.fontFamily
            // Invariant: CalendarView owns detail open state; navigation follows it so Back closes detail first.
            onDetailOpenChanged: {
              if (detailOpen) { if (root.page !== "calendarDetail") root.pushEntry("calendarDetail", {}) }
              else if (root.page === "calendarDetail") { root.navUntouched = false; root.nav = Nav.pop(root.nav) }
            }
            onCreateAt: function(startMs) { eventComposer.beginAt(startMs) }
            onEditRequested: function(sourceId, event) { eventComposer.beginEdit(sourceId, event) }
            onDeleteRequested: function(sourceId, event) { root.requestEventDelete(sourceId, event) }
          }
        }

        BackBar {
          id: pageBack
          objectName: "page-back"
          // Invariant: Keep the Back hit target above the full-height Settings viewport.
          z: 2
          parent: root.showSettings && root.compact ? settingsHolder : body
          x: (root.showSettings && root.compact ? 0 : MailStyle.space(18))
            + (root.showSettings ? settingsArea.blockLeft : setup.x)
          anchors.top: parent.top
          anchors.topMargin: MailStyle.space(18)
          visible: root.showPage && Nav.depth(root.nav) > 1
          textColor: root.foreground
          dimColor: root.dim
          panelFontFamily: root.fontFamily
          onActivated: root.back()
        }
        readonly property real pageTop: MailStyle.space(18)
          + (pageBack.visible ? pageBack.height + MailStyle.space(16) : 0)

        Flickable {
          id: setupFlick

          WheelScroller { view: setupFlick }
          anchors.fill: parent
          anchors.margins: MailStyle.space(18)
          anchors.topMargin: parent.pageTop
          visible: root.showSetup
          contentWidth: width
          contentHeight: setupHolder.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          onContentHeightChanged: Qt.callLater(revealFocusedControl)
          onHeightChanged: Qt.callLater(revealFocusedControl)
          function revealFocusedControl() {
            if (!visible) return
            var focused = setupFlick.Window.activeFocusItem
            var ancestor = focused
            while (ancestor && ancestor !== setupHolder) ancestor = ancestor.parent
            if (!ancestor || !focused) return
            var top = focused.mapToItem(setupHolder, 0, 0).y
            var bottom = top + focused.height
            if (top < contentY) contentY = top
            else if (bottom > contentY + height)
              contentY = Math.max(0, Math.min(contentHeight - height, bottom - height))
          }
          Connections {
            target: setupFlick.Window.window
            function onActiveFocusItemChanged() { setupFlick.revealFocusedControl() }
          }


          // Invariant: Flickable reparents children; center against a viewport-sized holder to avoid transient parent geometry.
          Item {
            id: setupHolder
            width: setupFlick.width
            implicitHeight: setup.implicitHeight

          // Invariant: Load one setup page at a time so inactive provider forms retain no fields or state.
          Loader {
            id: setup
            objectName: "setup-page"
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(setupHolder.width, MailStyle.space(560))
            sourceComponent: gmailSetupPage
          }
          }
        }

        Item {
          id: settingsArea
          anchors.fill: parent
          anchors.leftMargin: MailStyle.space(18)
          anchors.rightMargin: MailStyle.space(18)
          visible: root.showSettings

          readonly property real railWidth: settingsRail.visible
            ? settingsRail.width + MailStyle.space(18) : 0
          readonly property real pageWidth: Math.min(width - railWidth, MailStyle.space(560))
          readonly property real blockLeft: Math.max(0, (width - railWidth - pageWidth) / 2)

          SettingsSidebar {
            id: settingsRail
            objectName: "settings-sidebar"
            visible: !root.compact
            // Invariant: Keep the rail above the full-block Flickable so it receives clicks.
            z: 1
            x: settingsArea.blockLeft
            anchors.top: parent.top
            anchors.topMargin: body.pageTop
            width: MailStyle.space(176)
            sections: settings.sections
            activeKey: Model.activeSettingsSection(settings.sections, settingsFlick.contentY)
            textColor: root.foreground
            dimColor: root.dim
            accentColor: root.accent
            panelFontFamily: root.fontFamily
            onSectionRequested: function(key) {
              var target = Model.settingsScrollTarget(settings.sections, key,
                settingsFlick.contentHeight, settingsFlick.height)
              if (target < 0) return
              settingsScroll.stop()
              settingsScroll.to = target
              settingsScroll.start()
            }
          }

          // Performance: Animate section navigation only; a Behavior on contentY would also delay wheel scrolling.
          NumberAnimation {
            id: settingsScroll
            target: settingsFlick
            property: "contentY"
            duration: 160
            easing.type: Easing.OutQuad
          }

        Flickable {
          id: settingsFlick

          WheelScroller { view: settingsFlick }
          // Invariant: The viewport spans the rail so wheel input anywhere in the block scrolls Settings.
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          contentWidth: width
          contentHeight: settingsHolder.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Item {
            id: settingsHolder
            width: settingsFlick.width
            // Invariant: Bottom padding lets the last section align with the top after rail navigation.
            implicitHeight: body.pageTop + Model.settingsContentHeight(settings.sections,
              settings.implicitHeight, Math.max(0, settingsFlick.height - body.pageTop))

            SettingsPage {
              id: settings
              objectName: "settings-page"
              // Invariant: Initial spacing scrolls with content; clipping starts at the header.
              y: body.pageTop
              x: settingsArea.blockLeft + settingsArea.railWidth
              width: settingsArea.pageWidth
              service: root.service
              calendarController: root.service ? root.service.calendarController : null
              textColor: root.foreground
              dimColor: root.dim
              accentColor: root.accent
              urgentColor: root.urgent
              panelFontFamily: root.fontFamily
              restartBusy: root.restartBusy
              restartStatus: root.restartStatus
              restartFailed: root.restartFailed
              onRestartRequested: root.requestRestart()
              onClientSetupRequested: root.openClientSetup()
              onCalendarSignInRequested: function(index) {
                if (root.editAccount(index)) root.service.signIn()
              }
              onOpenCalendarRequested: {
                root.showCalendar()
                calendarView.refresh()
              }
              onAddRequested: root.addMailbox()
              onEditRequested: function(index) { root.editAccount(index) }
            }
          }
        }
        }
      }

      UndoSendToast {
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(16)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: MailStyle.space(12)
        z: 80
        visible: !!root.service && root.service.sendPending && compose.parkedForSend
        secondsRemaining: root.service ? root.service.sendSecondsRemaining : 0
        awaitingConnection: !!root.service && root.service.sendAwaitingConnection === true
        queuedCount: root.service && root.service.sendPendingCount !== undefined
          ? root.service.sendPendingCount : 1
        textColor: root.foreground
        dimColor: root.dim
        accentColor: root.accent
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        onUndoRequested: root.undoPendingSend()
      }

      DraftSavedToast {
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(16)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: MailStyle.space(12)
        z: 80
        visible: root.draftSavedNotice !== ""
        message: root.draftSavedNotice
        textColor: root.foreground
        accentColor: root.accent
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
      }

      Rectangle {
        id: statusBar
        objectName: "mail-notice"
        anchors.bottom: parent.bottom
        anchors.bottomMargin: compose.visible ? compose.actionBarHeight + MailStyle.space(8) : 0
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - MailStyle.space(28), MailStyle.space(720))
        height: visible ? noticeText.implicitHeight + MailStyle.space(16) : 0
        visible: noticeText.text !== ""
        z: 70
        radius: Style.cornerRadius
        color: root.popupBackground
        border.color: root.popupBorder
        IconButton {
          id: diagnoseErrorButton
          objectName: "diagnose-error-button"
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: !!root.service && root.service.hasAgent !== false && root.service.lastError !== "" && typeof root.service.diagnoseError === "function"
          enabled: visible && !root.service.diagnosing
          iconName: "agent"
          tooltipText: "Diagnose with AI..."
          foreground: root.urgent
          fontFamily: root.fontFamily
          onClicked: root.service.diagnoseError()
        }
        Text {
          id: noticeText
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: MailStyle.space(8)
          textFormat: Text.PlainText
          anchors.rightMargin: diagnoseErrorButton.visible ? diagnoseErrorButton.width + MailStyle.space(8) : MailStyle.space(8)
          text: root.notice || (root.service && root.service.inboxTools ? root.service.inboxTools.error || root.service.inboxTools.notice : "") || (root.service ? root.service.lastError || root.service.actionStatus || root.service.activityStatus || "" : "")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: MailStyle.caption
          wrapMode: Text.WordWrap
        }
      }

      SnoozePicker {
        id: snoozePicker
        textColor: root.foreground
        dimColor: root.dim
        accentColor: root.accent
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        tools: root.service ? root.service.inboxTools || null : null
        onSnoozed: function(id,until) { if (tools) tools.snooze(id,until) }
      }

      AppMenu {
        id: appMenu
        objectName: "app-menu"
        anchors.fill: parent
        textColor: root.foreground
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        signedIn: root.ready
        canOpenWebInbox: !!root.service && root.service.canOpenWebInbox
        accountCount: root.service ? root.service.accountCount : 1
        canQuit: root.standaloneWindowChrome
        singlePane: root.singlePane
        hasAgent: !!root.service && root.service.hasAgent !== false
        overviewsPaused: !!root.service && !!root.service.inboxTools && root.service.inboxTools.paused
        onRefreshImagesRequested: if (root.service && root.service.inboxTools) root.service.inboxTools.refreshAvatars()
        onOverviewPauseRequested: if (root.service && root.service.inboxTools) root.service.inboxTools.setPaused(!root.service.inboxTools.paused)
        onSnoozedRequested: snoozePicker.openScheduled()
        onLayoutRequested: if (root.service) root.service.setDisplayPreference("layout", root.singlePane ? "Split view" : "Single pane")
        onRefreshRequested: if (root.service) root.service.refresh()
        onAiRequested: root.runShortcut("askAgent", "Alt+G")
        onOverviewRetryRequested: if (root.service && root.service.inboxTools) root.service.inboxTools.retry()
        onMarkAllReadRequested: if (root.service) root.service.markAllRead()
        onOpenWebRequested: if (root.service) root.service.openWebInbox()
        onShortcutsRequested: root.openHelp()
        onInboxRequested: {
          root.backToList()
          if (root.service) root.service.selectMailbox("inbox")
        }
        onCalendarRequested: {
          root.showCalendar()
          calendarView.refresh()
        }
        onSetupRequested: root.openSettings()
        onSwitchAccountRequested: accountSwitcher.openCentered()
        onProjectRequested: if (root.service) root.service.openProjectPage()
        onAuthorRequested: if (root.service) root.service.openAuthorPage()
        onQuitRequested: {
          if (root.standaloneWindowChrome && root.shell
              && typeof root.shell.quit === "function") root.shell.quit()
        }
      }

      Timer {
        id: noticeTimer
        interval: 6000
        onTriggered: root.notice = ""
      }

      AccountSwitcher {
        id: accountSwitcher
        anchors.fill: parent
        textColor: root.foreground
        accentColor: root.accent
        urgentColor: root.urgent
        dimColor: root.dim
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        accounts: root.service ? root.service.accountSummaries : []
        unifiedActive: !!root.service && root.service.unified
        onAccountChosen: function(index) {
          root.switchAccount(index)
        }
        onUnifiedChosen: root.chooseUnified()
        onAddAccountRequested: root.addMailbox()
        onManageRequested: {
          root.openSettings()
        }
      }

      Item {
        id: assistantDock
        objectName: "assistant-dock"
        anchors.right: parent.right
        anchors.top: root.composing ? composeAiSlot.bottom : header.bottom
        anchors.bottom: parent.bottom
        width: root.assistantWidth
        visible: root.assistantOpen
        MouseArea {
          objectName: "assistant-splitter"
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: MailStyle.space(5)
          z: 100
          cursorShape: Qt.SplitHCursor
          property real grabbedAt: 0
          property real grabbedWidth: 0
          onPressed: function(mouse) {
            grabbedAt = mapToItem(focusScope, mouse.x, mouse.y).x
            grabbedWidth = root.assistantWidth
          }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            var moved = mapToItem(focusScope, mouse.x, mouse.y).x - grabbedAt
            root.preferredAssistantWidth = Math.max(root.assistantMinWidth,
              Math.min(root.assistantMaxWidth, grabbedWidth - moved))
          }
          onDoubleClicked: root.preferredAssistantWidth = 0
        }
        Loader {
          id: agentPromptLoader
          active: !!root.service && root.service.hasAgent !== false
          anchors.fill: parent
          sourceComponent: Component {
            AgentPrompt {
              proposalComposer: compose
              onApplyProposalRequested: function(envelope, parentId) {
                compose.beginProposal(envelope, parentId)
                Qt.callLater(function() { root.composeAgent.open() })
              }
              onOpenedChanged: if (opened) root.composeAgent.close()
              objectName: "agent-prompt"
              service: root.service
              textColor: root.foreground
              accentColor: root.accent
              urgentColor: root.urgent
              dimColor: root.dim
              popupBackgroundColor: root.popupBackground
              popupBorderColor: root.popupBorder
              panelFontFamily: root.fontFamily
              onFocusRequested: { root.assistantEditing = true; Qt.callLater(focusScope.applyContextFocus) }
              onKeyPressed: function(event) { keyRouter.routeKeyEvent(event) }
              onEditingChanged: function(editing) { root.assistantEditing = editing }
              onDismissed: { root.assistantEditing = false; Qt.callLater(focusScope.applyContextFocus) }
            }
          }
        }

        Loader {
          id: composeAgentLoader
          active: !!root.service && root.service.hasAgent !== false
          anchors.fill: parent
          sourceComponent: Component {
            ComposeAgent {
              onOpenedChanged: if (opened) root.agentPrompt.close()
              objectName: "compose-agent"
              service: root.service
              composer: compose
              textColor: root.foreground
              accentColor: root.accent
              urgentColor: root.urgent
              dimColor: root.dim
              popupBackgroundColor: root.popupBackground
              popupBorderColor: root.popupBorder
              panelFontFamily: root.fontFamily
              onFocusRequested: { root.assistantEditing = true; Qt.callLater(focusScope.applyContextFocus) }
              onKeyPressed: function(event) { keyRouter.routeKeyEvent(event) }
              onEditingChanged: function(editing) { root.assistantEditing = editing }
              onDismissed: { root.assistantEditing = false; Qt.callLater(focusScope.applyContextFocus) }
            }
          }
        }
      }

      LabelMenu {
        id: labelMenu
        objectName: "label-menu"
        anchors.fill: parent
        textColor: root.foreground
        urgentColor: root.urgent
        dimColor: root.dim
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        onRenameRequested: function(labelId) {
          var owner = labelMenu.accountId
          var path = root.labelPathFor(labelId, owner)
          root.askLabelName("rename", labelId, "Rename " + path,
            Model.labelLeaf(path), "The new name for this label. Labels beneath it move with it.", owner)
        }
        onCreateRequested: function(path, beneath) {
          var owner = labelMenu.accountId
          var parent = beneath ? path : Model.labelParent(path)
          root.askLabelName("create", parent,
            parent === "" ? "New label" : "New label under " + parent, "",
            "Its name at this level; nesting is the parent it goes under.", owner)
        }
        onMoveRequested: function(labelId) {
          var owner = labelMenu.accountId
          labelMovePicker.accountId = owner
          labelMovePicker.openFor(labelId,
            Model.labelMoveTargets(root.service ? root.service.labelsOf(owner) : [], root.labelPathFor(labelId, owner)))
        }
        onMonitorToggled: function(labelId) { if (root.service) root.service.toggleMonitored(labelId, labelMenu.accountId) }
        onDeleteRequested: function(labelId) {
          var owner = labelMenu.accountId
          var path = root.labelPathFor(labelId, owner)
          confirmDeleteDialog.openFor({
            kind: "label", labelId: labelId, name: path, accountId: owner,
            message: "The label and every label beneath it are removed from the server. "
              + "The messages keep their other labels."
          })
        }
      }

      NamePrompt {
        id: namePrompt
        objectName: "name-prompt"
        anchors.fill: parent
        textColor: root.foreground
        dimColor: root.dim
        accentColor: root.accent
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        onSubmitted: function(kind, subject, text) { root.labelNamed(kind, subject, text, namePrompt.accountId) }
      }

      LabelMovePicker {
        id: labelMovePicker
        objectName: "label-move-picker"
        anchors.fill: parent
        textColor: root.foreground
        accentColor: root.accent
        dimColor: root.dim
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        onTargetChosen: function(labelId, parentPath) {
          if (root.service) root.service.moveLabel(labelId, parentPath, labelMovePicker.accountId)
        }
      }

      AddressMenu {
        id: addressMenu
        objectName: "address-menu"
        anchors.fill: parent
        textColor: root.foreground
        dimColor: root.dim
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        canSearch: !!root.service
        onCopyRequested: function(address) { root.copyAddress(address) }
        onSearchRequested: function(field, address) { root.searchAddress(field, address) }
      }

      LabelPicker {
        id: labelPicker
        objectName: "label-picker"
        anchors.fill: parent
        textColor: root.foreground
        accentColor: root.accent
        dimColor: root.dim
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        labels: root.service ? root.service.labels : []
        currentLabelId: root.service ? String(root.service.rawLabelId || "") : ""
        onLabelChosen: function(labelId) {
          root.actOnCursor("label:" + labelId, root.labelPickerOnlyCursor)
        }
      }

      ComposeExitDialog {
        id: composeExitDialog
        objectName: "compose-exit-dialog"
        currentDraftKey: compose.opened ? compose.draftKey : ""
        textColor: root.foreground
        dimColor: root.dim
        dangerColor: root.urgent
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        onSaveRequested: function(draftKey) {
          if (compose.opened && compose.draftKey === draftKey) root.saveAndLeaveCompose(true)
        }
        onDiscardRequested: function(draftKey) {
          if (compose.opened && compose.draftKey === draftKey) compose.finish()
        }
      }

      AccountRemovalDialog {
        id: accountRemovalDialog
        anchors.fill: parent
        textColor: root.foreground
        dimColor: root.dim
        dangerColor: root.danger
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        onConfirmed: function(request) { root.confirmAccountRemoval(request) }
      }

      ConfirmDeleteDialog {
        id: confirmDeleteDialog
        anchors.fill: parent
        textColor: root.foreground
        dimColor: root.dim
        dangerColor: root.danger
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        onConfirmed: function(request) { root.confirmDelete(request) }
      }

      MessageMenu {
        onAgentRequested: function(id, sceneX, sceneY) { root.openAgentAt(id, sceneX, sceneY) }
        id: rowMenu
        objectName: "rowMenu"
        service: root.service
        textColor: root.foreground
        urgentColor: root.urgent
        dimColor: root.dim
        popupBackgroundColor: root.popupBackground
        popupBorderColor: root.popupBorder
        panelFontFamily: root.fontFamily
        onComposeRequested: function(mode, id) {
          if (mode === "draft") { root.editDraft(id); return }
          root.pendingComposeReturnTo = Nav.depth(root.nav)
          root.openMessage(id)
          root.startCompose(mode)
        }
        onActionRequested: function(action, id) {
          // Invariant: A checked row menu acts on the selection; any other row menu acts on that row alone.
          var outside = root.checkedIds.indexOf(id) < 0
          root.cursorId = id
          if (action === "moveToLabel") return root.openLabelPicker(outside)
          if ((action === "star" || action === "unstar") && root.selectionActive && !outside)
            return root.actOnChecked(Model.starActionFor(Model.summariesById(root.service.messages, root.checkedIds)))
          root.actOnCursor(action, outside)
        }
        // Invariant: A member menu acts on one message and preserves the independent list cursor.
        onMemberComposeRequested: function(mode, id) {
          root.pendingComposeReturnTo = Nav.depth(root.nav)
          root.openMember(id)
          root.startCompose(mode)
        }
        onMemberActionRequested: function(action, id) { root.actOnMember(action, id) }
      }

      ShortcutHelp {
        id: shortcutHelp
        anchors.fill: parent
        visible: root.shortcutHelpVisible
        textColor: root.foreground
        backgroundColor: root.background
        dimColor: root.dim
        panelFontFamily: root.fontFamily
        hiddenBindings: root.service && root.service.hasAgent === false
          ? ["askAgent", "assistantSend", "assistantChooseCommand", "assistantCommandNext", "assistantCommandPrevious"]
          : []
        onDismissed: root.dismissHelp()
      }


      KeyRouter {
        id: keyRouter
        objectName: "key-router"
        context: root.backendUnavailable ? "" : focusScope.keyContext
        overlay: root.shortcutHelpVisible
        onTriggered: function(id, sequence) { root.runShortcut(id, sequence) }
      }
    }
  }

}

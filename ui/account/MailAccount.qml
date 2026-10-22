import QtQuick
import "../providers"
import "../cache"

import "../message/Html.js" as Html
import "../providers/GmailApi.js" as Api
import "../message/Message.js" as Mail
import "../message/Calendar.js" as Calendar
import "../message/Unsubscribe.js" as Unsub
import "../message/Outbox.js" as Outbox
import "Model.js" as Model
import "SearchState.js" as SearchState
import "Accounts.js" as Accounts
import "Aliases.js" as Aliases
import "../providers/Registry.js" as Provider
import "../providers/ImapProtocol.js" as Imap
import "../providers/OAuth.js" as OAuth

// Performance: Every account polls unread counts; list refreshes follow visibility, baseline checks, unread-count changes and actions. Bodies load on demand.
Item {
  id: root
  readonly property var local: localMailbox
  LocalMailbox { id: localMailbox; account: root }
  readonly property var submittedSearch: submittedSearchSession
  property bool legacySearchStopped: false
  readonly property var searchStatus: submittedSearchSession.active || submittedSearchSession.phase !== ""
    ? submittedSearchSession.status : searchQuery !== "" && rawQuery === ""
    ? SearchState.status(legacySearchStopped ? "stopped" : listLoading ? "checking" : lastError ? "failed" : "complete", lastError, "", 0)
    : SearchState.status("", "", "", 0)
  SubmittedSearch { id: submittedSearchSession; account: root }
  AccountResources { id: resources; account: root }

  visible: false
  width: 0
  height: 0

  required property string pluginDir
  property var backend: null
  property var platform: null
  property string syncFingerprint: ""
  property string configuredEmail: ""
  property string oauthClientId: ""

  property string accountId: ""

  property string providerId: Provider.DEFAULT_ID
  // Invariant: Persisted IMAP settings pass the same normalization as setup input before connecting.
  property var imapSettings: null

  property string senderName: ""
  // Invariant: Persisted JMAP settings are normalized before sending credentials.
  property var jmapSettings: null
  // Invariant: Only the account that predates multi-account support may adopt the legacy client-keyed token.
  property bool mayAdoptLegacyToken: true
  property bool active: false

  readonly property var defaultSettingValues: ({
    refreshIntervalSec: 120,
    maxMessages: 50,
    defaultQuery: "in:inbox",
    notifyNewMail: "On",
    oauthPort: 9481,
    undoSendSeconds: 10
  })
  property var settings: defaultSettingValues

  property bool windowOpen: false

  property var savingAttachmentIds: Object.create(null)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Invariant: Replace this object to notify QML bindings; changing its keys in place does not notify them.
  readonly property int refreshIntervalSec: Math.max(30, Math.min(3600,
    Math.floor(Number(setting("refreshIntervalSec", 120))) || 120))
  readonly property int maxMessages: Math.max(5, Math.min(100,
    Math.floor(Number(setting("maxMessages", 50))) || 50))
  readonly property string defaultQuery: String(setting("defaultQuery", "in:inbox")).trim()
  readonly property bool notifyNewMail: String(setting("notifyNewMail", "On")) !== "Off"
  readonly property int oauthPort: OAuth.normalizedPort(setting("oauthPort", OAuth.DEFAULT_PORT))
  readonly property int undoSendSeconds: Outbox.normalizeDelay(
    setting("undoSendSeconds", Outbox.DEFAULT_DELAY_SECONDS))

  // Invariant: Provider changes briefly leave both loaders empty; consumers must tolerate null objects.
  readonly property var auth: authLoader.item
  readonly property var api: apiLoader.item
  readonly property alias cache: cacheStore

  // Invariant: Provider capabilities are a ceiling that each account may restrict. Missing refinements keep that ceiling; the client still validates each operation.
  readonly property var capabilityRefusals: api ? api.refusals : null
  readonly property var absentMailboxes: api ? api.absentMailboxes : null

  // Invariant: Credential refusal keeps the account and cache intact while setup requests replacement credentials.
  readonly property bool credentialsRejected: !!api && api.credentialsRejected === true

  readonly property var mailboxes: Provider.mailboxes(providerId, absentMailboxes,
    Number(backend && backend.protocolInfo && backend.protocolInfo.apiVersion || 0))

  readonly property bool canArchive: Provider.can(providerId, "archive", capabilityRefusals)
  readonly property bool canReportSpam: Provider.can(providerId, "spam", capabilityRefusals)
  readonly property bool canStar: Provider.can(providerId, "star", capabilityRefusals)
  readonly property bool canMove: Provider.can(providerId, "move", capabilityRefusals)
  readonly property bool hasLabels: Provider.can(providerId, "labels")
  readonly property bool canOpenOnWeb: Provider.can(providerId, "web")

  readonly property bool canOpenWebInbox: Provider.can(providerId, "webBox")
  readonly property bool canSend: Provider.can(providerId, "send", capabilityRefusals)
  // Invariant: Conversation grouping requires a provider-supplied thread block; it is not an account-specific action capability.
  readonly property bool showsConversations: Provider.can(providerId, "conversations")
  // Invariant: Visible controls, keyboard hints and action guards share the same refined capabilities.
  readonly property var actionCapabilities: ({
    archive: canArchive, star: canStar, spam: canReportSpam, move: canMove })

  readonly property var unavailableActions: Model.unavailableActions(actionCapabilities)

  // Invariant: Page size is part of query identity because it changes the cached result set.
  readonly property string cacheKey: String(effectiveQuery || "").trim() + "|" + maxMessages

  property string mailboxKey: "inbox"
  property string searchQuery: ""
  property string searchRaw: ""
  // Invariant: Provider-built mailbox queries bypass typed-search conversion, which would turn IMAP folder names into message text searches.
  property string rawQuery: ""
  // Invariant: Gmail moves remove the label behind the current view; IMAP moves already identify their source folder.
  property string rawLabelId: ""
  property var messages: []
  property var previewMessages: []
  property var labels: []
  property var sendAsAliases: []
  property bool sendAsLoading: false
  property bool sendAsLoaded: false
  property string nextPageToken: ""
  property int resultEstimate: 0
  property bool listLoading: false
  property bool listLoaded: false
  // Invariant: Refresh retains the depth already reached by pagination.
  property int loadedDepth: 0
  property var listHandle: null
  property int listSerial: 0

  property string selectedId: ""
  property var selectedMessage: null
  property var selectedBody: ({ text: "", source: "" })
  property bool selectedHasHtml: false
  property string selectedRenderRevision: ""

  property string readerSourceKey: ""
  // Performance: Viewport changes fit the native safe tree without reparsing sender HTML.
  property var selectedDocument: null
  // Performance: Reading mode has a separate document built from the same parse, so switching modes needs no fetch or parse.
  property var selectedReaderDocument: null
  property bool selectedReaderTooHeavy: false
  // Invariant: Image-only messages fall back to sender formatting when reading mode has no text.
  property bool selectedReaderEmpty: true
  // Invariant: The missing-image count describes the active representation, which may omit hidden images and beacons.
  property int selectedReaderRemoteImages: 0
  // Invariant: Remote images require standing or per-message permission because requests can disclose that the message was read.
  property bool alwaysShowImages: false
  onAlwaysShowImagesChanged: {
    var allowed = Model.showsRemoteImages(alwaysShowImages, selectionIsPreview)
    if (allowed !== remoteImagesAllowed) {
      remoteImagesAllowed = allowed
      remoteImageData = ({})
      if (!allowed) {
        imageFetchSerial++
        imageFetchQueue = []
        remoteImagesLoading = false
        imageBatchDirty = false
        imagePaintTimer.stop()
        remoteImageAttempted = ({})
        selectedDocument = null
        selectedReaderDocument = null
      }
      if (readerSourceKey !== "") renderSource(readerSourceKey)
    }
  }
  property bool remoteImagesAllowed: false
  property bool remoteImagesLoading: false
  property var remoteImageData: ({})
  property var selectedRemoteImageSources: []
  property var imageFetchQueue: []
  property int imageFetchSerial: 0
  property var remoteImageAttempted: ({})
  property bool imageBatchDirty: false
  // Invariant: Qt receives completed, validated data URIs; remote URLs and redirects remain inside the public-host worker.

  // Invariant: Image order matches the markers emitted by htmlToText.
  property var selectedImages: []
  property int selectedBlockedImages: 0
  // Invariant: Only loadable blocked images justify offering to load images; beacons and private-network URLs do not.
  property int selectedRemoteImages: 0
  property bool selectedTooHeavy: false
  property var selectedAttachments: []

  property var selectedInvite: null
  property bool rsvpSending: false

  property var selectedUnsubscribe: null
  property bool unsubscribing: false
  // Invariant: Unsubscribe confirmation persists with the message and prevents repeat requests; transient notices cannot represent completion.
  property string unsubscribeDone: ""

  // Invariant: Keep the held conversation when selecting one of its members, whose detail response may carry no thread block.
  property var selectedThread: null

  // Performance: Member summaries survive selections within a conversation, avoiding repeated metadata reads.
  property var memberSummaries: ({})
  property var memberHandle: null

  // Invariant: Search and custom-folder views show every member location because they have no matching mailbox rail row.
  readonly property bool viewingSearch: searchQuery !== "" || rawQuery !== ""
  property var conversationOrganisation: ({ showsRail: false, viewedMailboxKey: "" })
  readonly property string viewedMailboxKey: String(conversationOrganisation.viewedMailboxKey || "")
  readonly property bool showsRail: conversationOrganisation.showsRail === true
  property var conversationJobs: []
  property bool conversationBusy: false
  property int conversationSerial: 0
  property var conversationHandle: null
  function cancelConversation() {
    if (backend && typeof backend.call === "function" && conversationHandle
        && typeof conversationHandle.cancel === "function") conversationHandle.cancel()
    conversationHandle = null
    conversationSerial++
    conversationBusy = false
    conversationJobs = []
  }
  Connections {
    target: root.backend
    ignoreUnknownSignals: true
    function onReadyChanged() {
      if (root.backend && root.backend.ready) root.queueConversation("project", null, null, null)
      else {
        root.cancelConversation()
      }
    }
  }
  onSelectedThreadChanged: queueConversation("project", null, null, null)
  onMemberSummariesChanged: queueConversation("project", null, null, null)

  // Performance: Bound the immutable parsed-tree working set. Persist sender source so future sanitizer fixes apply after restart.
  property int renderSerial: 0
  property int listLiveSerial: 0
  onAccountIdChanged: {
    clearSelection()
    cancelConversation()
    conversationOrganisation = ({ showsRail: false, viewedMailboxKey: "" })
    renderSerial++
    syncFingerprint = ""
  }

  // Invariant: RSVP and unsubscribe use the owned alias that received the message. Read availableSendAsAliases inside this binding so alias changes invalidate it.
  readonly property var receivedAsAlias: {
    if (!selectedMessage) return null
    var addressed = (selectedMessage.to || []).concat(selectedMessage.cc || [])
    return Api.preferredSendAs(availableSendAsAliases, addressed)
  }
  readonly property string receivedAsAddress: {
    var chosen = receivedAsAlias ? String(receivedAsAlias.email || "") : ""
    return chosen !== "" ? chosen : ownAddress
  }
  readonly property string receivedAsName: receivedAsAlias
    ? String(receivedAsAlias.displayName || "") : ""

  // Invariant: The displayed attendance answer comes from the persisted attendee line, keeping the card and calendar file consistent.
  readonly property string selectedResponse: selectedInvite
    ? Calendar.responseOf(selectedInvite, receivedAsAddress) : ""
  readonly property bool canRespondToInvite: !!selectedInvite && canSend
    && Calendar.canRespond(selectedInvite, receivedAsAddress)

  readonly property string unsubscribeLabel: unsubscribeDone !== "" ? ""
    : Unsub.label(selectedUnsubscribe, canSend)
  readonly property string unsubscribeDetail: unsubscribeDone !== "" ? unsubscribeDone
    : Unsub.explanation(selectedUnsubscribe, canSend)
  property bool detailLoading: false
  // Invariant: Display readiness is separate from network loading; a cached body or a valid empty body can already be ready.
  property bool detailPainted: false
  // Invariant: A slower cache read cannot replace a completed live read.
  property bool detailLive: false
  property bool detailCachedResource: false
  property var detailHandle: null

  property var inviteHandle: null
  property int detailSerial: 0

  property var profile: null
  readonly property string accountEmail: profile ? String(profile.email || "") : ""
  readonly property var availableSendAsAliases: {
    var rows = sendAsAliases.length > 0 ? sendAsAliases
      : (accountEmail === "" ? []
        : [{ email: accountEmail, displayName: "", isPrimary: true, isDefault: true }])
    // Invariant: Apply the configured sender name only on API 7+, where agent sends use the same naming rule.
    var named = Accounts.namesSender(providerId) && !!backend && backend.ready && backend.apiVersion >= 7
    return named ? Aliases.withSenderName(rows, senderName) : rows
  }
  // Invariant: The loaded profile owns the default reply address; configuredEmail supplies it before profile loading finishes.
  readonly property string ownAddress: accountEmail !== "" ? accountEmail : configuredEmail
  property int inboxUnread: 0
  property bool countLoading: false
  property var countHandle: null
  property int countSerial: 0

  property double lastSyncedMs: 0
  property int syncTick: 0
  readonly property string syncedLabel: {
    var ignored = syncTick
    if (listLoading) return "Checking for mail"
    if (lastSyncedMs <= 0) return ""
    var ago = Mail.relativeTime(new Date(lastSyncedMs), new Date())
    return ago === "now" ? "Synced just now" : "Synced " + ago + " ago"
  }

  property string lastError: ""
  property string actionStatus: ""
  property string pendingAction: ""
  property int actionPreparations: 0
  property string pendingActionQuery: ""
  property var deferredListLoad: null
  property var queuedActions: []
  property var actionCompletions: []
  property bool sending: false
  readonly property alias sendQueue: sendQueue
  readonly property int sendPendingCount: sendQueue.parked.length
  readonly property bool sendPending: sendQueue.parked.length > 0
  readonly property var latestSend: sendQueue.latest
  property int sendSecondsRemaining: 0

  // Invariant: Notifications start only after a successful load establishes the already-seen baseline.
  property var seenIds: Object.create(null)
  property bool notificationsPrimed: false
  // Invariant: The notification floor is fixed in server time when primed; raising it would suppress out-of-order arrivals.
  property double arrivalFloor: 0
  // Invariant: Unopened accounts need an unread-count baseline independent of their absent message-page cache.
  property bool countPrimed: false
  // Invariant: The bar dot represents mail arriving since the last visit, not the total unread count.

  readonly property string setupState: {

    if (!Provider.isConnectable(providerId)) return "unavailable"
    if (!auth) return "signed_out"
    return Model.setupState({
      toolsPresent: auth.toolsPresent || !auth.toolsChecked,
      credentialsPresent: auth.credentialsPresent,
      signingIn: auth.loginBusy,
      recoveringSession: auth.recoveringSession || false,
      signedIn: auth.loggedIn
    })
  }
  // Invariant: Network readiness requires both loaders; restored local mail can open before authentication finishes.
  readonly property bool ready: (setupState === "ready" || (localMailbox.available && localMailbox.hasMail)) && !!api
    && (!backend || !backend.executable || backend.ready === true)
  readonly property bool nativePolling: Provider.nativeSync(providerId) && !!backend
    && !!backend.protocolInfo && Array.isArray(backend.protocolInfo.methods)
    && backend.protocolInfo.methods.indexOf("mail.watch") >= 0
  readonly property bool busy: listLoading || detailLoading || countLoading
    || (auth ? auth.sessionBusy : false) || sending || pendingAction !== ""
  // Invariant: Provider-produced query strings remain opaque to the account coordinator and its cache.
  property string resolvedProviderQuery: ""
  property string resolvedProviderInput: ""
  property int providerQuerySerial: 0
  property int providerLabelSerial: 0
  readonly property string providerQueryInput: JSON.stringify([providerId, mailboxKey, searchQuery, defaultQuery])
  readonly property bool providerQueryNeedsResolution: searchQuery.trim() !== ""
    || (mailboxKey === "inbox" && defaultQuery.trim() !== "" && defaultQuery.trim() !== Provider.get(providerId).inheritedDefault)
  readonly property string effectiveQuery: rawQuery !== "" ? rawQuery
    : searchRaw !== "" ? searchRaw
    : resolvedProviderInput === providerQueryInput ? resolvedProviderQuery
    : Provider.mailboxFor(providerId, mailboxKey).query
  readonly property bool hasMore: nextPageToken !== ""
  // Invariant: Cached search rows may be visible while the server continues extending the result.
  readonly property bool serverSearchLoading: submittedSearchSession.active
    ? submittedSearchSession.phase === "checking"
    : searchQuery !== "" && rawQuery === "" && listLoading && !localMailbox.available
  readonly property string resultSummary: Model.resultSummary(messages, resultEstimate, hasMore)
  readonly property string barTooltip: Model.barTooltip(setupState, accountEmail, inboxUnread,
    Provider.badge(providerId), Provider.authKind(providerId))

  readonly property string setupHeadline:
    Model.setupHeadline(setupState, Provider.badge(providerId), Provider.authKind(providerId))
  readonly property string setupDetail: Model.setupDetail(setupState,
    auth ? auth.missingTools : [], Provider.unavailableReason(providerId),
    Provider.badge(providerId), Provider.authKind(providerId))
  readonly property string setupActionLabel:
    Model.setupActionLabel(setupState, Provider.badge(providerId), Provider.authKind(providerId))

  readonly property string signInProgress: {
    if (!auth) return ""
    if (!auth.toolsChecked)
      return "Checking for " + auth.requiredTools.slice(0, 2).join(" and ") + "…"
    if (!auth.credentialsPresent) return ""

    if (auth.loginBusy)
      return Provider.usesOAuth(providerId)
        ? "Finish the sign-in in your browser…"
        : "Checking the mailbox…"
    if (auth.sessionBusy) return "Restoring the saved session…"
    return ""
  }

  signal listRefreshed()

  // Invariant: Cancellation also runs during teardown, when the provider client may already be gone.
  function abortRequest(handle) {
    if (handle && typeof handle.cancelReader === "function") handle.cancelReader()
    else if (api && handle) api.abortRequest(handle)
  }

  function clearNotice() {
    lastError = ""
    actionStatus = ""
  }

  // Invariant: Unified views choose the newest account notice by timestamp, independent of account order.
  property double actionStatusAt: 0

  function note(text) {
    actionStatus = String(text || "")
    actionStatusAt = actionStatus === "" ? 0 : Date.now()
    if (actionStatus !== "") noticeTimer.restart()
  }

  function fail(text) {
    lastError = String(text || "")
    actionStatus = ""
  }

  function refresh(explicitSearch) {
    if (!ready) return
    if (explicitSearch === true) legacySearchStopped = false
    if (submittedSearchSession.active && explicitSearch === true) {
      submittedSearchSession.start(effectiveQuery)
      return
    }
    refreshCounts()
    labelActions.refreshMonitored()
    if (active && (windowOpen || !listLoaded)) loadMessages(false)
  }

  property var monitoredIds: []

  function refreshCounts() {
    if (!ready || countLoading) return
    if (localMailbox.available) {localMailbox.refreshOverview(true); return}
    if (nativePolling) {
      backendSync.check()
      return
    }
    var serial = ++countSerial
    countLoading = true
    // Invariant: The unread badge uses the Unread query rather than the broader INBOX label count.
    countHandle = api.listMessages(Provider.unreadQuery(providerId), 3, "", function(page, error) {
      if (serial !== root.countSerial) return
      if (error || !page) {
        root.countLoading = false
        root.countHandle = null
        return
      }
      var before = root.inboxUnread
      root.inboxUnread = page.estimate

      if (page.ids.length === 0) {
        root.previewMessages = []
        root.countLoading = false
        root.countHandle = null
      } else {
        root.countHandle = root.summarizedRead(page.ids, false, function(payloads) {
          if (serial !== root.countSerial) return
          var summaries = []
          for (var payloadIndex = 0; payloadIndex < payloads.length; payloadIndex++) {
            var summary = payloads[payloadIndex].nativeSummary
            // Invariant: SEARCH UNSEEN is authoritative even when an IMAP metadata response omits FLAGS.
            summary.unread = true
            summaries.push(summary)
          }
          root.previewMessages = summaries
          root.countLoading = false
          root.countHandle = null
        }, root.countHandle)
      }

      // Invariant: Rising unread counts refresh inactive accounts too. The first session read compares against cached rows so mail arriving while the shell was stopped can notify.
      var first = !root.countPrimed
      root.countPrimed = true
      if ((first || page.estimate > before) && !root.listLoading)
        root.loadMessages(false)
    })
  }

  // Invariant: The Outlook connection check is read-only and returns capabilities, never credentials or provider payloads.
  function checkMicrosoftConnection(callback) {
    if (typeof callback !== "function") return
    var report = { mail: false, graph: false, calendar: false }
    if (providerId !== "outlook" || !auth || !auth.loggedIn || !backend || !backend.ready || !(backend.apiVersion >= 5)) {
      callback(report)
      return
    }
    var owner = auth
    var expectedAccount = accountId
    function current() {
      return providerId === "outlook" && auth === owner && owner.loggedIn
        && accountId === expectedAccount
    }
    backend.call("outlook.connectionCheck", { accountId: expectedAccount }, function(result, error) {
      if (!current()) return
      callback({
        mail: !error && !!result && result.mail === true,
        graph: !error && !!result && result.graph === true,
        calendar: !error && !!result && result.calendar === true
      })
    })
  }

  function loadProfile() {
    if (!ready || profile) return
    if (cacheStore.loaded && cacheStore.store.profile) profile = cacheStore.store.profile
    api.getProfile(function(result, error) {
      if (error || !result) return
      // Invariant: Account teardown can remove methods before an outstanding profile callback returns.
      if (typeof cacheStore.bindAccount !== "function") return
      root.profile = result
      if (result.email !== "") root.accountIdentified(result.email)
      // Invariant: Bind the cache to the verified profile address before exposing its mailbox data.
      cacheStore.bindAccount(result.email)
      cacheStore.putProfile(result)
    })
  }

  function loadLabels() {
    if (!ready) return
    if (localMailbox.available) {localMailbox.refreshOverview(false);return}
    if (cacheStore.loaded && cacheStore.store.labels.length > 0 && labels.length === 0)
      labels = cacheStore.store.labels
    api.getLabels(function(result, error) {
      if (error) return
      root.labels = result
      cacheStore.putLabels(result)
    })
  }

  function loadSendAs() {
    if (!ready || sendAsLoading || sendAsLoaded) return
    sendAsLoading = true
    api.getSendAs(function(result, error) {
      root.sendAsLoading = false
      // Invariant: Alias lookup failure keeps sendAsLoaded false for retry and logs diagnostics without blocking the mailbox.
      if (error) {
        console.warn("omamail: could not read the send-as addresses:",
          OAuth.redact(String(error)))
        return
      }
      root.sendAsAliases = result
      root.sendAsLoaded = true
    })
  }

  function hydrateSummary(summary) {
    summary.date = new Date(summary.dateMs || summary.date || 0)
    summary.time = Mail.relativeTime(summary.date, new Date())
    return summary
  }

  function hydrateSummaries(rows) {
    var values = Array.isArray(rows) ? rows : []
    for (var summaryIndex = 0; summaryIndex < values.length; summaryIndex++) hydrateSummary(values[summaryIndex])
    return values
  }

  function summarizeResources(payloads, callback) {
    var account = accountId
    var list = Array.isArray(payloads) ? payloads : []
    if (list.length === 0) { callback([], ""); return }
    if (!backend) { callback([], "Mail backend is unavailable"); return }
    backend.call("message.summaries", {messages: list, now: Date.now()}, function(result, error) {
      if (account !== root.accountId) return
      if (error || !result) { callback([], "Could not prepare message summaries"); return }
      var summaries = result.summaries || []
      if (summaries.length !== list.length) { callback([], "Incomplete message summaries"); return }
      for (var payloadIndex = 0; payloadIndex < list.length; payloadIndex++) list[payloadIndex].nativeSummary = root.hydrateSummary(summaries[payloadIndex])
      callback(list, "")
    })
  }

  // Invariant: Serialize native preparation so final metadata cannot overtake earlier progress batches.
  function summarizedRead(ids, full, callback, parent, progress, members) {
    var queued = []
    var preparing = false
    var handle = null
    var account = accountId
    function next() {
      if (preparing || queued.length === 0) return
      var item = queued.shift()
      preparing = true
      root.summarizeResources(item.payloads, function(payloads, error) {
        preparing = false
        if (account !== root.accountId || (handle && handle.aborted)) return
        if (item.final) callback(payloads, error || item.error)
        else if (typeof progress === "function") progress(payloads)
        next()
      })
    }
    function deliver(payloads, error) { queued.push({payloads: payloads, error: error, final: true}); next() }
    function arrived(payloads) { queued.push({payloads: payloads, final: false}); next() }
    handle = members ? api.getSummaries(ids, deliver)
      : api.getMessages(ids, full, deliver, parent, typeof progress === "function" ? arrived : undefined)
    return handle
  }

  property string readerRequestPrefix: String(Date.now()) + "-" + String(Math.random())
  property int readerRequestSerial: 0
  function readerOptions() {
    return {allowRemoteImages: remoteImagesAllowed,
      remoteImageData: remoteImagesAllowed ? remoteImageData : null, withReader: true}
  }

  function preparedRead(messageId, callback) {
    var account = accountId
    var client = api
    var request = readerRequestPrefix + "-" + (++readerRequestSerial)
    var handle = {aborted: false, cancelReader: function() {
      if (handle.aborted) return
      handle.aborted = true
      if (root.backend) root.backend.call("reader.cancel", {accountId: account, requestId: request}, function() {})
    }}
    function current() { return !handle.aborted && account === root.accountId && client === root.api }
    function read(cached) {
      if (!current()) return
      var options = root.readerOptions()
      root.backend.call("reader.open", {accountId: account, id: messageId, requestId: request,
        cacheOnly: cached, now: Date.now(), options: options}, function(resource, error) {
        if (!current()) return
        if (!error && resource && resource.nativeContent) {
          resource.nativeSummary = root.hydrateSummary(resource.nativeSummary)
          callback(resource, "", cached, options.allowRemoteImages)
        } else if (!cached) callback(null, "Could not open that message", false)
        if (cached && !(root.local && root.local.available && resource && !error)) read(false)
      })
    }
    if (!backend) { callback(null, "Mail backend is unavailable", false); return handle }
    read(true)
    return handle
  }

  function preferredSendAs(recipients) {
    return Api.preferredSendAs(availableSendAsAliases, recipients)
  }

  // Performance: Paint cached query rows immediately; typed searches can also search cached summaries while the server continues.
  function paintFromCache() {
    if (!cacheStore.loaded) return
    var serial = listSerial
    var account = accountId
    var query = cacheKey
    var liveAtStart = listLiveSerial
    cacheStore.getPreview(effectiveQuery, maxMessages,
      searchQuery !== "" && rawQuery === "" ? searchQuery : "", providerId, 0,
      function(result, error) {
        if (error || !result || serial !== root.listSerial || account !== root.accountId
            || query !== root.cacheKey || liveAtStart !== root.listLiveSerial) return
        var restored = result.summaries || []
        var entry = result.entry
        if (restored.length === 0) return
      hydrateSummaries(restored)

      if (!Model.sameSummaries(messages, restored)) messages = restored
      resultEstimate = entry ? Math.max(entry.estimate, restored.length) : restored.length
      nextPageToken = entry ? entry.nextPageToken : ""
      listLoaded = true
      lastError = ""

      // Invariant: Cached rows are already seen and must not become first-load notifications.
      var seen = Object.create(null)
      for (var key in seenIds) seen[key] = true
      for (var seenIndex = 0; seenIndex < restored.length; seenIndex++) seen[restored[seenIndex].id] = true
      seenIds = seen
      // Invariant: Cached timestamps establish the prior-visit baseline for identifying new mail.
      if (arrivalFloor === 0) arrivalFloor = restored[0].date.getTime() || 0
      notificationsPrimed = true
      listRefreshed()
      })
  }

  function loadMessages(append, skipCache, preservedError) {
    if (submittedSearchSession.active) {
      if (append) submittedSearchSession.loadMore()
      else submittedSearchSession.refreshSaved()
      return
    }
    // Invariant: Pending optimistic edits defer same-query refreshes; navigation to another cache key may still load.
    if (!ready) return
    if (rawQuery === "" && searchRaw === "" && providerQueryNeedsResolution
        && resolvedProviderInput !== providerQueryInput) {
      if (!backend || !backend.ready) return
      // Invariant: Invalidate the prior list before asynchronous query resolution so it cannot paint into the new view.
      listSerial++
      abortRequest(listHandle)
      listHandle = null
      listLoading = true
      var queryInput = providerQueryInput
      var queryAccount = accountId
      var querySerial = ++providerQuerySerial
      backend.call("providers.resolve", {provider: providerId, operation: "query", mailbox: mailboxKey,
        search: searchQuery, defaultQuery: defaultQuery}, function(result, error) {
        if (querySerial !== root.providerQuerySerial || queryAccount !== root.accountId
            || queryInput !== root.providerQueryInput) return
        if (error) { root.listLoading = false; root.note("Could not prepare this search"); return }
        root.resolvedProviderQuery = String((result || {}).value || "")
        root.resolvedProviderInput = queryInput
        root.loadMessages(append, skipCache, preservedError)
      })
      return
    }
    if ((pendingAction !== "" || actionPreparations > 0) && cacheKey === pendingActionQuery) {
      var cleared = !listLoaded
      // Invariant: Returning A→B→A needs a fresh serial even while A is deferred, or B can paint into A.
      if (cleared) {
        listSerial++
        abortRequest(listHandle)
        listHandle = null
        listLoading = false
      }
      deferredListLoad = ({
        cacheKey: cacheKey,
        append: append === true,
        skipCache: skipCache === true,
        preservedError: String(preservedError || ""),
        cleared: cleared
      })
      return
    }
    // Invariant: A deferred refresh belongs to its original view and is superseded by later navigation.
    if (deferredListLoad && deferredListLoad.cacheKey !== cacheKey)
      deferredListLoad = null
    var serial = ++listSerial
    var keptError = String(preservedError || "")
    abortRequest(listHandle)
    if (!append && skipCache !== true) {
      // Invariant: An interrupted optimistic edit already owns the freshest state; cache-first refresh must not restore its removed row.
      paintFromCache()
      nextPageToken = ""
      resultEstimate = 0
    }
    listLoading = true
    var token = append ? nextPageToken : ""
    var limit = append ? maxMessages : Model.reloadLimit(maxMessages, loadedDepth)
    if (localMailbox.load(append,limit,serial)) return

    if (searchQuery !== "" && rawQuery === "") {
      loadSearchMessages(append, token, limit, serial, keptError)
      return
    }

    listHandle = api.listMessages(effectiveQuery, limit, token,
      function(page, error) {
        if (serial !== root.listSerial) return
        if (error || !page) {
          root.listLoading = false
          if (!append) root.nextPageToken = ""
          root.fail(error || "Gmail returned nothing")
          return
        }
        root.resultEstimate = page.estimate
        root.nextPageToken = page.nextPageToken
        if (page.ids.length === 0) {
          root.listLiveSerial++
          root.listLoading = false
          root.listLoaded = true
          if (!append) {
            root.messages = []
            root.loadedDepth = 0
            // Invariant: Cache empty server results too, or the next cache-first visit restores rows the server removed.
            cacheStore.putQuery(root.cacheKey, ({
              summaries: [],
              estimate: root.resultEstimate,
              nextPageToken: root.nextPageToken
            }))
          }
          root.lastError = keptError
          root.listRefreshed()
          return
        }
        root.fetchSummaries(page.ids, append, serial, keptError)
      })
  }

  function deferredLoadCleared(query) {
    return !!deferredListLoad && deferredListLoad.cacheKey === query
      && deferredListLoad.cleared === true
  }

  function resumeDeferredListLoad(actionQuery, actionError) {
    var request = deferredListLoad
    deferredListLoad = null
    if (!request || request.cacheKey !== cacheKey) return false
    var sameActionQuery = cacheKey === actionQuery
    // Invariant: Failure may repaint the repaired cache; successful removal revalidates without cache because local-search fallback can restore the moved row.
    var useCache = sameActionQuery && request.cleared === true
      && String(actionError || "") !== ""
    loadMessages(sameActionQuery ? false : request.append === true,
      sameActionQuery ? !useCache : request.skipCache === true,
      String(actionError || request.preservedError || ""))
    return true
  }

  // Performance: Stream metadata as search ID fragments settle. The final listing alone owns pagination and completion.
  function loadSearchMessages(append, token, limit, serial, preservedError) {
    var previewSearch = messages.slice()
    var settledBase = append ? messages.slice() : []
    var liveSummaries = []
    var requested = Object.create(null)
    var painted = Object.create(null)
    var fetchQueue = []
    var fetchActive = false
    var listingDone = false
    var finalPage = null
    var listingError = ""
    var summaryError = ""
    var paintQueue = []
    var paintActive = false
    var finishing = false

    function summariesOf(payloads) {
      var summaries = []
      var list = Array.isArray(payloads) ? payloads : []
      for (var messageIndex = 0; messageIndex < list.length; messageIndex++) summaries.push(list[messageIndex].nativeSummary)
      return summaries
    }

    function paintPayloads(payloads) {
      if (serial !== root.listSerial) return
      var fresh = []
      var list = Array.isArray(payloads) ? payloads : []
      for (var messageIndex = 0; messageIndex < list.length; messageIndex++) {
        var id = String(list[messageIndex] && list[messageIndex].id ? list[messageIndex].id : "")
        if (id === "" || painted[id]) continue
        painted[id] = true
        fresh.push(list[messageIndex])
      }
      var summaries = summariesOf(fresh)
      if (summaries.length === 0) return
      paintQueue.push(summaries)
      pumpPaint()
    }

    function pumpPaint() {
      if (paintActive || paintQueue.length === 0 || serial !== root.listSerial) return
      paintActive = true
      var summaries = paintQueue.shift()
      root.backend.call("model.apply", {operation: "searchProgress",
        args: [previewSearch, liveSummaries, summaries]}, function(result, error) {
        if (serial !== root.listSerial) return
        paintActive = false
        if (error || !result) summaryError = "Could not prepare search results"
        else {
          liveSummaries = root.hydrateSummaries(result.live)
          root.listLiveSerial++
          root.messages = root.hydrateSummaries(result.visible)
          root.listLoaded = true
          root.lastError = preservedError
          root.listRefreshed()
        }
        if (paintQueue.length > 0) pumpPaint()
        else finishIfReady()
      })
    }

    function finishIfReady() {
      if (serial !== root.listSerial || !listingDone || fetchActive || paintActive
          || paintQueue.length > 0 || finishing || fetchQueue.length > 0) return
      root.listLoading = false
      if (!finalPage) {
        // Invariant: Failed page-one revalidation invalidates a cached continuation, which could otherwise skip or duplicate rows.
        root.nextPageToken = ""
        root.fail(listingError || "The mail server returned nothing")
        return
      }

      root.resultEstimate = finalPage.estimate
      finishing = true
      root.backend.call("model.apply", {operation: "searchFinish",
        args: [settledBase, previewSearch, liveSummaries, finalPage.ids, append]}, function(result, error) {
      if (serial !== root.listSerial) return
      if (error || !result) { root.fail("Could not settle search results"); return }
      var missingSummaries = result.missing
      var metadataError = summaryError
      if (metadataError === "" && missingSummaries.length > 0)
        metadataError = "Some search results could not be read"
      var complete = listingError === "" && metadataError === ""
      root.nextPageToken = complete ? finalPage.nextPageToken : ""
      var settled = root.hydrateSummaries(result.settled)
      root.applySummaries(settled, false, true, complete, function() {
      if (listingError !== "") {
        root.fail(listingError)
        return
      }
      if (metadataError !== "") {
        root.fail(metadataError)
        return
      }
      cacheStore.putQuery(root.cacheKey, ({
        summaries: root.messages,
        estimate: root.resultEstimate,
        nextPageToken: root.nextPageToken
      }))
      if (preservedError !== "") root.fail(preservedError)
      })
      })
    }

    // Performance: Serialize fragment metadata requests so IMAP batching keeps one shared concurrency ceiling.
    function startNextFetch() {
      if (serial !== root.listSerial || fetchActive || fetchQueue.length === 0) {
        finishIfReady()
        return
      }
      var wanted = fetchQueue.shift()
      fetchActive = true
      root.summarizedRead(wanted, false, function(payloads, error) {
        if (serial !== root.listSerial) return
        paintPayloads(payloads)
        if (error && summaryError === "") summaryError = error
        fetchActive = false
        startNextFetch()
      }, listHandle, paintPayloads)
    }

    function fetchIds(ids) {
      if (serial !== root.listSerial) return
      var source = Array.isArray(ids) ? ids : []
      var wanted = []
      for (var messageIndex = 0; messageIndex < source.length; messageIndex++) {
        var id = String(source[messageIndex] || "")
        if (id === "" || requested[id]) continue
        requested[id] = true
        wanted.push(id)
      }
      if (wanted.length === 0) {
        finishIfReady()
        return
      }
      fetchQueue.push(wanted)
      startNextFetch()
    }

    function idsArrived(page) {
      if (serial !== root.listSerial || !page) return
      root.resultEstimate = Math.max(root.resultEstimate,
        Math.max(0, Math.floor(Number(page.estimate)) || 0))
      root.nextPageToken = String(page.nextPageToken || "")
      fetchIds(page.ids)
    }

    listHandle = api.listMessages(effectiveQuery, limit, token,
      function(page, error) {
        if (serial !== root.listSerial) return
        finalPage = page
        listingError = String(error || "")
        listingDone = true
        if (page) fetchIds(page.ids)
        finishIfReady()
      }, idsArrived)
  }

  function fetchSummaries(ids, append, serial, preservedError) {
    var base = append ? root.messages.slice() : []
    var progress = resources.summaryProgress(ids,base,serial)
    root.summarizedRead(ids, false, function(payloads, error) {
      if (serial !== root.listSerial) return
      root.listLoading = false
      var summaries = []
      var list = Array.isArray(payloads) ? payloads : []
      for (var payloadIndex = 0; payloadIndex < list.length; payloadIndex++)
        summaries.push(list[payloadIndex].nativeSummary)
      root.backend.call("model.apply", {operation: "missingSearchSummaryIds", args: [summaries, ids]}, function(missingSummaries, modelError) {
      if (serial !== root.listSerial) return
      if (modelError) { root.fail("Could not prepare message list"); return }
      var metadataError = String(error || "")
      if (metadataError === "" && missingSummaries.length > 0)
        metadataError = "Some messages could not be read"
      if (metadataError !== "" && summaries.length === 0) {
        // Invariant: An entirely missing live metadata page may retain cached rows but never its continuation.
        root.nextPageToken = ""
        root.fail(metadataError)
        return
      }
      if (append) root.messages = base
      root.applySummaries(summaries, append, false, metadataError === "", function() {
      if (metadataError !== "") {
        // Invariant: Missing metadata invalidates the list token, which advances past every returned ID and would skip the missing row.
        root.nextPageToken = ""
        root.fail(metadataError)
        return
      }
      // Invariant: Cache the displayed bounded prefix across pages so local searches retain rows already seen.
      cacheStore.putQuery(root.cacheKey, ({
        summaries: root.messages,
        estimate: root.resultEstimate,
        nextPageToken: root.nextPageToken
      }))
      if (preservedError !== "") root.fail(preservedError)
      })
      })
    }, listHandle, progress)
  }

  function applySummaries(summaries, append, suppressArrivals, markSynced, callback) {
    var serial = ++listLiveSerial
    var account = accountId
    var list = listSerial
    var merged = append ? root.messages.concat(summaries) : summaries
    if (root.local && root.local.available) root.messages = merged
    // Invariant: Old unread rows found by a search are results, not new-mail notifications.
    if (!backend) { fail("Mail backend is unavailable"); return }
    backend.call("model.apply", {operation: "batch", calls: [
      {operation: "newArrivals", args: [summaries, seenIds, notificationsPrimed, arrivalFloor]},
      {operation: "newestDate", args: [merged]}
    ]}, function(result, error) {
      if (serial !== root.listLiveSerial || account !== root.accountId || list !== root.listSerial) return
      if (error || !result) { root.fail("Could not update message list"); return }
      var arrivals = append || suppressArrivals === true ? [] : result[0]

    var seen = Object.create(null)
    for (var rowIndex = 0; rowIndex < merged.length; rowIndex++) seen[merged[rowIndex].id] = true
    // Invariant: Keep seen IDs beyond the current page so returning rows cannot notify again.
    for (var key in seenIds) seen[key] = true
    seenIds = seen
    if (arrivalFloor === 0) arrivalFloor = Number(result[1]) || 0
    notificationsPrimed = true

    messages = merged
    loadedDepth = merged.length
    listLoaded = true
    lastError = ""
    if (markSynced !== false) lastSyncedMs = Date.now()
    listRefreshed()

    if (notifyNewMail && arrivals.length > 0) notify(arrivals)
    if (typeof callback === "function") callback()
    })
  }

  function loadMore() {
    if (!hasMore || listLoading) return
    loadMessages(true)
  }

  property bool selectionIsPreview: false

  function select(id, previewOnly) {
    var messageId = String(id || "")
    if (messageId === "") {
      clearSelection()
      return
    }
    selectionIsPreview = previewOnly === true
    selectedId = messageId
    var serial = ++detailSerial
    var markedRead = false
    abortRequest(detailHandle)
    abortRequest(inviteHandle)
    inviteHandle = null
    selectedMessage = null
    selectedBody = { text: "", source: "" }
    selectedHasHtml = false
    selectedRenderRevision = ""
    selectedDocument = null
    selectedReaderDocument = null
    selectedReaderTooHeavy = false
    selectedReaderEmpty = true
    selectedReaderRemoteImages = 0
    readerSourceKey = ""
    remoteImagesAllowed = Model.showsRemoteImages(alwaysShowImages, selectionIsPreview)
    remoteImagesLoading = false
    remoteImageData = ({})
    remoteImageAttempted = ({})
    imageBatchDirty = false
    imagePaintTimer.stop()
    selectedRemoteImageSources = []
    imageFetchQueue = []
    imageFetchSerial++
    selectedBlockedImages = 0
    selectedRemoteImages = 0
    selectedImages = []
    selectedAttachments = []
    selectedInvite = null
    selectedUnsubscribe = null
    unsubscribeDone = ""
    detailLoading = true
    detailPainted = false

    // Performance: Paint the known row or conversation-member summary before loading the body.
    var knownSummary = summaryOf(messageId)
    if (knownSummary) selectedMessage = knownSummary
    // Invariant: The selected row supplies thread membership before detail metadata arrives, preventing rail positions from shifting.
    selectConversation(messageId, knownSummary)

    // Invariant: Cache-first body painting must yield to a live response that finishes first.
    detailLive = false
    detailCachedResource = false

    detailHandle = preparedRead(messageId, function(payload, error, cached, readAllowsRemoteImages) {
      if (serial !== root.detailSerial || (cached && root.detailLive)) return
      if (error || !payload) {
        root.detailLoading = false
        if (!root.detailPainted && !root.detailCachedResource) root.fail(error || "Could not open that message")
        return
      }
      if (cached) root.detailCachedResource = true
      else root.detailLive = true
      var decoded = payload.nativeContent.body
      root.renderSerial++
      root.selectedHasHtml = !!payload.hasHtml
      root.readerSourceKey = payload.hasHtml ? String(payload.readerKey) : ""
      var ready = payload.nativeRender
      root.adoptRendered(ready, readAllowsRemoteImages)
        root.detailLoading = false
        root.detailPainted = true
        Qt.callLater(function() { if (serial===root.detailSerial) resources.warmNeighbours(messageId) })
        root.lastError = ""
        if (ready.plainText) decoded = ({ text: ready.plainText.text, source: "html", bodyDirection: ready.plainText.bodyDirection || "" })
        root.selectedBody = decoded
        root.selectedImages = ready.plainText ? ready.plainText.images : []

      root.selectedAttachments = payload.nativeContent.attachments

      // Invariant: Detail responses may omit listing fields, such as HEY subjects, so merge with known metadata.
      var previous = Model.messageById(root.messages, root.previewMessages, messageId)
      root.backend.call("model.apply", {operation: "detailSummary", args: [previous, payload.nativeSummary]}, function(summary, modelError) {
      if (serial !== root.detailSerial || (cached && root.detailLive)) return
      if (modelError || !summary) {
        root.detailLoading = false
        if (!root.detailPainted) root.fail("Could not prepare message detail")
        return
      }
      // Invariant: Cached bodies cannot replace newer account labels or thread state after optimistic edits.
      if (cached) summary = Model.cachedDetailSummary(root.summaryOf(messageId), summary)
      function paintSummary(summary) {
      if (serial !== root.detailSerial || (cached && root.detailLive)) return
      summary = root.hydrateSummary(summary)
      root.selectedMessage = summary
      root.selectedInvite = payload.cachedInvite || Calendar.fromPayload(payload.payload)
      root.selectedUnsubscribe = Unsub.fromMessage(payload)
      // Invariant: Persist only the invitation overlay after attachment loading; the complete resource remains in native cache.
      var record = ({
        text: root.selectedBody.text,
        source: root.selectedBody.source,
        bodyDirection: String(root.selectedBody.bodyDirection || ""),
        attachments: root.selectedAttachments,
        images: root.selectedImages,
        invite: root.selectedInvite,
        unsubscribe: root.selectedUnsubscribe
      })
      // Invariant: Calendar attachment references require a separate fetch; persist the invitation overlay for later opens.
      if (!payload.cachedInvite) root.loadInvite(messageId, serial, Calendar.pendingPart(payload.payload), record)
      if (!cached) {
        root.messages = Model.replaceById(root.messages, summary)
        root.previewMessages = Model.replaceById(root.previewMessages, summary)
      }
      // Invariant: A direct open without a known row learns its conversation from the detail response.
      root.selectConversation(messageId, summary)
      root.rememberMember(summary)
      // Invariant: Previewing a message must not mark it read.
      if (!markedRead && Model.marksReadOnArrival(summary, root.selectionIsPreview))
        markedRead = root.act(messageId, "markRead", true) === true
      }
      // Invariant: Overlay the pending read before painting stale UNREAD revalidation, and send at most one read per opening.
      var keepRead = markedRead && (root.actionPreparations > 0 || root.pendingAction === "markRead"
        || (root.selectedMessage && root.selectedMessage.unread === false))
      if (keepRead) {
        root.backend.call("model.apply", {operation: "applyLabelChange", args: [summary, "markRead", "", null]}, function(readSummary, readError) {
          if (serial !== root.detailSerial || (cached && root.detailLive)) return
          if (readError || !readSummary) return
          paintSummary(readSummary)
        })
      } else paintSummary(summary)
      })
    })
  }

  function markPreviewRead(id) {
    if (!Model.previewReadable(messages, id)) return false
    act(String(id), "markRead", true)
    return true
  }

  // Invariant: Bounding the member cache preserves summaries for the currently held conversation.
  function queueConversation(operation, summary, additions, after) {
    var jobs = (conversationJobs || []).slice()
    if (operation === "project" && jobs.some(function(job) { return job.operation === "project" })) {
      pumpConversation(); return
    }
    jobs.push({ operation: operation, summary: summary, additions: additions,
      after: after, account: accountId, selected: selectedId })
    conversationJobs = jobs
    pumpConversation()
  }
  function pumpConversation() {
    if (conversationBusy || !backend || !backend.ready || conversationJobs.length === 0) return
    var jobs = conversationJobs.slice()
    var job = jobs.shift()
    conversationJobs = jobs
    if (job.account !== accountId || (job.operation !== "project" && job.selected !== selectedId)) {
      pumpConversation(); return
    }
    conversationBusy = true
    var serial = ++conversationSerial
    var account = accountId
    var selected = selectedId
    var beforeMembers = JSON.stringify(memberSummaries)
    var beforeThread = JSON.stringify(selectedThread)
    var handle = backend.call("account.conversation", {
      operation: job.operation, thread: selectedThread, summaries: memberSummaries,
      selectedId: selectedId, summary: job.summary, additions: job.additions,
      messages: job.operation === "seed" ? messages : [],
      previewMessages: job.operation === "seed" ? previewMessages : [],
      conversations: showsConversations, mailboxKey: mailboxKey,
      searching: viewingSearch, mailboxes: mailboxes
    }, function(result, error) {
      if (!root || serial !== root.conversationSerial) return
      root.conversationHandle = null
      root.conversationBusy = false
      if (!error && result && account === root.accountId && selected === root.selectedId
          && beforeMembers === JSON.stringify(root.memberSummaries)
          && beforeThread === JSON.stringify(root.selectedThread)) {
        root.conversationOrganisation = result
        if (job.operation === "select" && JSON.stringify(result.thread) !== beforeThread)
          root.selectedThread = result.thread
        if ((job.operation === "merge" || job.operation === "seed")
            && JSON.stringify(result.summaries) !== beforeMembers)
          root.memberSummaries = result.summaries
        if (typeof job.after === "function") job.after(result)
      } else if (!error && account === root.accountId && selected === root.selectedId
          && (job.operation === "select" || job.operation === "seed")) {
        // Invariant: Rebase a selection plan when a list or optimistic action changed its source snapshot.
        root.queueConversation(job.operation, job.summary, job.additions, job.after)
      }
      root.pumpConversation()
    })
    if (conversationBusy && serial === conversationSerial) conversationHandle = handle
  }
  function selectConversation(messageId, summary) {
    if (String(messageId) !== selectedId) return
    queueConversation("select", summary, null, function() { root.loadMembers() })
  }
  function mergeMembers(additions) { queueConversation("merge", null, additions, null) }
  function rememberMember(summary) {
    if (!summary || !summary.id) return
    var additions = Object.create(null)
    additions[summary.id] = summary
    mergeMembers(additions)
  }
  function loadMembers() {
    if (!api || !showsConversations) return
    queueConversation("seed", null, null, function(result) {
      var wanted = result.missing || []
      if (!result.showsRail || wanted.length === 0) return
      root.abortRequest(root.memberHandle)
      var account = root.accountId
      var selected = root.selectedId
      var serial = root.detailSerial
      root.memberHandle = root.summarizedRead(wanted, false, function(payloads, error) {
        if (!root || account !== root.accountId || selected !== root.selectedId || serial !== root.detailSerial) return
        root.memberHandle = null
        if (error || !payloads || payloads.length === 0) return
        var arrived = Object.create(null)
        for (var messageIndex = 0; messageIndex < payloads.length; messageIndex++) {
          var summary = payloads[messageIndex].nativeSummary
          if (summary && summary.id) arrived[summary.id] = summary
        }
        root.mergeMembers(arrived)
      }, null, null, true)
    })
  }

  function loadInvite(messageId, serial, part, record) {
    if (!part) return
    inviteHandle = api.getAttachment(messageId, String(part.body.attachmentId),
      function(data, error) {
        if (serial !== root.detailSerial) return
        root.inviteHandle = null
        if (error || !data) return
        var invite = Calendar.fromAttachment(part, data)
        if (!invite) return
        root.selectedInvite = invite
        record.invite = invite
        bodyCache.put(messageId, record)
        })
  }

  // Invariant: Policy changes re-render by native source identity; sender markup never returns through QML.
  function renderSource(source) {
    readerSourceKey = String(source || "")
    var rendering = ++renderSerial
    var selection = selectedId
    var account = accountId
    var detail = detailSerial
    var key = readerSourceKey
    if (!backend) { fail("Mail backend is unavailable"); return }
    backend.call("reader.render", {accountId: account, id: selection,
      readerKey: readerSourceKey, now: Date.now(), options: readerOptions()}, function(result, error) {
      if (rendering !== root.renderSerial || account !== root.accountId
          || selection !== root.selectedId || detail !== root.detailSerial || key !== root.readerSourceKey) return
      if (error || !result) { root.detailLoading = false; root.fail("Could not prepare this message for display"); return }
      root.applyRendered(result.nativeRender)
    })
  }

  function adoptRendered(ready, readAllowsRemoteImages) {
    // Invariant: A response prepared under an older display policy must be re-rendered before painting.
    if (readerSourceKey !== "" && readAllowsRemoteImages !== undefined
        && readAllowsRemoteImages !== remoteImagesAllowed) {
      renderSource(readerSourceKey)
      return
    }
    // Invariant: Keep the current document until native rendering incorporates already-approved image bytes.
    if (readerSourceKey !== "" && remoteImagesAllowed && Object.keys(remoteImageData).length > 0) {
      renderSource(readerSourceKey)
      return
    }
    applyRendered(ready)
  }

  function applyRendered(ready) {
      var revision = String(ready.revision || "")
      if (revision !== "" && revision === selectedRenderRevision) return
      selectedRenderRevision = revision
      selectedDocument = ready.document
      selectedReaderDocument = ready.reader ? ready.reader.document : null
      selectedReaderTooHeavy = !!ready.reader && ready.reader.tooHeavy
      selectedReaderEmpty = !ready.reader || ready.reader.empty
      selectedReaderRemoteImages = ready.reader ? ready.reader.blockedImages : 0
      selectedBlockedImages = ready.blockedImages
      selectedRemoteImages = ready.remoteImages
      selectedRemoteImageSources = ready.remoteImageSources || []
      selectedTooHeavy = ready.tooHeavy
      if (remoteImagesAllowed && !remoteImagesLoading
        && selectedRemoteImageSources.length > 0)
        Qt.callLater(root.prepareRemoteImages)
  }

  function showRemoteImages() {
    if (remoteImagesAllowed || readerSourceKey === "") return
    remoteImagesAllowed = true
    remoteImageData = ({})
    renderSource(readerSourceKey)
  }

  function prepareRemoteImages() {
    if (!remoteImagesAllowed || remoteImagesLoading || readerSourceKey === ""
      || selectedRemoteImageSources.length === 0) return
    var pending = []
    for (var imageIndex = 0; imageIndex < selectedRemoteImageSources.length; imageIndex++) {
      var source = String(selectedRemoteImageSources[imageIndex])
      if (!remoteImageAttempted[source] && !remoteImageData[source] && pending.indexOf(source) < 0)
        pending.push(source)
    }
    if (pending.length === 0) return
    imageFetchQueue = pending
    imageBatchDirty = false
    remoteImagesLoading = true
    imageFetchSerial++
    fetchNextImage(imageFetchSerial)
  }

  function flushRemoteImages() {
    if (!imageBatchDirty || !remoteImagesAllowed || readerSourceKey === "") return
    imageBatchDirty = false
    renderSource(readerSourceKey)
  }

  function fetchNextImage(serial) {
    if (serial !== imageFetchSerial) return
    if (imageFetchQueue.length === 0) {
      remoteImagesLoading = false
      imagePaintTimer.stop()
      flushRemoteImages()
      return
    }
    var queue = imageFetchQueue.slice(0)
    var source = String(queue.shift())
    imageFetchQueue = queue
    if (!backend || !backend.ready) { remoteImagesLoading = false; return }
    remoteImageAttempted[source] = true
    backend.call("public.image", {url:source}, function(result, error) {
      if (serial !== root.imageFetchSerial) return
      var data = result && !error ? String(result.data || "") : ""
      if (!Html.isRasterDataImage(data)) data = ""
      if (data !== "") {
        var prepared = ({})
        for (var key in root.remoteImageData) prepared[key] = root.remoteImageData[key]
        prepared[source] = data
        root.remoteImageData = prepared
        root.imageBatchDirty = true
        if (!imagePaintTimer.running) imagePaintTimer.start()
      }
      root.fetchNextImage(serial)
    })
  }

  // Invariant: Explicitly opening one image still uses the public-host worker; Qt never receives the remote address.
  function fetchDisplayImage(source, callback) {
    var wanted = String(source || "")
    var done = typeof callback === "function" ? callback : function() {}
    if (Html.isRasterDataImage(wanted)) {
      done(wanted)
      return
    }
    if (remoteImageData && Object.prototype.hasOwnProperty.call(remoteImageData, wanted)
      && Html.isRasterDataImage(String(remoteImageData[wanted] || ""))) {
      done(String(remoteImageData[wanted]))
      return
    }
    if (Html.imageSourceKind(wanted) !== "remote") {
      done("")
      return
    }
    if (!backend || !backend.ready) { done(""); return }
    var account = accountId
    var selection = selectedId
    var detail = detailSerial
    backend.call("public.image", {url:wanted}, function(result, error) {
      if (account !== root.accountId || selection !== root.selectedId || detail !== root.detailSerial) return
      var data = result && !error ? String(result.data || "") : ""
      done(Html.isRasterDataImage(data) ? data : "")
    })
  }

  function clearSelection() {
    detailSerial++
    abortRequest(detailHandle)
    detailHandle = null
    abortRequest(inviteHandle)
    inviteHandle = null
    selectedId = ""
    selectedMessage = null
    selectedBody = { text: "", source: "" }
    selectedHasHtml = false
    selectedRenderRevision = ""
    selectedDocument = null
    selectedReaderDocument = null
    selectedReaderTooHeavy = false
    selectedReaderEmpty = true
    selectedReaderRemoteImages = 0
    readerSourceKey = ""
    remoteImagesAllowed = false
    remoteImagesLoading = false
    remoteImageData = ({})
    remoteImageAttempted = ({})
    imageBatchDirty = false
    imagePaintTimer.stop()
    selectedRemoteImageSources = []
    imageFetchQueue = []
    imageFetchSerial++
    selectedImages = []
    selectedBlockedImages = 0
    selectedRemoteImages = 0
    selectedTooHeavy = false
    selectedAttachments = []
    selectedInvite = null
    selectedUnsubscribe = null
    unsubscribeDone = ""
    detailLoading = false
    // Performance: Closing a conversation clears its rail but keeps reusable member summaries.
    selectedThread = null
    abortRequest(memberHandle)
    memberHandle = null
  }

  // Invariant: The list cursor and the reader selection are separate positions.
  function cursorOffset(cursorId, delta) {
    return Model.cursorAfterOffset(messages, cursorId, delta)
  }

  // Performance: Native intent preparation can overlap an earlier network send while dispatch preserves action order.
  function queueAction(request, discard, independent) {
    var queued = queuedActions.slice()
    for (var index = queued.length - 1; index >= 0; index--) {
      var previous = queued[index]
      if (previous.id !== request.id) continue
      if (!independent && previous.action === request.action && previous.cacheKey === request.cacheKey
          && previous.quiet === request.quiet && previous.memberOnly === request.memberOnly
          && previous.sourceLabelId === request.sourceLabelId) {
        discard(previous.token)
        return
      }
      break
    }
    queued.push(request)
    queuedActions = queued
  }

  function runQueuedAction() {
    if (pendingAction !== "" || queuedActions.length === 0) return
    var queued = queuedActions.slice()
    var next = queued.shift()
    queuedActions = queued
    next.dispatch()
  }

  function refuseUnavailableAction(action) {
    var needs = Model.actionCapability(action)
    if (needs === "" || actionCapabilities[needs] === true) return false
    var refused = Provider.refusal(providerId, needs, capabilityRefusals)
    note(refused !== "" ? refused : Model.actionUnavailable(action, Provider.badge(providerId)))
    return true
  }

  function intentView() {
    return {messages: messages, previewMessages: previewMessages,
      memberSummaries: memberSummaries, selectedId: selectedId,
      selectedMessage: selectedMessage, selectedThread: selectedThread,
      inboxUnread: inboxUnread}
  }

  function applyIntentView(view, query, selectedBefore) {
    if (!view) return
    if (query === cacheKey && !deferredLoadCleared(query)) {
      messages = hydrateSummaries(view.messages || [])
      previewMessages = hydrateSummaries(view.previewMessages || [])
      var members = view.memberSummaries || ({})
      for (var id in members) hydrateSummary(members[id])
      memberSummaries = members
      inboxUnread = Math.max(0, Number(view.inboxUnread) || 0)
    }
    if (selectedId === selectedBefore) {
      if (String(view.selectedId || "") === "") clearSelection()
      else if (view.selectedMessage) selectedMessage = hydrateSummary(view.selectedMessage)
    }
  }

  function act(id, action, quiet, memberOnly) {
    return runNativeAction([String(id || "")], action, quiet === true, memberOnly === true, false)
  }

  function runNativeAction(ids, action, quiet, memberOnly, allRead, completion) {
    if (!ready || !backend || (!allRead && ids.length === 0) || (allRead && messages.length === 0)) return false
    if (refuseUnavailableAction(action)) return false
    var reported = false
    var cancel = function() { finish(ids, "Account signed out") }
    function finish(failedIds, error) {
      if (reported) return
      reported = true
      root.actionCompletions = root.actionCompletions.filter(function(callback) { return callback !== cancel })
      if (typeof completion === "function") completion({failedIds: failedIds || [], error: String(error || "")})
    }
    if (typeof completion === "function") actionCompletions = actionCompletions.concat([cancel])
    var account = accountId
    var actionQuery = cacheKey
    var estimate = resultEstimate
    var oldPageToken = nextPageToken
    var interrupted = false
    function stopLiveList() {
      if (root.accountId !== account || root.cacheKey !== actionQuery || !root.listLoading) return
      interrupted = true
      root.listSerial++
      root.abortRequest(root.listHandle)
      root.listHandle = null
      root.listLoading = false
      root.nextPageToken = ""
      oldPageToken = ""
    }
    stopLiveList()
    var parameters = {accountId: account, query: actionQuery, action: action,
      ids: ids, allRead: allRead === true, quiet: quiet === true,
      memberOnly: memberOnly === true, mailboxKey: mailboxKey,
      rawQuery: rawQuery, hasLabels: hasLabels,
      sourceLabelId: hasLabels ? rawLabelId : "", capabilities: actionCapabilities,
      opaqueQuery: effectiveQuery !== Provider.mailboxFor(providerId, mailboxKey).query}
    var preparationEpoch = intents.epoch
    actionPreparations++
    if (pendingAction === "") pendingActionQuery = actionQuery
    intents.begin(parameters, function(prepared, error, selectedBefore) {
      if (root.accountId === account && preparationEpoch === intents.epoch)
        root.actionPreparations = Math.max(0, root.actionPreparations - 1)
      if (error || !prepared) {
        finish(ids, error || "Could not prepare the action")
        if (root.accountId === account && preparationEpoch === intents.epoch) {
          root.fail(error || "Could not prepare the action")
          if (root.actionPreparations === 0 && root.pendingAction === "") {
            var resumed = root.resumeDeferredListLoad(actionQuery, String(error || ""))
            if (!resumed && interrupted && root.cacheKey === actionQuery)
              root.loadMessages(false, true, String(error || ""))
          }
        }
        return
      }
      if (prepared.refused) {
        finish(ids, "This mailbox cannot perform that action")
        if (root.accountId === account && preparationEpoch === intents.epoch) {
          root.refuseUnavailableAction(action)
          if (root.actionPreparations === 0 && root.pendingAction === "") {
            var resumed = root.resumeDeferredListLoad(actionQuery, "")
            if (!resumed && interrupted && root.cacheKey === actionQuery) root.loadMessages(false, true, "")
          }
        }
        return
      }
      var targets = prepared.targets || []
      var rows = prepared.rows || []
      if (targets.length === 0) { finish(ids, "Those messages are no longer available"); return }
      if (root.accountId !== account || !root.ready || intents.generation !== prepared.generation) {
        finish(ids, "Account changed")
        intents.settle(account, actionQuery, prepared.token, rows, function() {}, prepared.generation)
        return
      }
      root.applyIntentView(prepared.view, actionQuery, selectedBefore)
      var invalidates = prepared.invalidatesPage === true || parameters.opaqueQuery
      if (root.cacheKey === actionQuery && invalidates) root.nextPageToken = ""
      if (root.cacheKey === actionQuery && !interrupted) root.rememberList()
      var optimisticToken = invalidates ? "" : oldPageToken
      function done(payload, failure, failedIds) {
        var failed = failure ? (Array.isArray(failedIds) ? failedIds : rows) : []
        intents.settle(account, actionQuery, prepared.token, failed, function(settled, settleError) {
          if (root.accountId !== account || intents.generation !== prepared.generation) {
            finish(ids, "Account changed")
            return
          }
          root.pendingAction = ""
          root.pendingActionQuery = ""
          var message = failure && Array.isArray(failedIds) && rows.length > 1
            ? Model.batchFailureNote(rows.length, failedIds.length, root.actionLabel(action), failure)
            : String(failure || settleError || "")
          if (failure && settled) root.applyIntentView(settled.view, actionQuery, selectedBefore)
          if (cacheStore.loaded) {
            cacheStore.invalidate(targets, function() {
              if (root.accountId !== account || !settled || !settled.view) return
              cacheStore.putQuery(actionQuery, {
                summaries: root.cacheKey === actionQuery ? root.messages
                  : root.hydrateSummaries(settled.view.messages || []), estimate: estimate,
                nextPageToken: failure && !Array.isArray(failedIds) ? oldPageToken : optimisticToken})
            })
          }
          if (message !== "") root.fail(message)
          else if (!quiet) {
            if (allRead) root.note(Model.markAllReadNote(rows.length, prepared.expanded === true))
            else root.note(rows.length > 1 ? Model.batchNote(rows.length, root.actionLabel(action)) : root.actionLabel(action))
          }
          root.refreshCounts()
          finish(settleError ? ids : failed, message)
          root.runQueuedAction()
          if (root.resumeDeferredListLoad(actionQuery, message)) return
          if (root.cacheKey === actionQuery && (interrupted || invalidates || message !== ""))
            root.loadMessages(false, true, message)
          else if (root.active && root.cacheKey !== actionQuery) root.loadMessages(false, true, "")
        }, prepared.generation)
      }
      function dispatch() {
        if (root.accountId !== account || !root.ready || intents.generation !== prepared.generation || !root.api) { done(null, "Account changed"); return }
        stopLiveList()
        root.pendingActionQuery = actionQuery
        root.pendingAction = action
        var change = prepared.change || {add: [], remove: []}
        if ((action === "trash" || action === "untrash") && rows.length > 1) {
          var remaining = rows.length
          var failures = []
          var firstError = ""
          function replyFor(rowId) {
            return function(payload, error) {
              if (error) { failures.push(rowId); if (firstError === "") firstError = String(error) }
              remaining--
              if (remaining === 0) done(null, firstError, failures)
            }
          }
          for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
            var rowTargets = prepared.targetsOf[rows[rowIndex]] || [rows[rowIndex]]
            var sent = rowTargets.length > 1 ? rowTargets : rowTargets[0]
            if (action === "trash") root.api.trashMessage(sent, replyFor(rows[rowIndex]))
            else root.api.untrashMessage(sent, replyFor(rows[rowIndex]))
          }
        } else if (action === "trash") root.api.trashMessage(targets.length > 1 ? targets : targets[0], done)
        else if (action === "untrash") root.api.untrashMessage(targets.length > 1 ? targets : targets[0], done)
        else if (targets.length > 1) root.api.batchModify(targets, change.add, change.remove, done)
        else root.api.modifyMessage(targets[0], change.add, change.remove, done)
      }
      if (root.pendingAction !== "") root.queueAction({id: JSON.stringify(ids), action: action,
        cacheKey: actionQuery, quiet: quiet, memberOnly: memberOnly, dispatch: dispatch,
        token: prepared.token, sourceLabelId: parameters.sourceLabelId}, function(intoToken) {
        intents.coalesce(account, actionQuery, prepared.token, intoToken, prepared.generation)
      }, typeof completion === "function")
      else dispatch()
    })
    return true
  }

  // Invariant: Persist optimistic state to the query cache so navigation cannot restore the pre-action row.
  function rememberList() {
    if (!listLoaded || !cacheStore.loaded) return
    cacheStore.putQuery(cacheKey, ({
      summaries: messages,
      estimate: resultEstimate,
      nextPageToken: nextPageToken
    }))
  }

  function actionLabel(action) {
    if (action === "archive") return "Archived"
    if (action === "trash") return "Moved to trash"
    if (action === "untrash") return "Restored"
    if (action === "star") return "Starred"
    if (action === "unstar") return "Unstarred"
    if (action === "markRead") return "Marked read"
    if (action === "markUnread") return "Marked unread"
    if (action === "unarchive") return "Moved to Inbox"
    if (action === "spam") return "Reported as spam"

    var target = Model.labelTarget(action)
    if (target !== "") return "Moved to " + labelName(target)
    return "Done"
  }

  // Invariant: A row star represents its conversation; a member star represents that message. Resolve the displayed scope before dispatch.
  function summaryOf(id) {
    var known = Model.messageById(messages, previewMessages, id)
    if (known) return known
    return memberSummaries[String(id || "")] || null
  }

  // Invariant: Move feedback uses the label name, falling back to its wire ID before labels load.
  function labelName(labelId) {
    var index = Model.indexById(labels, labelId)
    return index >= 0 ? labels[index].name : labelId
  }

  function toggleStar(id) {
    var summary = summaryOf(id)
    if (!summary) return
    act(id, summary.starred ? "unstar" : "star")
  }

  function toggleRead(id) {
    var summary = summaryOf(id)
    if (!summary) return
    act(id, summary.unread ? "markRead" : "markUnread")
  }

  function markAllRead() {
    return runNativeAction([], "markRead", false, false, true)
  }

  function actMany(ids, action, completion) { return batchAction.run(ids, action, completion) }

  BatchAction {
    id: batchAction
    account: root
    intents: intents
  }

  Intents {
    id: intents
    account: root
  }

  // Invariant: Forwarding claims an attachment only after its bytes or retained native handle have loaded.
  function loadAttachments(messageId, attachments, callback, draftKey) {
    var listed = Array.isArray(attachments) ? attachments : []
    if (listed.length === 0) {
      if (typeof callback === "function") callback([], "")
      return []
    }
    var remaining = listed.length
    var loaded = new Array(listed.length)
    var handles = []
    var firstError = ""
    function loadAttachment(index) {
      var source = listed[index] || ({})
      if (draftKey && backend && backend.ready && Number(backend.apiVersion)>=8 && providerId!=="hey") {
        handles.push(backend.call("attachment.retain",{accountId:accountId,draftKey:String(draftKey),
          messageId:String(messageId),attachmentId:String(source.attachmentId || ""),
          filename:String(source.filename || "attachment"),mimeType:String(source.mimeType || "application/octet-stream")},function(result,error) {
            if (error && firstError === "") firstError = "Could not include " + String(source.filename || "an attachment")
            loaded[index] = result
            remaining--
            if (remaining === 0 && typeof callback === "function") callback(loaded,firstError)
        }))
        return
      }
      handles.push(api.getAttachment(messageId, String(source.attachmentId || ""),
        function(data, error) {
          if (error && firstError === "")
            firstError = "Could not include " + String(source.filename || "an attachment")
              + ": " + error
          loaded[index] = ({
            filename: String(source.filename || "attachment"),
            mimeType: String(source.mimeType || "application/octet-stream"),
            size: Math.max(0, Math.floor(Number(source.size) || 0)),
            data: String(data || "")
          })
          remaining--
          if (remaining === 0 && typeof callback === "function")
            callback(loaded, firstError)
        }))
    }
    for (var attachmentIndex = 0; attachmentIndex < listed.length; attachmentIndex++)
      loadAttachment(attachmentIndex)
    return handles
  }

  function previewAttachment(messageId, attachment, callback) {
    return resources.previewAttachment(messageId,attachment,callback)
  }

  function openAttachment(messageId, attachment) {
    var source = attachment || ({})
    if (!ready) {
      fail("Sign in before opening an attachment")
      return
    }
    if (String(messageId || "") === "" || String(source.attachmentId || "") === "") {
      fail("That attachment is not available")
      return
    }
    if (backend && backend.ready && Number(backend.apiVersion)>=8) {resources.downloadAttachment(messageId,source,true);return}
    clearNotice()
    loadAttachments(messageId, [source], function(loaded, error) {
      if (error || !loaded || loaded.length === 0) {
        root.fail(error || "That attachment could not be loaded")
        return
      }
      var file = loaded[0]
      if (!root.backend || !root.backend.ready) {
        root.fail("Mail backend unavailable")
        return
      }
      root.backend.call("attachment.store", {
        filename: String(file.filename || "attachment"), data: String(file.data || ""), open: true
      }, function(result, failure) {
        if (!root) return
        if (failure || !result || !result.path) {
          root.fail(failure && failure.message === "attachment_open_refused"
            ? "That attachment is not something this can open" : "That attachment could not be opened")
          return
        }
        if (root.platform && typeof root.platform.openExternal === "function")
          root.platform.openExternal(String(result.path))
        root.note("Opening " + String(file.filename || "attachment"))
      })
    })
  }

  function saveAttachment(messageId, attachment) {
    var source = attachment || ({})
    if (!ready) {
      fail("Sign in before saving an attachment")
      return
    }
    if (String(messageId || "") === "" || String(source.attachmentId || "") === "") {
      fail("That attachment is not available")
      return
    }
    if (backend && backend.ready && Number(backend.apiVersion)>=8) {resources.downloadAttachment(messageId,source,false);return}
    // Invariant: One in-flight save per attachment prevents duplicate numbered files from repeated clicks.
    var key = String(source.attachmentId)
    if (savingAttachmentIds[key]) return
    markSavingAttachment(key, true)
    clearNotice()
    note("Saving " + String(source.filename || "attachment"))
    loadAttachments(messageId, [source], function(loaded, error) {
      if (error || !loaded || loaded.length === 0) {
        root.markSavingAttachment(key, false)
        root.fail(error || "That attachment could not be loaded")
        return
      }
      var file = loaded[0]
      if (!root.backend || !root.backend.ready) {
        root.markSavingAttachment(key, false)
        root.fail("Mail backend unavailable")
        return
      }
      root.backend.call("attachment.store", {
        filename: String(file.filename || "attachment"), data: String(file.data || ""), open: false
      }, function(result, failure) {
        if (!root) return
        root.markSavingAttachment(key, false)
        if (failure || !result || !result.path) {
          root.fail("That attachment could not be saved")
          return
        }
        // Invariant: Report the actual unique filename before its folder so truncation cannot hide a renamed download.
        var saved = String(result.path || "")
        var at = saved.lastIndexOf("/")
        root.note(at > 0
          ? "Saved " + saved.substring(at + 1) + " to " + saved.substring(0, at)
          : "Saved")
      })
    })
  }

  // Invariant: Replace the saving-attachments object so QML bindings notice additions and removals.
  function markSavingAttachment(key, saving) {
    var next = Object.create(null)
    for (var id in savingAttachmentIds)
      if (id !== key) next[id] = true
    if (saving) next[key] = true
    savingAttachmentIds = next
  }

  // Invariant: Every terminal send failure emits replyFailed so the parked composer draft can be restored, including readiness loss during undo.
  function reportSendFailure(error, sendId) {
    fail(error)
    // Invariant: Defer terminal signals until ComposeView has returned from send() and parked the accepted draft, even for synchronous provider replies.
    Qt.callLater(function() {
      if (root) root.replyFailed(String(sendId || ""))
    })
  }

  function reportSendSuccess(result, sendId) {
    // Invariant: Failure to file the sent copy is a warning on a successful delivery, not a failed send.
    var warning = result && result.warning ? String(result.warning) : ""
    note(warning !== "" ? warning : "Sent")
    // Invariant: Success observes the same composer-parking order as failure.
    Qt.callLater(function() {
      if (root) root.replySent(String(sendId || ""))
    })
  }

  function sentDraftRemoved(draftId) {
    if (Model.indexById(messages, draftId) >= 0) {
      messages = Model.removeById(messages, draftId)
      rememberList()
    }
    if (selectedId === draftId) clearSelection()
    refreshCounts()
  }

  function deliverPending() { return sendQueue.deliverAll() }

  function undoSend(callback) { return sendQueue.undoLatest(callback) }

  SendQueue {
    id: sendQueue
    account: root
  }

  // Invariant: Retry credential lookup before save/send readiness checks so recoverable token refusal cannot discard the operation.
  function whenReady(callback) {
    if (ready) { callback(true); return }
    if (!auth || !auth.configured || auth.loginBusy || typeof auth.withCredentials !== "function") {
      callback(false)
      return
    }
    auth.withCredentials(function(credentials, error) {
      if (!root) return
      callback(!!credentials && root.ready)
    })
  }

  function saveDraft(fields, callback) {
    if (!ready) {
      whenReady(function(ok) {
        if (!root) return
        if (ok) root.saveDraft(fields, callback)
        else if (typeof callback === "function") callback(null, "The mailbox is not ready to save drafts")
      })
      return null
    }
    if (!api || typeof api.saveDraft !== "function") {
      if (typeof callback === "function") callback(null, "The mailbox is not ready to save drafts")
      return null
    }
    var values = fields || ({})
    var from = String(values.from || "").trim()
    var alias = from === "" ? null : Api.sendAsFor(availableSendAsAliases, from)
    if (from !== "" && !alias) {
      if (typeof callback === "function") callback(null, "Choose a valid From address")
      return null
    }
    var composeFields = ({
      draftKey: String(values.draftKey || ""),
      from: from,
      fromName: alias ? String(alias.displayName || "") : "",

      accountAddress: ownAddress,
      to: String(values.to || "").trim(),
      cc: String(values.cc || "").trim(),
      bcc: String(values.bcc || "").trim(),
      replyTo: String(values.replyTo || "").trim(),
      signature: String(values.signature || ""),
      signatureHtml: String(values.signatureHtml || ""),
      subject: String(values.subject || ""),
      body: String(values.body || ""),
      attachments: Array.isArray(values.attachments) ? values.attachments : [],
      threadId: values.threadId,
      inReplyTo: values.inReplyTo,
      references: values.references,
      draftId: String(values.draftId || "")
    })
    var handle = {aborted: false, children: []}
    var account = accountId
    if (!backend) { if (typeof callback === "function") callback(null, "Mail backend is unavailable"); return handle }
    if (Number(backend.apiVersion)>=8 && providerId!=="hey") {
      var nativeJob=backend.call("draft.compose",{accountId:account,fields:composeFields},function(saved,error) {
        if (handle.aborted || account!==root.accountId) return
        if (typeof callback === "function") callback(saved,error ? "Could not save this draft online. Your local draft has been kept." : "")
        if (!error && root.mailboxKey==="drafts") root.loadMessages(false,true,"")
        else if (!error) root.refreshCounts()
      })
      if (nativeJob) handle.children.push(nativeJob)
      return handle
    }
    backend.call("message.compose", {fields: composeFields}, function(payload, composeError) {
      if (handle.aborted || account !== root.accountId) return
      if (composeError || !payload) {
        if (typeof callback === "function") callback(null, "Could not prepare this draft")
        return
      }
      var child = root.api.saveDraft(payload, function(saved, error) {
      if (handle.aborted || account !== root.accountId) return
      if (typeof callback === "function") callback(saved, error)
      // Invariant: Refresh Drafts after replacement so the old server row and its newly saved successor cannot coexist.
      if (!error && root && root.mailboxKey === "drafts") {
        root.listSerial++
        root.nextPageToken = ""
        root.loadMessages(false, true, "")
      } else if (!error && root) {
        root.refreshCounts()
      }
      })
      if (child) handle.children.push(child)
    })
    return handle
  }

  readonly property string sendSession: Date.now().toString(36) + "-" + Math.random().toString(36).slice(2)

  function send(fields, sendId, order) {
    var id = String(sendId || "")
    if (id === "") {
      sendQueue.serial += 1
      id = "send-" + sendSession + "-" + sendQueue.serial
    }
    if (!ready) {

      whenReady(function(ok) {
        if (!root) return
        if (ok) root.send(fields, id, order)
        else root.reportSendFailure("The mailbox is not ready to send", id)
      })
      return id
    }
    var values = fields || ({})
    var files = Array.isArray(values.attachments) ? values.attachments : []
    var hasFiles = false
    for (var fi = 0; fi < files.length; fi++) {
      if (files[fi] && (files[fi].data || files[fi].path || files[fi].handle)) hasFiles = true
    }
    var body = String(values.body || "")
    if (values.exactBody !== true) body = body.trim()
    if (body.trim() === "" && !hasFiles) {
      fail("Write something before sending")
      return false
    }
    var to = String(values.to || "").trim()
    if (to === "") {
      fail("Add a recipient first")
      return false
    }
    // Invariant: Sender display names come from the validated owned-alias list, not composer input.
    var from = String(values.from || "").trim()
    var alias = from === "" ? null : Api.sendAsFor(availableSendAsAliases, from)
    if (from !== "" && !alias) {
      fail("Choose a valid From address")
      return false
    }
    var composeFields = ({
      draftKey: String(values.draftKey || ""),
      from: from,
      fromName: alias ? String(alias.displayName || "") : "",

      accountAddress: ownAddress,
      to: to,
      cc: String(values.cc || "").trim(),
      bcc: String(values.bcc || "").trim(),
      replyTo: String(values.replyTo || "").trim(),
      signature: String(values.signature || ""),
      signatureHtml: String(values.signatureHtml || ""),
      subject: String(values.subject || ""),
      body: body,
      attachments: Array.isArray(values.attachments) ? values.attachments : [],
      threadId: values.threadId,
      inReplyTo: values.inReplyTo,
      references: values.references,
      // Invariant: Keep the replaced draft ID through undo and delivery so success can remove the original draft.
      draftId: String(values.draftId || "")
    })
    var account = accountId
    if (!backend) { reportSendFailure("Mail backend is unavailable", id); return "" }
    if (Number(backend.apiVersion) >= 8) {
      if (!sendQueue.park(null,id,order,composeFields)) reportSendFailure("Could not queue this message",id)
      return id
    }
    backend.call("message.compose", {fields: composeFields}, function(payload, error) {
      if (account !== root.accountId) return
      if (error || !payload) { root.reportSendFailure("Could not prepare this message", id); return }
      payload.draftId = String(values.draftId || "")
      payload.sendId = id
      if (!sendQueue.park(payload, id, order)) root.reportSendFailure("Could not queue this message", id)
    })
    return id
  }

  signal replySent(string sendId)

  // Invariant: replyFailed restores the parked draft, which may be the only remaining editable copy.
  signal replyFailed(string sendId)

  function rsvp(response) { rsvpAction.run(response) }
  readonly property bool rsvpFallbackAvailable: rsvpAction.fallbackAvailable
  function rsvpMailOnly(response) { rsvpAction.run(response, true) }
  readonly property alias bodies: bodyCache

  Rsvp {
    id: rsvpAction
    account: root
  }

  function unsubscribe() { unsubscribeAction.run() }

  Unsubscribe {
    id: unsubscribeAction
    account: root
  }

  property string notificationForeground: ""
  property string notificationAccent: ""
  signal notificationActivated(string targetAccountId, string messageId)

  NewMailNotification {
    id: newMailNotification
    pluginDir: root.pluginDir
    accountId: root.accountId
    notificationForeground: root.notificationForeground
    notificationAccent: root.notificationAccent
    nativeNotifications: !!root.platform && root.platform.standalone === true
      && root.platform.hasNotifications === true
    pluginNotifications: !root.platform || root.platform.standalone !== true
    onActivated: function(accountId, messageId) {
      root.notificationActivated(accountId, messageId)
    }
  }

  function notify(arrivals) { newMailNotification.notify(arrivals) }
  readonly property alias labelActions: labelActions

  signal monitoredMigrated(var ids)

  LabelActions {
    id: labelActions
    account: root
  }

  function selectMailbox(key) {
    providerLabelSerial++
    providerQuerySerial++
    submittedSearchSession.clear()
    if (mailboxKey === key && searchQuery === "" && rawQuery === "") return
    mailboxKey = String(key || "inbox")
    searchQuery = ""
    searchRaw = ""
    rawQuery = ""
    rawLabelId = ""
    clearSelection()
    messages = []
    previewMessages = []
    loadedDepth = 0
    listLoaded = false
    loadMessages(false)
  }

  // Invariant: App-built raw queries bypass typed-search conversion.
  function search(text, raw, reference) {
    var referenceTime = Number(reference) || Date.now()
    var query = String(text || "").trim()
    var built = String(raw || "").trim()
    if (submittedSearchSession.available && query !== "" && built === "") {
      if (query === submittedSearchSession.requestedQuery && (submittedSearchSession.phase === "local"
          || submittedSearchSession.phase === "checking" || submittedSearchSession.phase === "preparing")) return
      submittedSearchSession.prepare(query, referenceTime)
    } else if (query === searchQuery && built === searchRaw && rawQuery === ""
        && submittedSearchSession.phase === "") return
    providerLabelSerial++
    var serial = ++providerQuerySerial
    if (query !== "" && built === "") {
      if (!backend || !backend.ready) return
      var boundAccount = accountId
      var input = providerQueryInput
      var parameters = {provider: providerId, operation: "query", mailbox: mailboxKey,
        search: query, defaultQuery: defaultQuery}
      if (submittedSearchSession.available) { parameters.accountId = accountId; parameters.asOf = referenceTime }
      backend.call("providers.resolve", parameters, function(result, error) {
        if (!root || serial !== root.providerQuerySerial || boundAccount !== root.accountId
            || input !== root.providerQueryInput) return
        if (error) {
          if (root.submittedSearch.available) root.submittedSearch.reject("Could not prepare this search. Try again.")
          else root.note("Could not prepare this search")
          return
        }
        if (root.submittedSearch.available && result && result.search && result.search.valid === false) {
          root.submittedSearch.reject(String(result.search.message || "Check quotes, groups and filter values, then try again."))
          return
        }
        root.applySearch(query, String((result || {}).value || ""), referenceTime)
      })
      return
    }
    applySearch(query, built, referenceTime)
  }

  signal searchStarted()

  function applySearch(query, built, reference) {
    searchStarted()
    legacySearchStopped = false
    var changed = query !== searchQuery || built !== searchRaw || rawQuery !== ""
    submittedSearchSession.clear()
    searchQuery = query
    searchRaw = built
    rawQuery = ""
    rawLabelId = ""
    if (changed) {
      clearSelection()
      messages = []
      loadedDepth = 0
      listLoaded = false
    }
    if (query !== "" && submittedSearchSession.available) {
      submittedSearchSession.start(effectiveQuery, reference)
      return
    }
    loadMessages(false)
  }

  function stopSearch() {
    if (submittedSearchSession.active || submittedSearchSession.phase !== "") { submittedSearchSession.stop(); return }
    if (!searchQuery || rawQuery) return
    providerQuerySerial++
    listSerial++
    abortRequest(listHandle)
    listHandle = null
    listLoading = false
    legacySearchStopped = true
  }
  function retrySearch() {
    if (submittedSearchSession.active || submittedSearchSession.phase !== "") { submittedSearchSession.retry(); return }
    if (!searchQuery || rawQuery || listLoading) return
    legacySearchStopped = false
    loadMessages(false, true)
  }

  function selectLabel(name, labelId) {
    providerQuerySerial++
    if (!backend || !backend.ready) return
    var serial = ++providerLabelSerial
    var boundAccount = accountId
    var boundProvider = providerId
    backend.call("providers.resolve", {provider: providerId, operation: "labelQuery", value: String(name || "")}, function(result, error) {
      if (serial !== root.providerLabelSerial || boundAccount !== root.accountId || boundProvider !== root.providerId || error) return
      var query = String((result || {}).value || "")
      var id = String(labelId || "")
      if (query === "" || (query === root.rawQuery && id === root.rawLabelId)) return
      root.submittedSearch.clear()
      root.searchQuery = ""
      root.searchRaw = ""
      root.rawQuery = query
      root.rawLabelId = id
      root.clearSelection()
      root.messages = []
      root.loadedDepth = 0
      root.listLoaded = false
      root.loadMessages(false)
    })
  }

  function openProviderUrl(operation, value) {
    if (!backend || !backend.ready) return
    var boundAccount = accountId
    var boundProvider = providerId
    backend.call("providers.resolve", {provider: providerId, operation: operation, value: String(value || "")}, function(result, error) {
      if (error || boundAccount !== root.accountId || boundProvider !== root.providerId) return
      var url = String((result || {}).value || "")
      if (url !== "" && root.platform && typeof root.platform.openExternal === "function")
        root.platform.openExternal(url)
    })
  }

  function openInBrowser(id) { openProviderUrl("webMessageUrl", id) }
  function openWebInbox() { openProviderUrl("webBoxUrl", effectiveQuery) }

  function openCloudConsole() {
    if (root.platform && typeof root.platform.openExternal === "function")
      root.platform.openExternal("https://console.cloud.google.com/auth/clients/create")
  }

  function openConsentScreen() {
    if (root.platform && typeof root.platform.openExternal === "function")
      root.platform.openExternal("https://console.cloud.google.com/auth/overview")
  }

  function openGmailApiPage() {
    if (root.platform && typeof root.platform.openExternal === "function")
      root.platform.openExternal("https://console.cloud.google.com/apis/library/gmail.googleapis.com")
  }

  function afterSignIn() {
    loadProfile()
    loadLabels()
    loadSendAs()
    refreshCounts()
    loadMessages(false)
  }

  function signIn() { if (auth) auth.beginLogin() }
  function withAccessToken(callback) {
    if (providerId !== "gmail" || !auth) {
      callback("", "This is not a Google account")
      return
    }
    auth.withAccessToken(callback)
  }
  function cancelSignIn() { if (auth) auth.cancelLogin() }

  function signInWithPassword(secret) {
    if (!auth || !Provider.usesPassword(providerId)) return false
    return auth.signIn(secret)
  }

  function signOut() {
    intents.clear()
    cancelActionCompletions()
    queuedActions = []
    actionPreparations = 0
    pendingAction = ""
    pendingActionQuery = ""
    if (auth) auth.logout()
    messages = []
    loadedDepth = 0
    labels = []
    sendAsAliases = []
    sendAsLoading = false
    sendAsLoaded = false
    profile = null
    inboxUnread = 0
    listLoaded = false
    seenIds = Object.create(null)
    arrivalFloor = 0
    notificationsPrimed = false
    countPrimed = false
    cacheStore.clear()
    bodyCache.clear()
    clearSelection()
  }

  function cancelActionCompletions() {
    var callbacks = actionCompletions
    actionCompletions = []
    for (var callbackIndex = 0; callbackIndex < callbacks.length; callbackIndex++) callbacks[callbackIndex]()
  }
  Component.onDestruction: {
    cancelConversation()
    cancelActionCompletions()
  }

  onWindowOpenChanged: {
    if (!windowOpen) return
    clearNotice()
    if (!ready) return
    loadProfile()
    loadSendAs()
    if (!listLoaded) loadMessages(false)
    else refresh()
  }

  onReadyChanged: {
    if (!ready) return
    loadProfile()
    loadSendAs()
    refreshCounts()
    if (!active) return
    loadLabels()
    if (windowOpen && !listLoaded) loadMessages(false)
  }

  onActiveChanged: {
    if (!active || !ready) return
    loadLabels()
    loadSendAs()
    if (!listLoaded) loadMessages(false)
    else refresh()
  }

  // Invariant: Derive account identity with Accounts.accountId so provider prefixes match Service.findAccount and credential/cache ownership.
  onAccountEmailChanged: {
    if (accountEmail !== "" && accountId === "")
      accountId = Accounts.accountId(accountEmail, providerId)
  }

  signal accountIdentified(string email)

  // Invariant: Persist learned server settings through the owning account entry; this object only holds its bound copy.
  signal serverSettingsLearned(var jmap)

  // Invariant: Instantiate only the selected provider pair so another provider cannot probe dependencies or credentials.
  property bool providerLoadersReady: false
  property Component clientOverride: null

  function loadProvider() {
    apiLoader.active = false
    var component = providerId === "imap" ? imapAuthComponent
      : (providerId === "jmap" ? jmapAuthComponent
      : (providerId === "outlook" ? outlookAuthComponent
        : (providerId === "hey" ? heyAuthComponent : gmailAuthComponent)))
    if (authLoader.sourceComponent === component) loadClient()
    else authLoader.sourceComponent = component
  }

  function loadClient() {
    apiLoader.active = false
    apiLoader.sourceComponent = clientOverride ? clientOverride
      : (providerId === "imap" || providerId === "outlook" ? imapClientComponent
        : (providerId === "jmap" ? jmapClientComponent
          : (providerId === "hey" ? heyClientComponent : gmailClientComponent)))
    apiLoader.active = !!authLoader.item
  }

  onProviderIdChanged: if (providerLoadersReady) loadProvider()
  onClientOverrideChanged: if (providerLoadersReady) loadClient()
  Component.onCompleted: {
    providerLoadersReady = true
    loadProvider()
  }

  Loader {
    id: authLoader
    onLoaded: root.loadClient()
  }
  Loader {
    id: apiLoader
    active: false
  }

  Component {
    id: gmailAuthComponent

    AuthManager {
      backend: root.backend
      platform: root.platform
      pluginDir: root.pluginDir
      accountId: root.accountId
      mayAdoptLegacyToken: root.mayAdoptLegacyToken
      oauthPort: root.oauthPort
      loginHint: root.accountEmail

      onLoginSucceeded: {
        root.lastError = lastError
        root.afterSignIn()
      }
      onLoggedOut: root.clearNotice()
      onCredentialsSaved: root.note("OAuth client saved")
      onSessionUnavailable: function(reason) { root.fail(reason) }
    }
  }

  Component {
    id: imapAuthComponent

    ImapAuth {
      backend: root.backend
      platform: root.platform
      pluginDir: root.pluginDir
      accountId: root.accountId
      // Invariant: Normalize persisted server settings at the connection boundary just as setup input is normalized.
      settings: Imap.normalizeSettings(root.imapSettings)

      onLoginSucceeded: {
        root.lastError = lastError
        root.afterSignIn()
      }
      onLoggedOut: root.clearNotice()
      onCredentialsSaved: root.note("Mailbox saved")
      onSessionUnavailable: function(reason) { root.fail(reason) }
    }
  }

  Component {
    id: jmapAuthComponent

    JmapAuth {
      backend: root.backend
      platform: root.platform
      pluginDir: root.pluginDir
      accountId: root.accountId
      // Invariant: JMAP discovery requires the configured address before it can derive the server domain.
      address: root.configuredEmail
      settings: Accounts.makeJmapSettings(root.jmapSettings)

      // Invariant: Verified JMAP settings update the owning account entry so its binding survives reload.
      onSessionVerified: function(result) {
        root.serverSettingsLearned(Accounts.jmapSettingsAfterSignIn(settings, result))
      }
      onLoginSucceeded: {
        root.lastError = lastError
        root.afterSignIn()
      }
      onLoggedOut: root.clearNotice()
      onCredentialsSaved: root.note("Mailbox saved")
      onSessionUnavailable: function(reason) { root.fail(reason) }
    }
  }

  Component {
    id: heyAuthComponent

    HeyAuth {
      backend: root.backend
      pluginDir: root.pluginDir
      accountId: root.accountId

      onLoginSucceeded: {
        root.lastError = lastError
        root.afterSignIn()
      }
      onLoggedOut: root.clearNotice()
      onCredentialsSaved: root.note("Mailbox saved")
      onSessionUnavailable: function(reason) { root.fail(reason) }
    }
  }

  Component {
    id: outlookAuthComponent

    OutlookAuth {
      platform: root.platform
      backend: root.backend
      pluginDir: root.pluginDir
      accountId: root.accountId
      configuredClientId: root.oauthClientId
      configuredEmail: root.configuredEmail
      entrySettings: root.imapSettings

      onLoginSucceeded: {
        root.lastError = lastError
        root.afterSignIn()
      }
      onLoggedOut: root.clearNotice()
      onSessionUnavailable: function(reason) { root.fail(reason) }
      onGraphRefused: function(reason) { root.note(reason) }
    }
  }

  Component {
    id: gmailClientComponent
    GmailApiClient { auth: authLoader.item; backend: root.backend }
  }

  Component {
    id: heyClientComponent
    HeyClient { auth: authLoader.item; backend: root.backend }
  }

  Component {
    id: imapClientComponent
    ImapClient {
      auth: authLoader.item
      email: root.configuredEmail
      backend: root.backend
    }
  }

  Component {
    id: jmapClientComponent
    JmapClient {
      backend: root.backend
      auth: authLoader.item
      email: root.configuredEmail
      // Invariant: A JMAP session is cached server state, not persisted account configuration.
      cache: cacheStore

      // Invariant: Apply remote mailbox changes before refreshing mail so new messages can resolve their mailbox rows.
      onRemoteChanged: function(plan) {
        if (!root.ready || !plan) return
        if (plan.mailboxes) root.loadLabels()
        if (plan.mail) root.refresh()
      }
    }
  }

  CacheStore {
    id: cacheStore
    backend: root.backend
    accountId: root.accountId

    onRestored: {
      if (!root.profile && store.profile) root.profile = store.profile
      if (root.labels.length === 0 && store.labels.length > 0) root.labels = store.labels
      if (root.messages.length === 0) root.paintFromCache()
    }
  }

  BackendSync {
    id: backendSync
    backend: root.backend
    watchEnabled: root.ready && root.nativePolling && !localMailbox.available
    accountId: root.accountId
    query: Provider.unreadQuery(root.providerId)
    intervalSec: root.refreshIntervalSec
    pageSize: root.maxMessages
    onUpdated: function(snapshot) {
      if (snapshot.error) return
      root.summarizeResources(snapshot.messages || [], function(prepared, preparationError) {
      if (preparationError) return
      var before = root.inboxUnread
      root.inboxUnread = snapshot.estimate
      var summaries = []
      var payloads = prepared
      for (var payloadIndex = 0; payloadIndex < payloads.length; payloadIndex++) {
        var summary = payloads[payloadIndex].nativeSummary
        summary.unread = true
        summaries.push(summary)
      }
      if (summaries.length > 0 || snapshot.estimate === 0) root.previewMessages = summaries
      var fingerprint = String(snapshot.fingerprint || "")
      var changed = fingerprint !== "" && fingerprint !== root.syncFingerprint
      root.syncFingerprint = fingerprint
      var first = !root.countPrimed
      root.countPrimed = true
      if ((first || changed || snapshot.estimate > before || (root.active && root.windowOpen)) && !root.listLoading)
        root.loadMessages(false)
      })
    }
  }

  BodyCache {
    id: bodyCache
    backend: root.backend
    pluginDir: root.pluginDir
    accountId: root.accountId
  }

  // Invariant: Restore authentication after its loader creates the manager, not when the enclosing account completes.
  onAuthChanged: if (auth) auth.restoreSession()

  // Performance: Batch completed image paints without waiting for a slower queued image.
  Timer {
    id: imagePaintTimer
    interval: 100
    repeat: false
    onTriggered: root.flushRemoteImages()
  }

  Timer {
    interval: 30000
    running: root.ready
    repeat: true
    onTriggered: root.syncTick++
  }

  Timer {
    id: noticeTimer
    interval: 4000
    onTriggered: root.actionStatus = ""
  }

  // Invariant: Unread polling continues while the panel is closed so the bar badge remains current.
  Timer {
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    running: root.ready && !root.nativePolling
    repeat: true
    triggeredOnStart: true
    onTriggered: {

      root.refreshCounts()
      if (root.active && root.windowOpen) root.loadMessages(false)
    }
  }
}

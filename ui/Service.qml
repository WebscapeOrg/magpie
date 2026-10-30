import QtQuick
import "settings"
import "compose/Recipients.js" as AgentRecipients
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "account"
import "agent"
import "inbox"
import "backend"
import "diagnostics"
import "agent/Agent.js" as Agent

import "account/Accounts.js" as Accounts
import "account/Model.js" as Model
import "account/Unified.js" as Unified
import "account/SearchState.js" as SearchState
import "providers/Registry.js" as Provider
import "providers/Credentials.js" as CredentialKeys
import "providers/Secrets.js" as SecretText
import "bar/Preview.js" as Preview
import "bar/Bridge.js" as BarBridge
import "message/Outbox.js" as Outbox
import "message/Html.js" as Html
import "message/Direction.js" as Direction
import "message/CalendarHandoff.js" as CalendarHandoff
import "settings/Appearance.js" as Appearance
import "settings/Display.js" as Display

// Invariant: Account hosts own polling and caches; this service forwards the active or unified view.
Item {
  id: root
  readonly property var inboxTools: inboxController
  InboxTools { id: inboxController; service: root }

  visible: false
  width: 0
  height: 0

  // Invariant: The shell injects these four properties; plugin settings arrive later through the bar widget.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null
  // Invariant: Native hosts supply the platform adapter; the plugin shell leaves it unset.
  property var platform: null
  property var initialSettings: null
  property int configWrites: 0
  property int persistenceFailureRevision: 0
  readonly property bool persistencePending: configWrites > 0 || accountsWriting
    || accountsSaveQueued || accountsReading || accountsReloadQueued || windowWriting
    || windowPrefsSettling.running || sending || runningActionCount > 0 || queuedActionCount > 0
  readonly property var capabilities: platform && platform.capabilities
    ? platform.capabilities : ({ agent: true, tray: true, mailto: true, notifications: true })
  readonly property bool standalone: !!platform && platform.standalone === true
  readonly property bool smokeTest: standalone
    && Quickshell.env("OMAMAIL_SMOKE_TEST") === "1"

  // Invariant: The runtime and backend process outlive individual windows.
  readonly property var backendRuntime: privateRuntime
  Runtime {
    id: privateRuntime
    pluginDir: root.pluginDir
    bundledExecutable: root.standalone ? String(root.platform.backendPath || "") : ""
    bundledVersion: root.standalone ? root.version : ""
    bundledApiVersion: Number(bundledContract.releasedApiVersion || 0)
    bundledContract: root.standalone ? root.platform.backendContract || ({}) : ({})
    bundledMode: root.standalone
    developmentExecutable: root.standalone ? "" : (Quickshell.env("OMAMAIL_BIN") || "")
    onValidated: Qt.callLater(rustBackend.reconcileProcess)
  }
  readonly property var backend: rustBackend
  readonly property bool diagnosing: !!diagnosticsLoader.item && diagnosticsLoader.item.busy
  function diagnoseError() {
    if (hasAgent && diagnosticsLoader.item) diagnosticsLoader.item.open()
  }
  Loader {
    id: diagnosticsLoader
    active: root.hasAgent
    sourceComponent: Component {
      Diagnostics {
        objectName: "diagnostics"
        pluginDir: root.pluginDir
        onFailed: function(message) { if (root.current) root.current.fail(message) }
      }
    }
  }
  Backend {
    id: rustBackend
    // Invariant: Launch the runtime-validated path, which may resolve plugin symlinks.
    executable: privateRuntime.executable
    launchEnabled: !root.smokeTest && privateRuntime.state === "ready" && executable !== ""
    expectedVersion: privateRuntime.requiredVersion
    expectedApiVersion: privateRuntime.requiredApiVersion
    latestApiVersion: privateRuntime.latestApiVersion
    unreleasedMethods: privateRuntime.unreleasedMethods
    expectedContractHash: privateRuntime.contractHash
    onReadyChanged: root.scheduleUnifiedSnapshot()
    onRequestFailed: function(method, error) {
      if (diagnosticsLoader.item) diagnosticsLoader.item.record(method, error)
    }
  }

  // Invariant: Feature gates use fixed API minima; overall update status is diagnostic.
  readonly property bool backendNeedsUpdate: backend.needsUpdate
  // Invariant: Event suggestions require API 2 even after that revision is released.
  readonly property bool backendCanSuggestEvents: backend.ready && backend.apiVersion >= 2


  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "magpie"
  // Invariant: Omarchy strips private manifest metadata; resolve helpers relative to the plugin root.
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".."))
    .replace(/^file:\/\//, "")).replace(/\/$/, "")
  // Invariant: An absent manifest version stays empty rather than reporting a guessed build.
  readonly property string pluginName: manifest && manifest.name
    ? String(manifest.name) : "Magpie"
  readonly property string version: manifest && manifest.version
    ? String(manifest.version) : ""

  readonly property var defaultSettingValues: ({
    refreshIntervalSec: 120,
    maxMessages: 50,
    heavyMessageRendering: Html.HEAVY_MESSAGE_RENDERING_DEFAULT,
    contentDirection: Direction.MODE_DEFAULT,
    appearance: Appearance.MODE_DEFAULT,
    defaultQuery: "in:inbox",
    notifyNewMail: "On",
    oauthPort: 9481,
    undoSendSeconds: 10,
    showBarIcon: true,
    unifiedMailboxes: false,
    suggestEvents: false,
    aiAgent: "System default",
    aiModel: ""
  })
  function normalizedSettings(values) {
    var next = ({})
    for (var key in defaultSettingValues) next[key] = defaultSettingValues[key]
    var source = values || ({})
    for (var name in source) {
      if (source[name] !== undefined && source[name] !== null) next[name] = source[name]
    }
    return next
  }
  // Invariant: Apply initial settings before child accounts start activity.
  property var settings: normalizedSettings(initialSettings)
  readonly property int undoSendSeconds: Outbox.normalizeDelay(
    settings ? settings.undoSendSeconds : Outbox.DEFAULT_DELAY_SECONDS)
  readonly property bool alwaysRenderHeavyMessages: Html.alwaysRenderHeavyMessages(
    settings ? settings.heavyMessageRendering : null)
  readonly property bool notifyNewMail: String(settings ? settings.notifyNewMail : "On") !== "Off"
  // Invariant: Host capability controls AI visibility; the resolved provider controls availability.
  readonly property bool hasAgent: capabilities.agent === true
  readonly property bool agentAvailable: hasAgent && agentRunner.providerAvailable === true
  readonly property string agentUnavailableReason: agentRunner.availabilityError || "AI is unavailable."
  readonly property bool hasTray: capabilities.tray === true
  readonly property bool hasMailto: capabilities.mailto === true
  readonly property bool hasNotifications: capabilities.notifications === true
  // Invariant: The Omarchy plugin uses the shell palette; only a standalone host chooses appearance.
  readonly property bool hasAppearance: capabilities.appearance === true
  readonly property string appearance: Appearance.normalizeMode(
    settings ? settings.appearance : null)
  readonly property string notificationError: platform && platform.notificationError
    ? String(platform.notificationError) : ""

  readonly property bool backendCanStoreCredentials: backend.ready && backend.apiVersion >= 4
  // Invariant: Only Linux plugin backends before API 4 use the reviewed keyring compatibility adapter.
  readonly property bool legacyCredentialCompatibility: !standalone
    && backend.ready && backend.apiVersion < 4
  readonly property bool canAccessCredentials: backendCanStoreCredentials
    || legacyCredentialCompatibility
  readonly property var agentRunner: agentRunnerLoader.item || inactiveAgentRunner
  readonly property var agentContext: agentContextLoader.item || inactiveAgentContext
  readonly property var eventSuggester: eventSuggesterLoader.item || inactiveEventSuggester
  readonly property string agentError: agentContext.error !== "" ? agentContext.error : agentRunner.lastError
  readonly property bool agentStarting: agentContext.busy || agentRunner.starting
  // Invariant: Message job IDs are scoped to the open account.
  readonly property var agentJobs: agentRunner.byMessage
  // Invariant: Opening a job acknowledges its attention state.
  readonly property bool agentAttention: agentRunner.attention
  readonly property var agentAttentionByMessage: agentRunner.attentionByMessage
  function agentJobWantsAttention(job) { return agentRunner.wantsAttention(job) }
  function acknowledgeAgentJob(jobId) { agentRunner.acknowledge(jobId) }
  readonly property bool agentBusy: agentRunner.anyActive
  // Invariant: Event suggestions require opt-in because message text is sent to the system AI.
  readonly property bool suggestEvents: !!settings && settings.suggestEvents === true
  readonly property string aiAgent: {
    var selected = String(settings ? settings.aiAgent || "System default" : "System default")
    return platform && platform.standalone && selected === "System default" ? "OpenCode" : selected
  }
  readonly property string aiModel: String(settings ? settings.aiModel || "" : "")
  readonly property bool backendCanChooseAgent: backend.ready && backend.apiVersion >= 6
  readonly property bool backendCanAgentProposals: backend.ready && backend.apiVersion >= 6
  function setAiAgent(value) {
    if (String(value) === aiAgent) return
    persistSetting("aiChatResetAt", Date.now())
    persistSetting("aiAgent", String(value))
  }
  function setAiModel(value) {
    var model = String(value).trim()
    if (model === aiModel) return
    persistSetting("aiChatResetAt", Date.now())
    persistSetting("aiModel", model)
  }
  function setSuggestEvents(value) { persistSetting("suggestEvents", value === true) }
  readonly property var eventSuggestions: eventSuggester.suggestions
  function dismissSuggestion(key) { eventSuggester.dismiss(key) }
  function addSuggestedEvent(suggestion) { return eventSuggester.compose(suggestion) }

  function agentJobFor(messageId, accountId) {
    var target = agentTarget(messageId, accountId)
    return target.owner ? agentRunner.selectionJob([target.id], target.owner.accountId) : null
  }

  function agentHistoryFor(fields, ids, accountId) {
    if (fields && fields.draftKey) {
      var sender = sendHostFor(fields)
      return sender ? agentRunner.historyFor(sender.accountId, [], fields.draftKey) : []
    }
    if (!ids || !ids.length) return []
    var target = agentTarget(ids[0], accountId)
    if (!target.owner) return []
    var own = []
    for (var jobIndex = 0; jobIndex < ids.length; jobIndex++) {
      var item = agentTarget(ids[jobIndex], accountId)
      if (item.owner !== target.owner) return []
      own.push(item.id)
    }
    return agentRunner.historyFor(target.owner.accountId, own, "")
  }

  function agentSelectionJob(ids, accountId) {
    var target = ids && ids.length ? agentTarget(ids[0], accountId) : null
    if (!target || !target.owner) return null
    var own = []
    for (var jobIndex = 0; jobIndex < ids.length; jobIndex++) {
      var item = agentTarget(ids[jobIndex], accountId)
      if (item.owner !== target.owner) return null
      own.push(item.id)
    }
    return agentRunner.selectionJob(own, target.owner.accountId)
  }

  // Invariant: Deferred AI actions retain their opening account. Only an omitted account ID resolves to current.
  function agentOwner(accountId) {
    var id = String(accountId || "")
    if (id === "") return current
    var owner = findAccount(id)
    if (!owner) {
      agentContext.error = "That mailbox is no longer set up, so AI was not asked."
      if (current) current.fail(agentContext.error)
    }
    return owner
  }

  // Invariant: Unified IDs encode account ownership; account-local IDs require the separate account argument.
  function agentTarget(messageId, accountId) {
    var split = Unified.splitUnifiedId(messageId)
    if (split.accountId !== "") return { owner: agentOwner(split.accountId), id: split.id }
    return { owner: agentOwner(accountId), id: String(messageId || "") }
  }

  function askAgent(messageId, prompt, accountId) {
    if (!agentAvailable) return false
    var target = agentTarget(messageId, accountId)
    if (!target.owner || target.id === "") return false
    var envelope = Number(backend.apiVersion) >= 6 ? agentReplyEnvelope({accountId: target.owner.accountId, messageId: target.id, draftKey: "",subject:"",body:""}) : null
    return agentContext.request(target.owner, [target.id], prompt, null, envelope)
  }

  readonly property var agentAllJobs: agentRunner.jobs
  readonly property string agentShownId: agentRunner.shownId
  readonly property string agentShownOutput: agentRunner.shownOutput
  readonly property var agentShownTranscript: agentRunner.shownTranscript
  readonly property var agentShownProposals: agentRunner.shownProposals
  readonly property bool agentHasEarlier: agentRunner.previousPage !== ""
  readonly property bool agentLoadingEarlier: agentRunner.loadingEarlier
  readonly property bool agentHasOlderChats: agentRunner.hasMoreJobs
  readonly property bool agentHasNewerChats: agentRunner.listingOffset > 0
  function loadEarlierAgentMessages() { return agentRunner.loadEarlier() }
  function clearAgentError() { agentContext.error = ""; agentRunner.lastError = "" }
  readonly property int agentSelectionRevision: agentRunner.selectionRevision || 0
  function canContinueAgentJob(job) { return agentRunner.canContinueSelection(job) }
  function pageAgentChats(older) { agentRunner.pageChats(older) }
  function agentReplyEnvelope(proposal) {
    var owner = findAccount(String(proposal.accountId || ""))
    if (!owner || String(owner.selectedId) !== String(proposal.messageId)
        || !owner.selectedMessage || String(proposal.draftKey || "") !== "") return null
    var message = owner.selectedMessage
    var own = [{email: owner.accountEmail}]
    for (var identityIndex = 0; identityIndex < sendIdentities.length; identityIndex++)
      if (String(sendIdentities[identityIndex].accountId) === String(proposal.accountId)) own.push(sendIdentities[identityIndex])
    var recipients = AgentRecipients.replyFields(message, "reply", own)
    var choice = preferredSendAs(recipients.outgoing ? [message.from]
      : (message.to || []).concat(message.cc || []))
    var from = choice && String(choice.accountId) === String(proposal.accountId) ? String(choice.email) : owner.accountEmail
    return {accountId: String(proposal.accountId), from: from, to: recipients.to, cc: recipients.cc, bcc: "",
      replyTo: "", subject: String(proposal.subject), body: String(proposal.body || signatureFor(String(proposal.accountId)) || ""), attachments: [],
      draftId: "", threadId: String(message.threadId || ""), inReplyTo: String(message.messageId || ""),
      replyMessageId: String(proposal.messageId)}
  }

  function showAgentJob(jobId) { agentRunner.show(jobId) }

  function answerAgent(jobId, answer, fields) {
    if (!agentAvailable) return false
    var job = agentRunner.jobById(jobId)
    if (!job || !job.canContinue || !canContinueAgentJob(job) || agentRunner.isActive(job) || !findAccount(job.accountId)
        || String(answer || "").trim() === "") return false
    agentContext.error = ""
    var payload = { parent: String(job.id), prompt: String(answer || "").trim() }
    if (fields && !Agent.canUseDraftChat(job, fields)) return false
    // Invariant: API 5 retains the original snapshot; current-draft updates require API 6.
    if (fields && Number(backend.apiVersion) >= 6) {
      var attaching = String(job.draftKey || "") === "" && String(fields.draftKey || "") !== ""
      payload.draftUpdate = {accountId: String(fields.accountId), draftKey: String(fields.draftKey),
        draft: {from: String(fields.from || ""), to: String(fields.to || ""),
          cc: String(fields.cc || ""), bcc: String(fields.bcc || ""),
          subject: String(fields.subject || ""), body: String(fields.body || "")}}
      if (attaching) payload.draftUpdate.messageId = String(fields.replyMessageId)
      if (fields.envelope) payload.draftUpdate.envelope = fields.envelope
    }
    if (Number(backend.apiVersion) >= 6 && job.messageId && (!Array.isArray(job.messageIds) || job.messageIds.length === 1)) {
      return agentContext.request(findAccount(job.accountId), [String(job.messageId)], answer, null, null, payload)
    }
    if (!agentRunner.start(payload)) return false
    return true
  }

  function askAgentMany(ids, prompt, accountId) {
    if (!agentAvailable) return false
    // Invariant: One AI job may include messages from only one account.
    var list = Array.isArray(ids) ? ids : []
    var owner = null
    var own = []
    for (var entryIndex = 0; entryIndex < list.length; entryIndex++) {
      var target = agentTarget(list[entryIndex], accountId)
      if (!target.owner) return false
      if (owner && target.owner !== owner) {
        agentContext.error = "Select messages from one mailbox at a time."
        owner.fail(agentContext.error)
        return false
      }
      owner = target.owner
      own.push(target.id)
    }
    if (!owner) return false
    return agentContext.request(owner, own, prompt)
  }

  function forgetAgentJob(jobId) { return agentRunner.forget(jobId) }
  function forgetFinishedAgentJobs() { return agentRunner.forgetFinished() }

  function agentJobsForDraft(fields) {
    var owner = sendHostFor(fields)
    return owner ? agentRunner.draftJobs(owner.accountId, fields.draftKey) : []
  }

  function askAgentDraft(fields, ask) {
    if (!agentAvailable) return false
    var owner = sendHostFor(fields)
    if (!owner || !fields || !fields.draftKey || String(ask || "").trim() === "") return false
    agentContext.error = ""
    if (fields.replyMessageId) return agentContext.request(owner, [String(fields.replyMessageId)], ask, fields)
    return agentRunner.start({ draftFields: fields, ask: ask, account: owner.accountEmail, accountId: owner.accountId })
  }

  function cancelAgentJob(jobId) {
    var job = agentRunner.jobById(jobId)
    if (!job || !agentRunner.isActive(job) || agentRunner.cancelling) return false
    return agentRunner.cancelById(jobId)
  }

  function cancelAgent(messageId, accountId) {
    var target = agentTarget(messageId, accountId)
    if (!target.owner) return false
    if (!agentRunner.cancel(target.id, target.owner.accountId)) return false
    target.owner.note("Stopping AI")
    return true
  }

  function refreshAgentJobs() { agentRunner.refresh() }
  // Invariant: Message text direction never changes interface layout direction.
  readonly property string contentDirection: Direction.normalizeMode(
    settings ? settings.contentDirection : null)
  readonly property bool unifiedMailboxes: !!settings
    && settings.unifiedMailboxes === true

  // Invariant: Only a stored boolean false hides the bar icon; malformed settings retain the default.
  readonly property bool showBarIcon: !settings || settings.showBarIcon !== false

  // Invariant: Contact suggestions read external mail profiles without modifying or persisting their contents.
  property var recipientContacts: []
  property bool contactsLoading: false

  function refreshRecipientContacts() {
    if (contactsLoading || !backend || !backend.ready) return
    contactsLoading = true
    backend.call("contacts.suggest", {}, function(result, error) {
      root.contactsLoading = false
      if (!error && Array.isArray(result)) root.recipientContacts = result
    })
  }

  function registerMailtoHandler() {
    if (!hasMailto || pluginDir === "" || mailtoInstaller.running) return
    mailtoInstaller.command = [pluginDir + "/scripts/register-mailto.sh", pluginDir]
    mailtoInstaller.running = true
  }

  // Invariant: Default-client status starts unknown and is refreshed because external settings can change.
  property string defaultMailClient: ""
  property bool defaultMailClientBusy: false
  property string defaultMailClientError: ""

  function refreshDefaultMailClient() {
    if (!hasMailto || pluginDir === "" || defaultMailClientProcess.running) return
    defaultMailClientProcess.command = [pluginDir + "/scripts/default-mail.sh", "status"]
    defaultMailClientProcess.running = true
  }

  function setDefaultMailClient(enabled) {
    if (!hasMailto || pluginDir === "" || defaultMailClientProcess.running) return
    defaultMailClientBusy = true
    defaultMailClientError = ""
    defaultMailClientProcess.command = enabled
      ? [pluginDir + "/scripts/default-mail.sh", "on", pluginDir]
      : [pluginDir + "/scripts/default-mail.sh", "off"]
    defaultMailClientProcess.running = true
  }

  function applySettings(values) {
    var next = normalizedSettings(values)
    if (JSON.stringify(next) !== JSON.stringify(settings)) settings = next
  }

  function openExternal(value) {
    var target = String(value || "")
    if (target === "") return false
    if (platform && typeof platform.openExternal === "function")
      return platform.openExternal(target)
    return Quickshell.execDetached(["xdg-open", target])
  }

  function copyText(value) {
    var text = String(value === undefined || value === null ? "" : value)
    if (platform && typeof platform.setClipboard === "function")
      return platform.setClipboard(text)
    // Invariant: NUL cannot cross argv without truncating clipboard text.
    if (text.indexOf("\0") >= 0) return false
    return Quickshell.execDetached(["wl-copy", "--", text])
  }

  function configPath(name) {
    if (platform && typeof platform.configPath === "function")
      return String(platform.configPath(String(name || "")) || "")
    var home = Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
    return home + "/omamail/" + String(name || "")
  }

  function cachePath(name) {
    if (platform && typeof platform.cachePath === "function")
      return String(platform.cachePath(String(name || "")) || "")
    var home = Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")
    return home + "/omamail/" + String(name || "")
  }

  function writeConfig(name, text, callback) {
    var allowed = ["credentials.json", "window.json", "calendars.json"]
    if (allowed.indexOf(String(name || "")) < 0) {
      if (typeof callback === "function") callback(false, "Invalid configuration file")
      return false
    }
    configWrites++
    var completed = false
    var done = function(ok, error) {
      if (completed) return
      completed = true
      root.configWrites--
      if (!ok) root.persistenceFailureRevision++
      if (typeof callback === "function") callback(ok, error)
    }
    if (platform && typeof platform.writeConfig === "function") {
      var accepted = platform.writeConfig(String(name), String(text), done)
      if (accepted === false) done(false, "Could not start configuration write")
      return accepted
    }
    var request = hostProcessComponent.createObject(root, {
      operation: "write", callback: done, payload: String(text) + "\n",
      command: [root.pluginDir + "/scripts/config-store.sh", String(name)]
    })
    if (!request) {
      done(false, "Could not start configuration write")
      return false
    }
    request.running = true
    return true
  }

  function chooseFiles(callback) {
    if (platform && typeof platform.chooseFiles === "function")
      return platform.chooseFiles(callback)
    var request = hostProcessComponent.createObject(root, {
      operation: "result", callback: callback,
      command: [root.pluginDir + "/scripts/attachment.sh", "pick"]
    })
    if (!request) {
      if (typeof callback === "function") callback(({ok:false,error:"No file picker is available"}))
      return false
    }
    request.running = true
    return true
  }

  function clipboardAttachment(directory, callback) {
    if (platform && typeof platform.clipboardAttachment === "function")
      return platform.clipboardAttachment(String(directory || ""), callback)
    var request = hostProcessComponent.createObject(root, {
      operation: "result", callback: callback,
      command: [root.pluginDir + "/scripts/attachment.sh", "clipboard", String(directory || "")]
    })
    if (!request) {
      if (typeof callback === "function") callback(({ok:false,error:"no-image"}))
      return false
    }
    request.running = true
    return true
  }

  function credentialFields(kind, accountId, clientId) {
    var fields = { kind: String(kind || ""), accountId: String(accountId || "") }
    if (String(clientId || "") !== "") fields.clientId = String(clientId)
    return fields
  }

  function legacyCredentialAttributes(kind, accountId, clientId) {
    var account = String(accountId || "")
    var client = String(clientId || "")
    var controlled = /[\u0000-\u001f\u007f]/
    if (account === "" || account.length > 1024 || account.trim() !== account
        || controlled.test(account) || client.length > 1024 || controlled.test(client)) return []
    if (kind === "google-refresh-token")
      return client === "" || (account !== "default"
        && (account.indexOf("@") < 0 || account.indexOf(":") >= 0))
          ? [] : CredentialKeys.keyringAttributes(client, account)
    return []
  }

  function legacyCredentialOperation(operation, kind, accountId, clientId, secret, callback) {
    var attributes = legacyCredentialAttributes(kind, accountId, clientId)
    var value = String(secret || "")
    if (attributes.length === 0 || (operation === "put"
        && (value === "" || /[\u0000\r\n]/.test(value)))) {
      if (typeof callback === "function") callback(operation === "get" ? "" : false, "invalid_params")
      return false
    }
    var request = legacyCredentialProcessComponent.createObject(root, {
      operation: operation, done: callback, payload: value,
      command: operation === "get" ? ["secret-tool", "lookup"].concat(attributes)
        : operation === "delete" ? ["secret-tool", "clear"].concat(attributes)
        : [root.pluginDir + "/scripts/keyring-store.sh"].concat(attributes)
    })
    value = ""
    if (!request) {
      if (typeof callback === "function") callback(operation === "get" ? "" : false, "credential_store_unavailable")
      return false
    }
    request.running = true
    return true
  }

  function credentialGet(kind, accountId, clientId, callback) {
    if (!backendCanStoreCredentials) {
      if (legacyCredentialCompatibility)
        return legacyCredentialOperation("get", kind, accountId, clientId, "", callback)
      if (typeof callback === "function") callback("", "backend_needs_update")
      return false
    }
    backend.call("credentials.get", credentialFields(kind, accountId, clientId), function(result, error) {
      if (typeof callback === "function") callback(!error && result && result.found === true
        ? String(result.secret || "") : "", error ? String(error.message || error) : "")
    })
    return true
  }

  function credentialPut(kind, accountId, clientId, secret, callback) {
    if (!backendCanStoreCredentials) {
      if (legacyCredentialCompatibility)
        return legacyCredentialOperation("put", kind, accountId, clientId, secret, callback)
      if (typeof callback === "function") callback(false, "backend_needs_update")
      return false
    }
    var fields = credentialFields(kind, accountId, clientId)
    fields.secret = String(secret || "")
    backend.call("credentials.put", fields, function(result, error) {
      if (typeof callback === "function") callback(!error && !!result && result.stored === true,
        error ? String(error.message || error) : "")
    })
    return true
  }

  function credentialDelete(kind, accountId, clientId, callback) {
    if (!backendCanStoreCredentials) {
      if (legacyCredentialCompatibility)
        return legacyCredentialOperation("delete", kind, accountId, clientId, "", callback)
      if (typeof callback === "function") callback(false, "backend_needs_update")
      return false
    }
    backend.call("credentials.delete", credentialFields(kind, accountId, clientId), function(result, error) {
      if (typeof callback === "function") callback(!error, error ? String(error.message || error) : "")
    })
    return true
  }

  function persistSetting(name, value) {
    var next = ({})
    for (var key in settings) if (key !== "id") next[key] = settings[key]
    next[name] = value
    var entry = ({ id: pluginId })
    for (var field in next) entry[field] = next[field]
    if (shell && typeof shell.updateEntryInline === "function"
        && shell.updateEntryInline(pluginId, entry) === false) {
      persistenceFailureRevision++
      fail("Could not save settings. Please try again.")
      return false
    }
    applySettings(next)
    return true
  }

  function setUndoSendSeconds(value) {
    persistSetting("undoSendSeconds", Outbox.normalizeDelay(value))
  }

  function setAlwaysRenderHeavyMessages(value) {
    persistSetting("heavyMessageRendering", Html.heavyMessageRendering(value))
  }

  function setNotifyNewMail(value) {
    persistSetting("notifyNewMail", value ? "On" : "Off")
  }

  function setContentDirection(value) {
    persistSetting("contentDirection", Direction.normalizeMode(value))
  }

  function setAppearance(value) {
    persistSetting("appearance", Appearance.normalizeMode(value))
  }



  function setShowBarIcon(value) {
    persistSetting("showBarIcon", value === true)
  }

  // Invariant: Unified mailbox mode persists across sessions.
  function setUnifiedMailboxes(value) {
    persistSetting("unifiedMailboxes", value === true)
  }

  property var accountList: Accounts.emptyList()
  property string accountRegistryError: ""
  property bool accountsLoaded: false
  property string accountsWritePayload: ""
  property var accountsReleasedIds: []
  property bool accountsWriting: false
  property bool accountsReading: false
  property bool accountsReloadQueued: false
  property string accountsRevision: ""

  readonly property int accountCount: Accounts.count(accountList)
  readonly property bool hasSavedAccounts: Accounts.hasSavedAccounts(accountList)
  readonly property string activeAccountId: accountList ? accountList.activeId : ""
  // Invariant: A pending account has no signature; views access account data through the service.
  readonly property string activeSignature: signatureFor(activeAccountId)

  // Invariant: Signatures and reply identities belong to the named account, which can differ from the visible account.
  function signatureFor(accountId) {
    var entry = Accounts.find(accountList, String(accountId || ""))
    return entry ? String(entry.signature || "") : ""
  }

  function accountEmailFor(accountId) {
    var entry = Accounts.find(accountList, String(accountId || ""))
    return entry ? String(entry.email || "") : ""
  }
  readonly property string activeSignatureHtml: {
    var entry = Accounts.find(accountList, activeAccountId)
    return entry ? String(entry.signatureHtml || "") : ""
  }

  property var current: null

  // Invariant: An unnamed setup row uses a transient index until it acquires an account ID.
  property int activeIndex: -1

  function accountAt(index) {
    return accountHosts.objectAt(index)
  }

  function findAccount(id) {
    for (var hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var host = accountHosts.objectAt(hostIndex)
      if (host && host.accountId === String(id)) return host
    }
    return null
  }

  function gmailAccountId() {
    var accounts = accountList ? accountList.accounts : []
    for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      if (accounts[accountIndex].id) return accounts[accountIndex].id
    }
    return ""
  }

  function refreshCurrent() {
    var next = activeIndex >= 0 && activeIndex < accountHosts.count
      ? accountHosts.objectAt(activeIndex)
      : findAccount(activeAccountId)
    // Invariant: Setup must still resolve a host before its account has an ID.
    if (!next && accountHosts.count > 0) next = accountHosts.objectAt(0)
    if (next !== current) {
      searchPreparationSerial++
      searchPreparation = null
      if (!unified && current && current.submittedSearch.active) current.stopSearch()
      current = next
    }
    applyLiveHosts()
  }

  // Invariant: Every saved account in unified view is active and receives windowOpen, so its list can refresh.
  function applyLiveHosts() {
    for (var hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var host = accountHosts.objectAt(hostIndex)
      if (!host) continue
      // Invariant: An unnamed setup row is active only when it is the current row.
      var live = host === current
        || (unified && String(host.accountId || "") !== "")
      host.active = live
      if (live) host.windowOpen = windowOpen
    }
  }

  // Invariant: Unified mode changes active hosts without changing the current account.
  onUnifiedChanged: {
    searchPreparationSerial++
    searchPreparation = null
    submittedUnifiedQuery = ""
    searchParticipantIds = null
    eachHost(function(host) {
      host.stopSearch()
      if (root.unified || host === root.current) host.selectMailbox(root.unified ? root.unifiedMailboxKey : host.mailboxKey)
    })
    applyLiveHosts(); scheduleUnifiedSnapshot()
  }

  // Invariant: Account caches and queued sends survive visible-account switches.
  function switchTo(id) {
    // Invariant: A stale notification must not switch to or persist an account that no longer exists.
    if (!Accounts.find(accountList, id)) return false
    // Invariant: Returning to the saved active account still clears any transient setup selection.
    if (String(id) === activeAccountId) {
      if (activeIndex >= 0) {
        activeIndex = -1
        refreshCurrent()
      }
      return true
    }
    activeIndex = -1
    accountList = Accounts.setActive(accountList, id)
    saveAccounts()
    refreshCurrent()
    return true
  }

  function openNotification(accountId, messageId) {
    if (!Accounts.find(accountList, accountId) || !messageId) return false
    if (shell && typeof shell.summon === "function")
      return shell.summon(pluginId, JSON.stringify({ accountId: accountId, messageId: messageId }))
    return false
  }

  // Invariant: Position is the only selection identity available for an unnamed setup row.
  function switchToIndex(index) {
    var accounts = accountList ? accountList.accounts : []
    if (index < 0 || index >= accounts.length) return false
    // Invariant: Clear activeIndex even when the saved account is already active, or editing still targets the pending row.
    if (index === indexOfActiveAccount()) {
      if (activeIndex >= 0) {
        activeIndex = -1
        refreshCurrent()
      }
      return true
    }
    if (accounts[index].id !== "") {
      return switchTo(accounts[index].id)
    }
    activeIndex = index
    refreshCurrent()
    return true
  }

  function addAccount() {
    if (accountRegistryError !== "") return false
    accountList = Accounts.add(accountList, ({
      email: "", clientId: "", clientSecret: "",
      provider: "gmail",
      // Invariant: Explicit pending state distinguishes a setup draft from a persisted account with damaged identity.
      pending: true
    }))
    // Invariant: Select the pending row before opening its form; persist it only after successful configuration.
    activeIndex = accountCount - 1
    refreshCurrent()
    accountAdded()
  }

  function discardCurrentDraft() {
    var index = editingIndex()
    var next = Accounts.discardDraftAt(accountList, index)
    if (Accounts.count(next) === accountCount) return false
    activeIndex = -1
    accountList = next
    refreshCurrent()
    return true
  }

  function removeAccount(id) {
    activeIndex = -1
    accountList = Accounts.remove(accountList, id)
    saveAccounts({ allowDrop: true })
    refreshCurrent()
  }

  function removeAccountAt(index) {
    activeIndex = -1
    accountList = Accounts.removeAt(accountList, index)
    saveAccounts({ allowDrop: true })
    refreshCurrent()
  }

  // Invariant: The first profile read can supply an account address that setup did not know.
  function nameAccount(index, email) {
    var accounts = accountList.accounts
    if (index < 0 || index >= accounts.length) return
    // Invariant: Account identity includes the provider; one address may belong to multiple provider accounts.
    var named = Accounts.accountId(email, accounts[index].provider)
    if (accounts[index].id === named) return
    // Invariant: Reject an invalid reported address without replacing the existing account identity.
    if (named === "") return

    // Invariant: Renaming releases only this row's old identity; all other persisted accounts must survive the save.
    accountsReleasedIds = accountsReleasedIds.concat([String(accounts[index].id || "")])
    lastPersistedIds = Accounts.withoutId(lastPersistedIds, String(accounts[index].id || ""))

    // Invariant: A duplicate profile removes the new row, preserving the existing account.
    for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      if (accountIndex === index || accounts[accountIndex].id !== named) continue
      activeIndex = -1
      accountList = Accounts.removeAt(accountList, index)
      saveAccounts()
      refreshCurrent()
      duplicateAccount(email)
      return
    }

    // Invariant: Renaming preserves every other account field and changes selection only for the active draft.
    var updated = Accounts.replaceAt(accountList, index, withEmail(accounts[index], email))
    if (activeIndex === index)
      updated = Accounts.setActive(updated, named)
    if (activeIndex === index) activeIndex = -1
    accountList = updated
    saveAccounts()
  }

  function withEmail(entry, email) {
    var next = {}
    for (var key in entry) next[key] = entry[key]
    next.email = email
    return next
  }

  // Invariant: Persist configuration before sign-in so failed authentication retains editable settings. A refused configuration must not proceed to credential storage.
  function configureAccount(index, values) {
    if (accountRegistryError !== "") return false
    var accounts = accountList.accounts
    if (index < 0 || index >= accounts.length) return false
    var raw = values || ({})

    var entry = {}
    for (var key in accounts[index]) entry[key] = accounts[index][key]
    var keys = ["email", "clientId", "clientSecret", "label"]
    for (var keyIndex = 0; keyIndex < keys.length; keyIndex++)
      if (raw[keys[keyIndex]] !== undefined) entry[keys[keyIndex]] = raw[keys[keyIndex]]

    // Invariant: Updating through add could replace another row on an identity collision; use replaceAt.
    if (Accounts.collidingId(accountList, index, entry)) {
      duplicateAccount(String(entry.email || ""))
      return false
    }

    // Invariant: Configuration preserves selection unless it names the draft currently being edited.
    var updated = Accounts.replaceAt(accountList, index, entry)
    var id = Accounts.accountId(entry.email, entry.provider)
    if (id !== "" && activeIndex === index)
      updated = Accounts.setActive(updated, id)
    // Invariant: Keep a draft's index until configuration produces a valid account ID.
    if (activeIndex === index && id !== "") activeIndex = -1
    // Invariant: A corrected address releases its previous ID from the persisted-account removal guard.
    var oldId = String(accounts[index].id || "")
    if (oldId !== "" && id !== oldId) {
      accountsReleasedIds = accountsReleasedIds.concat([oldId])
      lastPersistedIds = Accounts.withoutId(lastPersistedIds, oldId)
    }
    accountList = updated
    saveAccounts()
    refreshCurrent()
    return true
  }

  // Invariant: Queue saves received during a write; dropping them lets later reads revert accepted changes.
  property bool accountsSaveQueued: false
  property bool accountsSaveQueuedAllowDrop: false
  // Invariant: Compare writes with the last persisted IDs as well as current memory, which may already have lost a row.
  property var lastPersistedIds: []

  readonly property var monitoredLabelIds: {
    var entry = Accounts.find(accountList, activeAccountId)
    return entry && Array.isArray(entry.monitored) ? entry.monitored : []
  }

  function toggleMonitored(labelId, accountId) {
    var owner = labelOwner(accountId)
    if (!owner) return
    if (commitAccounts(Accounts.toggleMonitored(accountList, owner.accountId, labelId)))
      owner.labelActions.refreshMonitored()
  }

  // Invariant: Monitored folders follow the IDs produced by an account rename or move.
  function setMonitoredIds(index, ids) {
    var account = accountAt(index)
    if (!account) return
    commitAccounts(Accounts.setMonitored(accountList, account.accountId, Array.prototype.slice.call(ids)))
  }

  function commitAccounts(next) {
    if (accountRegistryError !== "") return false
    if (Accounts.serialize(next) === Accounts.serialize(accountList)) return false
    accountList = next
    saveAccounts()
    return true
  }

  function setAccountLabel(id, text) { commitAccounts(Accounts.setLabel(accountList, id, text)) }
  function setAccountSignatureHtml(id, html) { commitAccounts(Accounts.setSignatureHtml(accountList, id, html)) }
  function setAccountSignature(id, text) { commitAccounts(Accounts.setSignature(accountList, id, text)) }

  function saveAccounts(options) {
    if (!accountsLoaded || accountRegistryError !== "") return
    // Invariant: Serialize saved rows only and refuse an empty registry; setup drafts must never replace saved accounts.
    var writable = Accounts.savedOnly(accountList)
    if (!Accounts.hasSavedAccounts(writable)) return
    // Invariant: Every named in-memory mailbox must survive serialization; deletion requires an explicit removal path.
    if (Accounts.dropsNamedMailbox(accountList, writable)) return
    var allowDrop = !!(options && options.allowDrop)
    if (!allowDrop && Accounts.dropsAnyId(lastPersistedIds, writable)) return
    if (accountsWriting) {
      accountsSaveQueued = true
      if (allowDrop) accountsSaveQueuedAllowDrop = true
      return
    }
    accountsSaveQueued = false
    accountsSaveQueuedAllowDrop = false
    if (!backend || !backend.ready) { accountsSaveQueued = true; accountsSaveQueuedAllowDrop = allowDrop; return }
    accountsWriting = true
    accountsWritePayload = Accounts.serialize(writable)
    var released = accountsReleasedIds.slice()
    backend.call("accounts.save", { registry: writable, revision: accountsRevision, allowDrop: allowDrop, releasedIds: released }, function(result, error) {
      if (!root) return
      root.accountsWriting = false
      root.accountsWritePayload = ""
      if (error || !result) {
        root.persistenceFailureRevision++
        root.accountsSaveQueued = false
        root.accountsSaveQueuedAllowDrop = false
        root.accountsRevision = ""
        if (root.current) root.current.fail("Account changes could not be saved. Reloading saved accounts.")
        root.restoreAccountRegistry()
        return
      }
      root.accountsRevision = String(result.revision || "")
      root.accountsReleasedIds = root.accountsReleasedIds.filter(function(id) { return released.indexOf(id) < 0 })
      root.lastPersistedIds = Accounts.namedIds(writable).filter(function(id) { return root.accountsReleasedIds.indexOf(id) < 0 })
      if (root.accountsSaveQueued) {
        var drop = root.accountsSaveQueuedAllowDrop
        root.saveAccounts(drop ? { allowDrop: true } : undefined)
        return
      }
      if (root.accountsReloadQueued) {
        root.accountsReloadQueued = false
        root.restoreAccountRegistry()
      }
    })
  }

  function restoreAccountRegistry() {
    if (!backend || !backend.ready) return
    if (accountsReading || accountsWriting || accountsSaveQueued) { accountsReloadQueued = true; return }
    accountsReading = true
    backend.call("accounts.read", {}, function(result, error) {
      if (!root) return
      root.accountsReading = false
      var reload = root.accountsReloadQueued
      root.accountsReloadQueued = false
      if (!error && result && !root.accountsWriting && !root.accountsSaveQueued
          && (!root.accountsLoaded || root.accountsRevision !== result.revision)) {
        root.accountsRevision = String(result.revision || "")
        root.applyAccounts(JSON.stringify(result.registry))
      } else if (error && String(error.message || error) === "accounts_provider_unsupported") {
        root.accountRegistryError = "Only Gmail accounts are supported. Your saved accounts have not been changed."
        root.accountsSaveQueued = false
        root.accountsSaveQueuedAllowDrop = false
      } else if (error && !root.accountsLoaded) {
        // Invariant: First-run read failure still creates a placeholder so cold-start notification routing can finish.
        root.applyAccounts("")
      }
      if (reload) root.restoreAccountRegistry()
    })
  }

  function applyAccounts(raw) {
    if (!Accounts.supportsGmailAccounts(raw)) {
      accountRegistryError = "Only Gmail accounts are supported. Your saved accounts have not been changed."
      accountsSaveQueued = false
      accountsSaveQueuedAllowDrop = false
      return
    }
    if (accountRegistryError !== "" && !Accounts.isSerializedList(raw)) return
    accountRegistryError = ""

    // Invariant: A transient invalid registry read must not erase an already-loaded account list.
    if (accountsLoaded && !Accounts.isSerializedList(raw)) return
    var loaded = Accounts.load(raw)
    // Invariant: First run retains an unnamed placeholder for legacy credentials and setup.
    if (Accounts.count(loaded) === 0)
      loaded = Accounts.add(loaded, ({ email: "", clientId: "", clientSecret: "", pending: true }))
    // Invariant: Compare saved rows only when reading back a write; rebuilding identical hosts would discard sessions and pending setup fields.
    if (accountsLoaded && Accounts.serialize(Accounts.savedOnly(loaded))
        === Accounts.serialize(Accounts.savedOnly(accountList)))
      return
    // Invariant: Ignore reloads while accepted changes still await persistence.
    if (accountsWriting || accountsSaveQueued) return
    accountList = loaded
    accountsLoaded = true
    lastPersistedIds = Accounts.namedIds(Accounts.savedOnly(loaded))
  }

  signal accountAdded()

  // Invariant: Window preferences use their own file; plugin settings arrive through the bar widget.

  property var displayPreferences: Display.normalize({})
  Binding { target: MailStyle; property: "preferences"; value: root.displayPreferences }

  function setDisplayPreference(key, value) {
    displayPreferences = Display.changed(displayPreferences, key, value)
    saveWindowPrefs()
  }

  property bool sidebarCollapsed: false
  // Invariant: Pane widths are pixels; zero selects each pane's proportional default.
  property real sidebarWidth: 0
  property real listWidth: 0
  // Invariant: Folder collapse preferences are keyed by path and shared across accounts.
  property var collapsedFolders: []
  property real bodyZoom: 1.0
  property string bodyMode: "reader"
  // Invariant: Remote images require explicit permission.
  property bool alwaysShowImages: false
  property bool windowPrefsLoaded: false
  property string windowWritePayload: ""
  property bool windowWriting: false
  property bool restoreWindow: false
  property int restoreAttempts: 0

  function applyWindowPrefs(raw) {
    inboxController.descriptionsEnabled = Display.readWindow(raw).descriptionsEnabled !== false
    inboxController.paused = Display.readWindow(raw).overviewPaused === true
    displayPreferences = Display.fromWindow(raw)
    var prefs = Model.windowPrefs(raw)
    sidebarCollapsed = prefs.sidebarCollapsed
    sidebarWidth = prefs.sidebarWidth
    listWidth = prefs.listWidth
    collapsedFolders = prefs.collapsedFolders
    bodyZoom = Display.zoomForWindow(raw, prefs.bodyZoom)
    bodyMode = prefs.bodyMode
    alwaysShowImages = prefs.alwaysShowImages
    restoreWindow = prefs.windowOpen
    restoreAttempts = 0
    windowPrefsLoaded = true
    if (restoreWindow) Qt.callLater(root.reopenWindow)
    else if (windowOpen) saveWindowPrefs()
  }

  function reopenWindow() {
    if (!restoreWindow || windowOpen) return
    if (restoreAttempts > 10) return
    restoreAttempts = restoreAttempts + 1
    if (!shell || typeof shell.summon !== "function") {
      restoreTimer.start()
      return
    }
    var ok = shell.summon(pluginId, "{}")
    if (!ok) restoreTimer.start()
  }

  // Invariant: Persist the first preference change immediately and retain the final value of changes arriving during that write.
  function saveWindowPrefs() {
    if (!windowPrefsLoaded) return
    if (windowWriting) {
      windowPrefsSettling.restart()
      return
    }
    windowPrefsSettling.stop()
    windowWritePayload = JSON.stringify({
      display: displayPreferences,
      overviewPaused: inboxController.paused,
      descriptionsEnabled: inboxController.descriptionsEnabled,
      sidebarCollapsed: sidebarCollapsed,
      sidebarWidth: sidebarWidth,
      listWidth: listWidth,
      collapsedFolders: collapsedFolders,
      bodyZoom: bodyZoom,
      bodyMode: bodyMode,
      alwaysShowImages: alwaysShowImages,
      windowOpen: windowOpen || restoreWindow
    })
    windowWriting = true
    writeConfig("window.json", windowWritePayload, function(ok, error) {
      root.windowWriting = false
      root.windowWritePayload = ""
      if (!ok && root.current) root.current.fail(error || "Could not save window settings")
    })
  }

  // Performance: Persist pane widths when dragging finishes, not on every pointer move.
  function setPaneWidths(sidebar, list) {
    var nextSidebar = Model.paneWidth(sidebar)
    var nextList = Model.paneWidth(list)
    if (nextSidebar === sidebarWidth && nextList === listWidth) return
    sidebarWidth = nextSidebar
    listWidth = nextList
    saveWindowPrefs()
  }

  function toggleFolder(path) {
    var key = String(path || "")
    if (key === "") return
    collapsedFolders = Model.togglePath(collapsedFolders, key)
    saveWindowPrefs()
  }

  // Invariant: Shortcut numbering uses visible labels after collapsed folders are removed.
  readonly property var visibleLabels: Model.visibleLabels(labels, collapsedFolders)

  function setSidebarCollapsed(value) {
    var next = value === true
    if (next === sidebarCollapsed) return
    sidebarCollapsed = next
    saveWindowPrefs()
  }

  function setBodyZoom(value) {
    var next = Model.clampZoom(value)
    if (next === bodyZoom) return
    bodyZoom = next
    saveWindowPrefs()
  }

  function setBodyMode(value) {
    // Performance: Changing body mode reuses existing parsed documents without fetching the message again.
    var next = Html.bodyModeOf(value, bodyMode)
    if (next === bodyMode) return
    bodyMode = next
    saveWindowPrefs()
  }

  function setAlwaysShowImages(value) {
    var next = value === true
    if (next === alwaysShowImages) return
    alwaysShowImages = next
    saveWindowPrefs()
  }
  signal duplicateAccount(string email)

  property int unreadTotal: 0
  // Invariant: First-run setup depends on readiness across all accounts, not only the visible mailbox.
  property bool anyAccountReady: false

  // Invariant: Instantiator.objectAt is not observable; hostsEpoch invalidates derived sender identities.
  property int hostsEpoch: 0

  function recount() {
    var total = 0
    var signedIn = false
    for (var hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var host = accountHosts.objectAt(hostIndex)
      if (!host) continue
      total += host.inboxUnread
      if (host.ready) signedIn = true
    }
    unreadTotal = total
    anyAccountReady = signedIn
    hostsEpoch += 1
  }

  // Invariant: The bar unread count spans all accounts.
  readonly property string barTooltip: {
    if (!ready) return "Magpie · Not connected"
    var suffix = unreadTotal === 0 ? "No unread mail"
      : (unreadTotal === 1 ? "1 unread message" : unreadTotal + " unread messages")
    return (accountEmail !== "" ? accountEmail : "Magpie") + " · " + suffix
  }

  // Invariant: Signature editor models depend on account entries only; live polling state must not rebuild editable fields.
  readonly property var accountSignatures: {
    var result = []
    var accounts = accountList ? accountList.accounts : []
    for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      // Invariant: An unnamed pending row cannot receive a persisted signature.
      if (!accounts[accountIndex].id) continue
      result.push({
        id: accounts[accountIndex].id,
        email: accounts[accountIndex].email,
        // Invariant: Editable labels preserve an empty saved value rather than substituting the address.
        label: String(accounts[accountIndex].label || ""),
        provider: String(accounts[accountIndex].provider || ""),
        signature: String(accounts[accountIndex].signature || ""),
        signatureHtml: String(accounts[accountIndex].signatureHtml || "")
      })
    }
    return result
  }

  readonly property var accountSummaries: {
    var result = []
    var accounts = accountList ? accountList.accounts : []
    for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      var host = accountHosts.objectAt(accountIndex)
      result.push({
        id: accounts[accountIndex].id,
        email: accounts[accountIndex].email,
        provider: accounts[accountIndex].provider,
        calendarProvider: Accounts.calendarProvider(accounts[accountIndex]),
        label: Accounts.label(accounts[accountIndex]),
        // Invariant: name preserves an empty saved label; label includes a display fallback.
        name: String(accounts[accountIndex].label || ""),
        detail: "",
        unread: host ? host.inboxUnread : 0,
        active: host ? host.active : false,
        signedIn: host ? host.ready : false,
        busy: host ? host.listLoading : false,
        error: host ? host.lastError : ""
      })
    }
    return result
  }

  // Performance: A single account bypasses the unified merge and its row copies.
  readonly property bool unified: unifiedMailboxes && accountCount > 1

  // Invariant: listEpoch observes host list changes separately from sender-identity changes in hostsEpoch.
  property int listEpoch: 0

  function bumpListEpoch() {
    listEpoch += 1
  }

  readonly property var unifiedSources: {
    // Performance: Build unified source copies only while the merged view is enabled.
    if (!unified) return []
    var _epoch = listEpoch
    var result = []
    var accounts = accountList ? accountList.accounts : []
    for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      if (!accounts[accountIndex].id) continue
      var host = accountHosts.objectAt(accountIndex)
      if (!searchParticipant(host)) continue
      result.push({
        id: accounts[accountIndex].id,
        label: Accounts.label(accounts[accountIndex]),
        messages: host ? host.messages : [],
        // Invariant: A partial source bounds the merged list so unseen older rows cannot create a gap.
        hasMore: !!(host && host.hasMore)
      })
    }
    return result
  }

  readonly property var unifiedStates: {
    if (!unified) return []
    var _epoch = listEpoch
    var result = []
    var accounts = accountList ? accountList.accounts : []
    for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      if (!accounts[accountIndex].id) continue
      var host = accountHosts.objectAt(accountIndex)
      if (!searchParticipant(host)) continue
      result.push({
        label: Accounts.label(accounts[accountIndex]),
        loading: !!(host && host.listLoading),
        loaded: !!(host && host.listLoaded),
        serverSearchLoading: !!(host && host.serverSearchLoading),
        hasMore: !!(host && host.hasMore),
        error: host ? String(host.lastError || "") : ""
      })
    }
    return result
  }

  // Invariant: Coalesce native merge requests and reject responses from older account or view generations.
  property var unifiedSnapshot: ({})
  property int unifiedRevision: 0
  property bool unifiedRequestPending: false
  property bool unifiedRequestQueued: false
  property string unifiedAccountKey: ""
  property string unifiedSnapshotError: ""
  readonly property var unifiedMessages: unified
    ? (unifiedSnapshot.messages || []) : []

  function scheduleUnifiedSnapshot() {
    unifiedRevision++
    unifiedRequestQueued = true
    var ids = []
    var sources = unifiedSources || []
    for (var sourceIndex = 0; sourceIndex < sources.length; sourceIndex++) ids.push(sources[sourceIndex].id)
    var key = JSON.stringify(ids)
    if (!unified || key !== unifiedAccountKey) {
      unifiedSnapshot = ({})
      unifiedSnapshotError = ""
    }
    unifiedAccountKey = key
    unifiedSnapshotTimer.restart()
  }

  function refreshUnifiedSnapshot() {
    if (!unified || !backend || !backend.ready || unifiedRequestPending) return
    unifiedRequestQueued = false
    unifiedRequestPending = true
    var generation = unifiedRevision
    backend.call("model.unified", {
      sources: unifiedSources,
      states: unifiedStates, summaries: accountSummaries
    }, function(value, error) {
      if (!root) return
      root.unifiedRequestPending = false
      root.acceptUnifiedSnapshot(generation, value, error)
      if (root.unifiedRequestQueued) unifiedSnapshotTimer.restart()
    })
  }

  function acceptUnifiedSnapshot(generation, value, error) {
    if (!unified || generation !== unifiedRevision) return
    if (error || !value) {
      unifiedSnapshotError = "Could not combine mailboxes"
      return
    }
    var rows = value.messages || []
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      if (rows[rowIndex].date) rows[rowIndex].date = new Date(rows[rowIndex].date)
    }
    unifiedSnapshot = value
    unifiedSnapshotError = ""
  }

  onUnifiedSourcesChanged: scheduleUnifiedSnapshot()
  onUnifiedStatesChanged: scheduleUnifiedSnapshot()
  onAccountSummariesChanged: scheduleUnifiedSnapshot()
  Timer { id: unifiedSnapshotTimer; interval: 0; onTriggered: root.refreshUnifiedSnapshot() }

  // Invariant: Unified mailbox selection stays stable while individual accounts finish switching.
  property string unifiedMailboxKey: "inbox"

  // Invariant: A unified reader forwards from the selected message's owning account.
  property var selectionHost: null

  // Invariant: Unified actions resolve account ownership from the row ID.
  function hostForId(id) {
    if (!unified) return current
    var target = Unified.accountOf(id)
    return target === "" ? null : findAccount(target)
  }

  function sourceIdFor(id) {
    return unified ? Unified.sourceIdOf(id) : String(id === undefined || id === null ? "" : id)
  }

  function eachHost(callback) {
    for (var hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var host = accountHosts.objectAt(hostIndex)
      if (host) callback(host)
    }
  }

  readonly property var barMessages: {
    var accounts = []
    var values = accountList ? accountList.accounts : []
    for (var accountIndex = 0; accountIndex < values.length; accountIndex++) {
      var host = accountHosts.objectAt(accountIndex)
      accounts.push({
        id: values[accountIndex].id, label: Accounts.label(values[accountIndex]), inbox: "Inbox",
        messages: host ? host.previewMessages : []
      })
    }
    return Preview.latestMessages(accounts, 3)
  }

  function openSkylark(request) {
    if (skylarkLauncher.running) return false
    skylarkLauncher.command = ["python3",root.pluginDir + "/scripts/open-skylark.py",JSON.stringify(request || {})]
    skylarkLauncher.running = true
    return true
  }
  function openInvitationInSkylark() {
    if (!reading || !selectedInvite) return false
    return openSkylark(CalendarHandoff.invitation(reading.accountId, selectedInvite))
  }
  Process {
    id:skylarkLauncher
    objectName:"skylark-launcher"
    stderr:StdioCollector { waitForEnd:true }
    onExited:function(code) { if (code !== 0 && root.current) root.current.fail("Skylark could not open. Check that Skylark is installed, then try again.") }
  }

  property bool windowOpen: false
  onWindowOpenChanged: {
    applyLiveHosts()
    if (windowOpen) restoreWindow = false
    saveWindowPrefs()
  }

  readonly property var auth: current ? current.auth : null
  readonly property bool ready: !!current && current.ready
  readonly property var localMailbox: !unified && current ? current.local : null
  readonly property string accountEmail: current ? current.accountEmail : ""
  readonly property string accountLabel: {
    var entry = Accounts.find(accountList, activeAccountId)
    return entry ? Accounts.label(entry) : ""
  }
  readonly property var sendAsAliases: current ? current.availableSendAsAliases : []
  // Invariant: Sender sources span ready accounts; reply composition narrows them to its owning account.
  readonly property var senderSources: {
    var _epoch = hostsEpoch
    var mailboxes = []
    var accounts = accountList ? accountList.accounts : []
    var accountIndex
    for (accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      var host = accountHosts.objectAt(accountIndex)
      mailboxes.push({
        id: accounts[accountIndex].id,
        email: host && host.accountEmail ? host.accountEmail : accounts[accountIndex].email,
        label: Accounts.label(accounts[accountIndex]),
        ready: !!(host && host.ready),
        canSend: !!(host && host.canSend),
        aliases: host ? host.availableSendAsAliases : []
      })
    }
    return mailboxes
  }
  property var sendIdentities: []
  property int senderRequestSerial: 0
  function scheduleSenderIdentities() {
    senderRequestSerial++
    sendIdentities = []
    senderProjectionTimer.restart()
  }
  Timer { id: senderProjectionTimer; interval: 0; onTriggered: root.refreshSenderIdentities() }
  onSenderSourcesChanged: scheduleSenderIdentities()
  function refreshSenderIdentities() {
    if (!backend || !backend.ready) return
    var serial = senderRequestSerial
    backend.call("account.identities", { mailboxes: senderSources }, function(result, error) {
      if (!root || serial !== root.senderRequestSerial || error || !result) return
      root.sendIdentities = result.identities || []
    })
  }
  // Invariant: Setup fields use the saved entry, preserving empty names without display-label fallbacks.
  function editingEntry() {
    var accounts = accountList ? accountList.accounts : []
    var index = editingIndex()
    return index >= 0 && index < accounts.length ? accounts[index] : ({})
  }
  readonly property string accountName: String(editingEntry().label || "")
  readonly property string accountAddress: String(editingEntry().email || "")
  readonly property int inboxUnread: unified
    ? Number(unifiedSnapshot.totalUnread || 0) : (current ? current.inboxUnread : 0)
  readonly property var messages: unified
    ? unifiedMessages : (current ? current.messages : [])
  // Invariant: Labels belong to one account and are unavailable in unified view.
  readonly property var labels: unified ? [] : (current ? current.labels : [])
  readonly property bool canMoveToLabel: !unified
    && !!current && current.canMove

  readonly property string providerId: "gmail"
  readonly property var mailboxes: current ? current.mailboxes : Provider.mailboxes("gmail")
  readonly property bool canArchive: unified || !current || current.canArchive
  readonly property bool canReportSpam: unified || !current || current.canReportSpam
  readonly property bool canStar: unified || !current || current.canStar
  readonly property bool hasLabels: true
  readonly property bool canOpenOnWeb: true
  readonly property bool canOpenWebInbox: !unified && !!current && current.canOpenWebInbox
  readonly property var unavailableActions: unified
    ? Model.unavailableActions({
        archive: canArchive, star: canStar, spam: canReportSpam,
        move: canMoveToLabel })
    : (current ? current.unavailableActions : [])

  // Invariant: Attachment progress uses account-qualified IDs in a unified view.
  readonly property var savingAttachmentIds: {
    if (!unified) return current ? current.savingAttachmentIds : ({})
    var _epoch = listEpoch
    var result = ({})
    var accounts = accountList ? accountList.accounts : []
    for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      if (!accounts[accountIndex].id) continue
      var host = accountHosts.objectAt(accountIndex)
      var own = host ? host.savingAttachmentIds : ({})
      for (var key in own) result[Unified.unifiedId(accounts[accountIndex].id, key)] = own[key]
    }
    return result
  }
  // Invariant: Send capability belongs to the selected sender account, not the intersection of mailbox capabilities.
  readonly property bool canSend: !current || current.canSend
  readonly property bool showsConversations: false
  // Invariant: Reader conversation state belongs to the selected message's account.
  readonly property bool showsRail: conversationProjection.showsRail === true
  // Invariant: Unified thread members carry account-qualified IDs for reader comparisons and actions.
  readonly property var selectedThread: {
    if (!reading) return null
    if (!unified) return reading.selectedThread
    return Unified.composeThread(reading.accountId, reading.selectedThread)
  }
  readonly property var memberSummaries: {
    if (!reading) return ({})
    if (!unified) return reading.memberSummaries
    return Unified.composeMembers(reading.accountId, reading.memberSummaries)
  }
  readonly property string mailboxKey: unified
    ? unifiedMailboxKey : (current ? current.mailboxKey : "inbox")
  // Invariant: The conversation projection uses the service mailbox key, including the unified selection.
  readonly property string viewedMailboxKey: String(conversationProjection.viewedMailboxKey || "")
  property var conversationProjection: ({ showsRail: false, stops: [], caption: "", navigation: {}, memberIds: [] })
  property int conversationProjectionSerial: 0
  // Performance: Compare serialized projection sources to avoid requests caused only by new object identities.
  property string projectedSource: ""
  property string projectedRail: ""
  readonly property var conversationSource: ({
    operation: "project", thread: selectedThread, summaries: memberSummaries,
    selectedId: selectedId, mailboxKey: mailboxKey,
    searching: searchQuery !== "" || rawQuery !== "", mailboxes: mailboxes,
    conversations: !!reading && reading.showsConversations,
    // Invariant: Projection identity includes the account because provider-local thread IDs can collide.
    accountId: reading ? String(reading.accountId || "") : ""
  })
  // Invariant: Preserve a pending projection only for the same account, thread, and mailbox to avoid reflowing an unchanged reader.
  function scheduleConversationProjection(sourceText) {
    conversationProjectionSerial++
    var source = conversationSource
    var rail = Model.projectionKey(source)
    var sameRail = rail === projectedRail
    projectedSource = sourceText || JSON.stringify(source)
    projectedRail = rail
    conversationProjection = Model.pendingProjection(conversationProjection, sameRail)
    conversationProjectionTimer.restart()
  }
  Timer { id: conversationProjectionTimer; interval: 0; onTriggered: root.refreshConversationProjection() }
  onConversationSourceChanged: {
    var text = JSON.stringify(conversationSource)
    if (text === projectedSource) return
    scheduleConversationProjection(text)
  }
  function refreshConversationProjection() {
    if (!backend || !backend.ready) return
    var serial = conversationProjectionSerial
    backend.call("account.conversation", conversationSource, function(result, error) {
      if (!root || serial !== root.conversationProjectionSerial) return
      // Invariant: Failed projection requests clear the source cache so an unchanged source can retry.
      if (error || !result) { root.projectedSource = ""; return }
      root.conversationProjection = result
    })
  }
  property int searchGeneration: 0
  property int searchPreparationSerial: 0
  property var searchPreparation: null
  property string preparingSearchQuery: ""
  property string submittedUnifiedQuery: ""
  property var searchParticipantIds: null
  readonly property string searchQuery: unified ? submittedUnifiedQuery : current ? current.searchQuery : ""
  readonly property bool searchActive: searchQuery !== ""
  readonly property bool searchAssistanceAvailable: !!backend && backend.ready
    && Number(backend.apiVersion) >= 8 && !!current
  readonly property var searchOperators: searchAssistanceAvailable ? Provider.get("gmail").searchOperators : []
  readonly property var searchLabels: {
    var observed = listEpoch
    var seen = Object.create(null)
    var result = []
    eachHost(function(host) {
      if (!root.unified && host !== root.current) return
      var labels = host.labels || []
      for (var index = 0; index < labels.length; index++) {
        var name = String(labels[index].name || labels[index].id || "")
        if (!name || seen[name]) continue
        seen[name] = true
        result.push({name:name})
      }
    })
    return result
  }
  function searchParticipant(host) {
    return !!host && (!unified || searchParticipantIds === null
      || searchParticipantIds.indexOf(String(host.accountId || "")) >= 0)
  }
  readonly property var searchStatus: {
    if (searchPreparation) return searchPreparation
    if (!unified) return current ? current.searchStatus : SearchState.status("", "", "", 0)
    var observed = listEpoch
    if (!submittedUnifiedQuery) return SearchState.status("", "", "", 0)
    var states = [], total = 0
    eachHost(function(host) {
      if (!host.accountId) return
      total++
      if (!root.searchParticipant(host)) return
      var state = Object.assign({}, host.searchStatus)
      state.label = host.accountEmail || host.accountId
      states.push(state)
    })
    var scope = "All accounts · " + states.length + " accounts searched"
    var result = SearchState.aggregate(states, scope)
    if (result.phase === "complete") result.text = "Search complete." + SearchState.pendingText(result.pendingCount)
    if (result.phase === "checking") result.text = "Searching accounts…" + SearchState.pendingText(result.pendingCount)
    return result
  }
  function stopSearch() {
    searchPreparationSerial++
    if (searchPreparation && searchPreparation.phase === "preparing")
      searchPreparation = SearchState.status("stopped", "", "", 0)
    if (!unified) { if (current) current.stopSearch(); return }
    eachHost(function(host) { if (root.searchParticipant(host)) host.stopSearch() })
  }
  function retrySearch() {
    if (searchPreparation && searchPreparation.phase === "stopped" && preparingSearchQuery) {
      var pendingQuery = preparingSearchQuery
      searchPreparation = null
      search(pendingQuery)
      return
    }
    searchPreparation = null
    if (!unified) { if (current) current.retrySearch(); return }
    eachHost(function(host) { if (root.searchParticipant(host) && host.searchStatus.canRetry) host.retrySearch() })
  }
  readonly property string rawQuery: unified || !current ? "" : current.rawQuery
  readonly property string rawLabelId: unified || !current ? "" : current.rawLabelId
  readonly property bool listLoading: unified
    ? !!unifiedSnapshot.loading : (!!current && current.listLoading)
  // Invariant: Failed or signed-out accounts must not keep unified loading placeholders active forever.
  readonly property bool listLoaded: unified
    ? !!unifiedSnapshot.loaded : (!!current && current.listLoaded)
  // Invariant: Unified search remains busy while any participating server is still searching.
  readonly property bool serverSearchLoading: unified
    ? !!unifiedSnapshot.serverSearchLoading
    : (!!current && current.serverSearchLoading)
  readonly property bool hasMore: unified
    ? !!unifiedSnapshot.hasMore : (!!current && current.hasMore)
  readonly property bool selectionIsPreview: !!reading && reading.selectionIsPreview

  readonly property string resultSummary: {
    if (!unified) return current ? current.resultSummary : ""
    var observed = listEpoch
    var estimate = 0
    eachHost(function(host) { if (root.searchParticipant(host)) estimate += Number(host.resultEstimate || 0) })
    return Model.resultSummary(unifiedMessages, estimate, hasMore)
  }
  // Invariant: reading owns all message details, independently of which account supplies the visible list.
  readonly property var reading: unified ? selectionHost : current

  // Invariant: Unified selected IDs must match account-qualified row IDs; hosts retain account-local IDs.
  readonly property string selectedId: {
    if (!reading) return ""
    if (!unified) return reading.selectedId
    return Unified.unifiedId(reading.accountId, reading.selectedId)
  }
  readonly property var selectedMessage: reading ? reading.selectedMessage : null
  readonly property var selectedBody: reading ? reading.selectedBody : ({ text: "", source: "" })
  readonly property bool selectedHasHtml: reading ? reading.selectedHasHtml : false
  readonly property var selectedDocument: reading ? reading.selectedDocument : null
  readonly property var selectedReaderDocument: reading ? reading.selectedReaderDocument : null
  readonly property bool selectedReaderTooHeavy: !!reading && reading.selectedReaderTooHeavy
  readonly property bool selectedReaderEmpty: !reading || reading.selectedReaderEmpty
  readonly property int selectedReaderRemoteImages: reading ? reading.selectedReaderRemoteImages : 0
  readonly property var selectedImages: reading ? reading.selectedImages : []
  readonly property int selectedBlockedImages: reading ? reading.selectedBlockedImages : 0
  readonly property int selectedRemoteImages: reading ? reading.selectedRemoteImages : 0
  readonly property bool remoteImagesAllowed: !!reading && reading.remoteImagesAllowed
  readonly property var selectedAttachments: reading ? reading.selectedAttachments : []
  readonly property bool selectedTooHeavy: !!reading && reading.selectedTooHeavy
  readonly property var selectedInvite: reading ? reading.selectedInvite : null
  readonly property string unsubscribeLabel: reading ? reading.unsubscribeLabel : ""
  readonly property string unsubscribeDetail: reading ? reading.unsubscribeDetail : ""
  readonly property bool unsubscribing: !!reading && reading.unsubscribing
  readonly property bool detailLoading: !!reading && reading.detailLoading
  readonly property bool detailPainted: !!reading && reading.detailPainted
  // Invariant: Sending state spans all account hosts, including hidden mailboxes.
  readonly property var sendingHost: {
    for (var hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var host = accountHosts.objectAt(hostIndex)
      if (host && host.sending) return host
    }
    return null
  }
  readonly property bool sending: !!sendingHost
  readonly property var pendingSendHost: {
    var newest = null
    var newestSend = null
    for (var accountIndex = 0; accountIndex < accountHosts.count; accountIndex++) {
      var host = accountHosts.objectAt(accountIndex)
      var latest = host ? host.latestSend : null
      if (!latest || !host.sendPending) continue
      if (!newestSend || latest.order > newestSend.order
          || (latest.order === newestSend.order && latest.queuedAt > newestSend.queuedAt)) {
        newest = host
        newestSend = latest
      }
    }
    return newest
  }
  readonly property bool sendAwaitingConnection: !!pendingSendHost && !!pendingSendHost.latestSend
    && pendingSendHost.latestSend.error === "outbox_awaiting_connection"
  readonly property bool sendPending: !!pendingSendHost
  readonly property int sendSecondsRemaining: pendingSendHost
    ? pendingSendHost.sendSecondsRemaining : 0
  readonly property string lastError: accountRegistryError || (unified
    ? (unifiedBatchAction.error || unifiedSnapshotError || unifiedSnapshot.error || "") : (current ? current.lastError : ""))
  // Invariant: Unified action status reports the newest available account notice.
  readonly property string actionStatus: {
    if (!unified) return current ? current.actionStatus : ""
    if (unifiedBatchAction.status !== "") return unifiedBatchAction.status
    var _epoch = listEpoch
    var newest = ""
    var at = -1
    for (var hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var host = accountHosts.objectAt(hostIndex)
      if (!host || String(host.actionStatus || "") === "") continue
      if (host.actionStatusAt > at) {
        at = host.actionStatusAt
        newest = String(host.actionStatus)
      }
    }
    return newest
  }
  readonly property int sendPendingCount: {
    var total = 0
    for (var hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var host = accountHosts.objectAt(hostIndex)
      if (host) total += host.sendPendingCount
    }
    return total
  }
  readonly property int sendingCount: {
    var total = 0
    for (var hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var host = accountHosts.objectAt(hostIndex)
      if (host && host.sending) total += 1
    }
    return total
  }
  readonly property int runningActionCount: {
    var total = 0
    for (var hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var host = accountHosts.objectAt(hostIndex)
      if (host && host.pendingAction !== "") total += 1
    }
    return total
  }
  readonly property int queuedActionCount: {
    var total = 0
    for (var hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var host = accountHosts.objectAt(hostIndex)
      if (host) total += host.queuedActions.length
    }
    return total
  }
  readonly property string activityStatus: Model.activityStatus({
    sending: sendingCount, queuedSends: sendPendingCount,
    running: runningActionCount, waiting: queuedActionCount
  })
  readonly property string signInProgress: current ? current.signInProgress : ""
  // Invariant: Credential rejection offers repair without implicitly signing out.
  readonly property bool credentialsRejected: !!current && current.credentialsRejected
  // Invariant: A single account's sync age is not a freshness claim for unified view.
  readonly property string syncedLabel: current ? current.syncedLabel : ""

  function refresh() {
    if (searchActive) searchGeneration++
    if (!unified) {
      if (current) current.refresh(true)
      return
    }
    eachHost(function(host) { if (root.searchParticipant(host)) host.refresh(true) })
  }
  // Invariant: Extend every incomplete source before merging beyond the oldest visible row of the shortest source.
  function loadMore() {
    if (!unified) {
      if (current) current.loadMore()
      return
    }
    eachHost(function(host) { if (root.searchParticipant(host) && host.hasMore) host.loadMore() })
  }
  function select(id, previewOnly) {
    if (!unified) {
      if (current) current.select(id, previewOnly)
      return
    }
    var host = hostForId(id)
    if (!host) return
    // Invariant: Clear other accounts' selections so stale message details cannot answer for the new reader.
    eachHost(function(other) { if (other !== host) other.clearSelection() })
    selectionHost = host
    host.select(sourceIdFor(id), previewOnly)
  }
  function clearSelection() {
    if (!unified) {
      if (current) current.clearSelection()
      return
    }
    eachHost(function(host) { host.clearSelection() })
    selectionHost = null
  }
  function markPreviewRead(id) {
    if (!id) return false
    if (unified) {
      var host = hostForId(id)
      return host ? host.markPreviewRead(sourceIdFor(id)) : false
    }
    return current ? current.markPreviewRead(id) : false
  }
  // Invariant: Allowing remote images changes the preference for every message.
  function showRemoteImages() { setAlwaysShowImages(true) }
  function fetchDisplayImage(source, callback) {
    if (reading) return reading.fetchDisplayImage(source, callback)
    if (typeof callback === "function") callback("")
  }
  function unsubscribe() { if (reading) reading.unsubscribe() }
  function cursorOffset(cursorId, delta) {
    if (unified) return Unified.cursorOffset(unifiedMessages, cursorId, delta)
    return current ? current.cursorOffset(cursorId, delta) : ""
  }
  function selectMailbox(key) {
    searchPreparationSerial++
    searchPreparation = null
    submittedUnifiedQuery = ""
    searchParticipantIds = null
    searchGeneration++
    if (!unified) {
      if (current) current.selectMailbox(key)
      return
    }
    unifiedMailboxKey = String(key)
    clearSelection()
    eachHost(function(host) { host.selectMailbox(key) })
  }
  function search(text) {
    var query = String(text || "").trim()
    if ((query !== "" && query === searchQuery && searchStatus.canStop)
        || (query === preparingSearchQuery && searchPreparation && searchPreparation.phase === "preparing")) return
    var serial = ++searchPreparationSerial
    var combined = unified
    var selected = current
    var reference = Date.now()
    var participants = []
    eachHost(function(host) {
      if ((combined && host.accountId) || (!combined && host === selected))
        participants.push({id:String(host.accountId || ""), host:host})
    })
    preparingSearchQuery = query
    if (!query || !searchAssistanceAvailable) {
      submitSearch(query, reference, participants, combined)
      return
    }
    searchPreparation = SearchState.status("preparing", "", "", 0)
    for (var index = 0; index < participants.length; index++)
      participants[index].serial = participants[index].host.prepareSearch(query, reference)
    backend.call("providers.resolve", {provider:"gmail",operation:"query",search:query,asOf:reference}, function(result, failure) {
      if (!root || serial !== root.searchPreparationSerial || combined !== root.unified
          || (!combined && selected !== root.current)) return
      var preparation = result && result.search ? result.search : {}
      if (failure || !result || preparation.valid === false) {
        var message = failure || !result ? "Could not prepare this search. Try again."
          : String(preparation.message || "Check quotes, groups and filter values, then try again.")
        root.searchPreparation = SearchState.status("invalid", message, "local_search_invalid", 0)
        for (var index = 0; index < participants.length; index++) {
          var member = participants[index]
          if (root.findAccount(member.id) === member.host && member.serial === member.host.providerQuerySerial)
            member.host.submittedSearch.reject(message)
        }
        return
      }
      root.submitSearch(query, reference, participants, combined)
    })
  }

  function submitSearch(query, reference, participants, combined) {
    searchPreparation = null
    searchGeneration++
    if (combined) {
      submittedUnifiedQuery = query
      searchParticipantIds = query ? participants.map(function(member) { return member.id }) : null
    }
    for (var index = 0; index < participants.length; index++) {
      var member = participants[index]
      if ((member.id ? findAccount(member.id) === member.host : current === member.host))
        member.host.searchPrepared(query, reference, member.serial)
    }
    bumpListEpoch()
  }

  readonly property bool canManageLabels: !!current && current.ready

  // Invariant: Deferred label actions retain the opening account ID because Gmail label IDs can collide. Only an omitted account ID resolves to current.
  function labelOwner(accountId, mustBeReady) {
    var id = String(accountId || "")
    var owner = id === "" ? current : findAccount(id)
    if (!owner) {
      if (current) current.fail("That mailbox is no longer set up, so nothing was changed")
      return null
    }
    if (mustBeReady === true && !owner.ready) {
      owner.fail("That mailbox is signed out, so nothing was changed")
      return null
    }
    return owner
  }
  function labelById(id, accountId) {
    var owner = String(accountId || "") === "" ? current : findAccount(accountId)
    return owner ? owner.labelActions.labelById(id) : null
  }
  function labelsOf(accountId) {
    var owner = String(accountId || "") === "" ? current : findAccount(accountId)
    return owner ? owner.labels : []
  }
  function createLabel(parentPath, leaf, accountId) {
    var owner = labelOwner(accountId, true)
    return owner ? owner.labelActions.createLabel(parentPath, leaf) : false
  }
  function renameLabel(id, leaf, accountId) {
    var owner = labelOwner(accountId, true)
    return owner ? owner.labelActions.renameLabel(id, leaf) : false
  }
  function moveLabel(id, parentPath, accountId) {
    var owner = labelOwner(accountId, true)
    return owner ? owner.labelActions.moveLabel(id, parentPath) : false
  }
  function deleteLabel(id, accountId) {
    var owner = labelOwner(accountId, true)
    return owner ? owner.labelActions.deleteLabel(id) : false
  }

  // Invariant: Provider-specific address queries require a single-account view.
  function searchAddress(query, text) {
    if (unified) {
      fail("Searching by address needs one mailbox on screen")
      return
    }
    if (current) current.search(text, query)
  }
  // Invariant: Label selection retains both display name and provider ID and requires a single-account view.
  function selectLabel(name, labelId) {
    searchPreparationSerial++
    searchPreparation = null
    searchGeneration++
    if (current && !unified) current.selectLabel(name, labelId)
  }
  // Invariant: Capability refusals come from the row's owning provider, not the visible account.
  function refuseUnavailableAction(action, id) {
    var host = id === undefined ? current : hostForId(id)
    if (!host) host = current
    return host ? host.refuseUnavailableAction(action) : true
  }
  function act(id, action, quiet, memberOnly) {
    unifiedBatchAction.clear()
    var host = hostForId(id)
    return host ? host.act(sourceIdFor(id), action, quiet, memberOnly) : false
  }
  function toggleStar(id) {
    unifiedBatchAction.clear()
    var host = hostForId(id)
    if (host) host.toggleStar(sourceIdFor(id))
  }
  function markAllRead() {
    if (!unified) {
      if (current) current.markAllRead()
      return
    }
    eachHost(function(host) { host.markAllRead() })
  }
  UnifiedBatchAction { id: unifiedBatchAction; service: root }
  function actMany(ids, action, completion) {
    if (!unified) return current ? current.actMany(ids, action, completion) : false
    return unifiedBatchAction.run(ids, action, completion)
  }
  // Invariant: Sending routes through the account named by the selected From identity.
  function send(fields) {
    var values = fields || ({})
    var host = sendHostFor(values)
    if (!host) return false
    sendSequence += 1
    return host.send(withSignatures(withSourceDraftId(values), host),
      "send-" + sendSession + "-" + sendSequence, sendSequence)
  }

  function sendAgentProposal(proposalId, fields) {
    var id = String(proposalId || "")
    if (!/^[a-f0-9]{32}-[0-9]+$/.test(id)) return false
    var host = sendHostFor(fields)
    if (!host) return false
    sendSequence += 1
    // Invariant: The durable outbox owns proposal-send idempotency across windows and restarts.
    var outgoing = Object.assign({}, fields, {exactBody: true})
    return host.send(outgoing, "agent-" + id, sendSequence)
  }
  function agentProposalQueue(accountId) {
    var host = findAccount(String(accountId || ""))
    return host ? host.sendQueue : null
  }

  // Invariant: An explicit mailbox identity must resolve; address fallback applies only when identity is omitted.
  function sendHostFor(fields) {
    var values = fields || ({})
    var target = draftOwner(values)
    if (target !== "") return findAccount(target)
    var host = senderFor(String(values.from || ""))
    return host ? host : current
  }

  // Invariant: Draft ownership comes from the explicit account or the account encoded in its unified ID.
  function draftOwner(values) {
    var named = String(values.accountId || "")
    if (named !== "") return named
    return Unified.accountOf(String(values.draftId || ""))
  }

  // Invariant: Decode unified draft IDs even after leaving unified view; provider-local IDs cannot contain the separator.
  function withSourceDraftId(values) {
    var id = String(values.draftId || "")
    if (Unified.accountOf(id) === "") return values
    var result = ({})
    for (var key in values) result[key] = values[key]
    result.draftId = Unified.sourceIdOf(id)
    return result
  }

  // Invariant: Resolve aliases from live account hosts because persisted entries do not contain them.
  function senderFor(address) {
    var wanted = String(address || "").trim().toLowerCase()
    if (wanted === "") return null
    var hostIndex
    for (hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var host = accountHosts.objectAt(hostIndex)
      if (host && String(host.accountEmail || "").toLowerCase() === wanted) return host
    }
    for (hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
      var other = accountHosts.objectAt(hostIndex)
      if (!other) continue
      var aliases = other.availableSendAsAliases || []
      for (var aliasIndex = 0; aliasIndex < aliases.length; aliasIndex++) {
        var alias = aliases[aliasIndex]
        var email = String((alias && alias.email) || alias || "").trim().toLowerCase()
        if (email === wanted) return other
      }
    }
    return null
  }

  // Invariant: The service supplies both signature forms from the sending account entry; hosts and views keep no independent signature copy.
  function withSignatures(fields, host) {
    var values = {}
    var source = fields || ({})
    for (var key in source) values[key] = source[key]
    var entry = Accounts.find(accountList, host ? String(host.accountId || "") : activeAccountId)
    values.signature = entry ? String(entry.signature || "") : ""
    values.signatureHtml = entry ? String(entry.signatureHtml || "") : ""
    return values
  }

  readonly property string sendSession: Date.now().toString(36) + "-" + Math.random().toString(36).slice(2)
  property int sendSequence: 0

  function saveDraft(fields, callback) {
    var values = fields || ({})
    var target = draftOwner(values)
    var host = target !== "" ? findAccount(target) : current
    if (!host) {
      if (typeof callback === "function") callback(null, "The mailbox for this draft is unavailable")
      return null
    }
    return host.saveDraft(withSignatures(withSourceDraftId(values), host), callback)
  }
  function fail(text) { if (current) current.fail(text) }
  function note(text) { if (current) current.note(text) }
  function undoSend(callback) {
    var host = pendingSendHost
    if (!host) return false
    // Invariant: Undo keeps unified view visible because the restored draft already names its account.
    if (host !== current && !unified) {
      for (var hostIndex = 0; hostIndex < accountHosts.count; hostIndex++) {
        if (accountHosts.objectAt(hostIndex) !== host) continue
        switchToIndex(hostIndex)
        break
      }
    }
    return host.undoSend(callback)
  }
  function loadAttachments(messageId, attachments, callback, draftKey, ownerAccountId) {
    var bound = ownerAccountId !== undefined && ownerAccountId !== null
    var owner = bound ? String(ownerAccountId) : ""
    var encodedOwner = Unified.accountOf(messageId)
    if (bound && (owner === "" || (encodedOwner !== "" && encodedOwner !== owner))) {
      if (typeof callback === "function") callback([], "These attachments belong to a different mailbox")
      return null
    }
    var host = bound ? findAccount(owner) : hostForId(messageId)
    if (!host) {
      if (typeof callback === "function") callback([], "The mailbox for these attachments is unavailable")
      return null
    }
    var source = bound ? (encodedOwner !== "" ? Unified.sourceIdOf(messageId) : String(messageId || "")) : sourceIdFor(messageId)
    return host.loadAttachments(source, attachments, callback, draftKey)
  }
  function openAttachment(messageId, attachment) {
    var host = hostForId(messageId)
    if (host) host.openAttachment(sourceIdFor(messageId), attachment)
  }

  function previewAttachment(messageId, attachment, callback) {
    var host = hostForId(messageId)
    if (host) return host.previewAttachment(sourceIdFor(messageId), attachment, callback)
    if (typeof callback === "function") callback("")
    return null
  }

  function saveAttachment(messageId, attachment) {
    var host = hostForId(messageId)
    if (host) host.saveAttachment(sourceIdFor(messageId), attachment)
  }

  // Invariant: Attachment progress keys include the account because provider-local attachment IDs can collide.
  function attachmentIsSaving(messageId, attachmentId) {
    var key = String(attachmentId || "")
    if (key === "") return false
    if (!unified) return !!savingAttachmentIds[key]
    var owner = Unified.accountOf(messageId)
    if (owner === "") return false
    return !!savingAttachmentIds[Unified.unifiedId(owner, key)]
  }
  // Invariant: Reply sender selection comes from the message's owning account.
  function preferredSendAs(recipients) {
    var host = reading || current
    return host ? host.preferredSendAs(recipients) : null
  }

  // Invariant: New reply drafts inherit the selected message's account, including unified view.
  readonly property string composeAccountId: {
    var host = reading || current
    return host ? String(host.accountId || "") : ""
  }
  function signIn() { if (current) current.signIn() }
  function cancelSignIn() { if (current) current.cancelSignIn() }
  function signOut() { if (current) current.signOut() }
  // Invariant: Setup writes through the editing index because an unnamed row has no account ID.
  function configureCurrentAccount(values) {
    return configureAccount(editingIndex(), values)
  }

  // Invariant: Save OAuth configuration before the account host starts its browser flow.
  function configureCurrentAccountAndSignInOAuth(values) {
    if (!configureCurrentAccount(values)) return false
    var accountId = String(editingEntry().id || "")
    Qt.callLater(function() {
      var host = root.findAccount(accountId)
      if (host) host.signIn()
    })
    return true
  }

  function indexOfActiveAccount() {
    var accounts = accountList ? accountList.accounts : []
    for (var recipientIndex = 0; recipientIndex < accounts.length; recipientIndex++) {
      if (accounts[recipientIndex].id !== "" && accounts[recipientIndex].id === accountList.activeId) return recipientIndex
    }
    // Invariant: If no saved ID matches, setup uses the first unnamed row.
    for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      if (accounts[accountIndex].id === "") return accountIndex
    }
    return -1
  }

  // Invariant: An unnamed draft is addressed by its active index, never the saved mailbox behind it.
  function editingIndex() {
    return activeIndex >= 0 ? activeIndex : indexOfActiveAccount()
  }

  // Invariant: A unified row resolves its owning mailbox before opening a provider URL.
  function openInBrowser(id) {
    var host = hostForId(id)
    if (host) host.openInBrowser(sourceIdFor(id))
  }
  function openWebInbox() { if (current) current.openWebInbox() }

  // Invariant: Provider websites remain available during setup before an account has an address.
  function openProviderWebsite(id) {
    var url = Provider.webHomeUrl(id)
    if (url !== "") openExternal(url)
  }

  function openCloudConsole() { if (current) current.openCloudConsole() }
  function openGmailApiPage() { if (current) current.openGmailApiPage() }

  // Invariant: Project links work before an account is signed in.
  function openProjectPage() {
    openExternal("https://github.com/dreinecke/magpie")
  }

  function openAuthorPage() {
    openExternal("https://x.com/huacnlee")
  }
  function openConsentScreen() { if (current) current.openConsentScreen() }



  signal replySent(string sendId)
  signal replyFailed(string sendId)

  // Invariant: Before restoring a failed send outside unified view, select its owning account.
  function forwardReplyFailure(index, sendId) {
    var host = accountAt(index)
    // Invariant: A failed send preserves unified view because its draft already names the owning account.
    if (host && host !== current && !unified) switchToIndex(index)
    replyFailed(String(sendId || ""))
  }

  // Invariant: Model hosts by count; replacing an account array must not destroy every host and its in-flight callbacks.
  Instantiator {
    id: accountHosts
    model: root.accountCount

    delegate: MailAccount {
      platform: root
      required property int index

      readonly property var entry: {
        var accounts = root.accountList ? root.accountList.accounts : []
        return index < accounts.length ? accounts[index] : null
      }

      notificationForeground: Commons.Color.foreground
      notificationAccent: Commons.Color.accent
      pluginDir: root.pluginDir
      accountId: entry ? entry.id : ""
      backend: root.backend
      configuredEmail: entry ? entry.email : ""
      // Invariant: Provider and server settings come from the same account entry.
      // Invariant: Only the first Gmail account may adopt the legacy client-keyed refresh token.
      mayAdoptLegacyToken: index === 0
      settings: root.settings
      monitoredIds: entry ? entry.monitored : []
      // Invariant: Remote-image permission is a reader-wide preference shared by every account.
      alwaysShowImages: root.alwaysShowImages

      onNotificationActivated: function(accountId, messageId) {
        root.openNotification(accountId, messageId)
      }
      onAccountIdentified: function(email) { root.nameAccount(index, email) }
      // Invariant: Learned JMAP settings update the owning account entry without discarding its other fields.
      onReadyChanged: root.recount()
      onInboxUnreadChanged: root.recount()
      onReplySent: function(sendId) { root.replySent(String(sendId || "")) }
      onReplyFailed: function(sendId) { root.forwardReplyFailure(index, sendId) }
      onMonitoredMigrated: function(ids) { root.setMonitoredIds(index, ids) }

      // Performance: List updates invalidate unified projections without rebuilding sender identities.
      onSearchStarted: { if (!root.unified) root.searchGeneration++ }
      onSearchStatusChanged: root.bumpListEpoch()
      onLabelsChanged: root.bumpListEpoch()
      onMessagesChanged: root.bumpListEpoch()
      onListLoadingChanged: root.bumpListEpoch()
      onListLoadedChanged: root.bumpListEpoch()
      onHasMoreChanged: root.bumpListEpoch()
      onLastErrorChanged: root.bumpListEpoch()

      Component.onCompleted: Qt.callLater(root.refreshCurrent)
      Component.onDestruction: Qt.callLater(root.refreshCurrent)
    }
  }

  onActiveAccountIdChanged: refreshCurrent()
  onAccountListChanged: Qt.callLater(refreshCurrent)

  FileView {
    id: windowFile
    path: root.configPath("window.json")
    printErrors: false
    onLoaded: root.applyWindowPrefs(text())
    // Invariant: A missing window-preference file is a normal first-run state.
    onLoadFailed: root.applyWindowPrefs("")
  }

  Timer {
    id: windowPrefsSettling
    interval: 500
    onTriggered: root.saveWindowPrefs()
  }

  Timer {
    id: restoreTimer
    interval: 200
    repeat: false
    onTriggered: root.reopenWindow()
  }

  QtObject {
    id: inactiveAgentContext
    property string error: ""
    property bool busy: false
    function request() { return false }
  }

  QtObject {
    id: inactiveEventSuggester
    property var suggestions: []
    function compose() { return false }
    function dismiss() { return false }
  }

  QtObject {
    id: inactiveAgentRunner
    property bool providerAvailable: false
    property string availabilityError: ""
    property int selectionRevision: 0
    property string lastError: ""
    property bool starting: false
    property var byMessage: ({})
    property bool attention: false
    property var attentionByMessage: ({})
    property bool anyActive: false
    property var jobs: []
    property string shownId: ""
    property string shownOutput: ""
    property var shownTranscript: []
    property var shownProposals: []
    property string previousPage: ""
    property bool loadingEarlier: false
    property int listingOffset: 0
    property bool hasMoreJobs: false
    property bool cancelling: false
    function acknowledge() {}
    function cancel() { return false }
    function cancelById() { return false }
    function draftJobs() { return [] }
    function forget() {}
    function forgetFinished() {}
    function historyFor() { return [] }
    function isActive() { return false }
    function jobById() { return null }
    function loadEarlier() { return false }
    function canContinueSelection() { return false }
    function pageChats() {}
    function refresh() {}
    function selectionJob() { return null }
    function show() {}
    function start() { return false }
    function wantsAttention() { return false }
  }

  Loader {
    id: agentContextLoader
    active: root.hasAgent
    sourceComponent: Component { AgentContext { service: root; runner: root.agentRunner } }
  }

  Loader {
    id: eventSuggesterLoader
    active: root.hasAgent
    sourceComponent: Component { EventSuggester { service: root; runner: root.agentRunner } }
  }

  Loader {
    id: agentRunnerLoader
    active: root.hasAgent
    // Invariant: The loader facade preserves shell integration while AI capability controls instance creation.
    property string pluginDir: root.pluginDir
    property var backend: root.backend
    readonly property var jobs: item ? item.jobs : []
    function applyListing(values) { if (item) item.applyListing(values) }
    sourceComponent: Component {
      AgentRunner {
        objectName: "agent-runner"
        backend: agentRunnerLoader.backend
        pluginDir: root.pluginDir
        selectedAgent: root.aiAgent
        selectedModel: root.aiModel
        selectionResetAt: Number(root.settings ? root.settings.aiChatResetAt || 0 : 0)
        // Invariant: AI row display and cancellation use account ownership because message IDs are account-local.
        accountId: root.current ? root.current.accountId : ""
        onJobFinished: function(job) {
          var text = Agent.finishedNote(job)
          var owner = root.findAccount(String(job && job.accountId || "")) || root.current
          if (text !== "" && owner) owner.note(text)
        }
        onFailed: function(text) { if (root.current) root.current.fail(text) }
      }
    }
  }

  Component {
    id: hostProcessComponent
    Process {
      id: hostProcess
      required property string operation
      property var callback: null
      property string payload: ""
      property bool processStarted: false
      property bool completed: false
      objectName: operation === "write" ? "configuration-writer" : "host-process"
      stdinEnabled: payload !== ""
      stdout: StdioCollector { waitForEnd: true }
      stderr: StdioCollector { waitForEnd: true }
      readonly property Timer startDeadline: Timer {
        objectName: "config-write-start-deadline"
        interval: 10000
        running: hostProcess.operation === "write" && !hostProcess.processStarted && !hostProcess.completed
        onTriggered: {
          hostProcess.running = false
          hostProcess.finish(-1)
        }
      }
      onStarted: {
        processStarted = true
        if (payload !== "") { write(payload); payload = "" }
      }
      function finish(exitCode) {
        if (completed) return
        completed = true
        var done = callback
        callback = null
        if (typeof done === "function") {
          if (operation === "write") done(exitCode === 0,
            exitCode === 0 ? "" : String(stderr.text || "Could not write configuration"))
          else {
            var value = null
            try { value = JSON.parse(String(stdout.text || "")) } catch (error) {}
            done(value || ({ok:false,error:String(stderr.text || "Host operation failed")}))
          }
        }
        destroy()
      }
      onExited: function(exitCode) { finish(exitCode) }
    }
  }

  Component {
    id: legacyCredentialProcessComponent
    Process {
      id: legacyCredentialProcess
      required property string operation
      property var done: null
      property string payload: ""
      objectName: "legacy-credential-" + operation
      stdinEnabled: operation === "put"
      stdout: StdioCollector { id: legacyCredentialOutput; waitForEnd: true }
      stderr: StdioCollector { waitForEnd: true }
      onStarted: if (operation === "put") {
        write(payload + "\n")
        payload = ""
      }
      onExited: function(exitCode) {
        payload = ""
        var callback = done
        done = null
        if (typeof callback === "function") {
          if (operation === "get") callback(exitCode === 0
            ? SecretText.fromKeyring(legacyCredentialOutput.text) : "",
            exitCode === 0 ? "" : (exitCode === 1
              ? "credential_missing" : "credential_store_unavailable"))
          else callback(exitCode === 0, exitCode === 0 ? "" : "credential_store_unavailable")
        }
        destroy()
      }
    }
  }

  Connections {
    target: root.backend
    function onNotification(method, parameters) {
      if (method === "accounts.changed" && parameters && parameters.revision !== root.accountsRevision)
        root.restoreAccountRegistry()
    }
    function onReadyChanged() {
      root.scheduleSenderIdentities()
      root.scheduleConversationProjection()
      if (!root.backend.ready) {
        root.contactsLoading = false
        return
      }
      if (root.accountsSaveQueued) root.saveAccounts(root.accountsSaveQueuedAllowDrop ? { allowDrop: true } : undefined)
      else root.restoreAccountRegistry()
      root.refreshRecipientContacts()
    }
  }

  Process {
    id: mailtoInstaller
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: defaultMailClientProcess
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (root.defaultMailClientBusy) {
        root.defaultMailClientBusy = false
        if (exitCode !== 0) root.defaultMailClientError =
          String(stderr.text || "").trim() || "Could not change the default mail client"
        // Invariant: Defer the status read until the current process exit handler has finished.
        Qt.callLater(root.refreshDefaultMailClient)
        return
      }
      if (exitCode === 0) root.defaultMailClient = String(stdout.text || "").trim()
    }
  }

  Component.onCompleted: {
    barBridge = BarBridge.publish(function() {
      return {
        ready: root.ready, windowOpen: root.windowOpen,
        showBarIcon: root.showBarIcon, unreadTotal: root.unreadTotal,
        barTooltip: root.barTooltip, contentDirection: root.contentDirection,
        barMessages: root.barMessages
      }
    }, function(values) { root.applySettings(BarBridge.settings(values, root.defaultSettingValues)) },
      function() { root.refresh() })
    Qt.callLater(root.restoreAccountRegistry)
    Qt.callLater(root.refreshRecipientContacts)
    Qt.callLater(root.registerMailtoHandler)
    Qt.callLater(root.refreshDefaultMailClient)
  }

  property var barBridge: null
  Component.onDestruction: BarBridge.clear(barBridge)
}

import QtQuick
import "../controls" as Widgets
import "../settings"
import QtQuick.Controls
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../message/Direction.js" as Direction
import "../message/Message.js" as Mail
import "../message/Html.js" as Html
import "../compose/Recipients.js" as Recipients
import "../compose/Senders.js" as Senders
import "../agent/Agent.js" as Agent

DropArea {
  id: root

  required property var service
  required property color textColor
  required property color backgroundColor
  required property color accentColor
  required property color dimColor
  required property color dimmerColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  readonly property int formInset: MailStyle.space(18)
  readonly property int formLabelWidth: MailStyle.space(52)
  readonly property int formLabelGap: MailStyle.space(10)
  readonly property real actionBarHeight: actions.height

  property bool opened: false
  property bool userModified: false
  property bool settingBodyText: false
  // Invariant: undo-window drafts remain paired with their outbox send IDs in dispatch order.
  property var parkedDrafts: []
  readonly property bool parkedForSend: parkedDrafts.length > 0
  readonly property var pendingDraft: parkedDrafts.length > 0
    ? parkedDrafts[parkedDrafts.length - 1].draft : null
  property var interruptedDraft: null
  property var recoveryDrafts: []
  property string accountId: ""
  property string sourceDraftId: ""
  // Invariant: draft ownership determines the signature; binding it to the active mailbox can send
  // another identity’s details and overwrite manual edits.
  readonly property string accountSignature: root.service
    ? String(root.service.signatureFor(root.accountId) || "") : ""
  // Invariant: text equality cannot detect an edit later undone; track edit history before
  // replacing the placed body.
  property string placedBody: ""
  property bool bodyWasEdited: false
  property string bodyPrefix: ""
  property string bodyQuote: ""
  // Docs: overlay popups are exposed because they are not children of this view.
  readonly property bool fromMenuOpened: fromMenu.opened
  readonly property bool contactsPickerOpened: contactsPicker.opened
  property int restoreRevision: 0
  property real restoreFlashOpacity: 0
  property string mode: "new"
  property string threadId: ""
  property string inReplyTo: ""
  property bool ccVisible: false
  property bool bccVisible: false
  property bool replyToVisible: false

  property bool agentOpen: false
  property bool agentWorking: false
  property bool agentAttention: false
  signal agentRequested(real sceneX, real sceneY)

  property string draftKey: newDraftKey()
  function newDraftKey() { return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2) }
  function currentFields() {
    return ({ to: toField.text, cc: ccField.text, bcc: bccField.text,
      subject: subjectField.text, body: Agent.replyOnly(bodyEdit.text, retainedReplyQuote()),
      from: fromEmail, accountId: accountId, draftId: sourceDraftId, draftKey: draftKey, replyMessageId: replyMessageId,
      envelope: outgoingEnvelope() })
  }

  property string agentParentJobId: ""
  property string replyMessageId: ""
  function retainedReplyQuote() {
    if (mode !== "reply" && mode !== "replyAll") return ""
    return Agent.replyOnly(bodyEdit.text, bodyQuote) !== bodyEdit.text ? bodyQuote : ""
  }
  readonly property bool attachmentsReady: !forwardAttachmentsLoading
    && forwardAttachmentError === "" && attachmentRecoveryError === "" && !attachmentHostPending
    && !attachmentReadPending && attachJobs.length === 0

  function outgoingEnvelope() {
    if (!attachmentsReady) return null
    return {accountId: accountId, draftKey: draftKey, from: fromEmail,
      to: toField.text, cc: ccField.text, bcc: bccField.text, replyTo: replyToField.text,
      subject: subjectField.text, body: bodyEdit.text,
      attachments: JSON.parse(JSON.stringify(allOutgoingAttachments())), draftId: sourceDraftId,
      threadId: mode === "forward" ? "" : threadId, inReplyTo: mode === "forward" ? "" : inReplyTo,
      replyMessageId: replyMessageId, replyQuote: retainedReplyQuote()}
  }
  function beginProposal(envelope, parentId) {
    begin("new", null, "", [])
    restoreDraft(Agent.proposalDraft(envelope, parentId, draftKey))
  }
  function applyProposal(envelope) {
    if (!opened || String(envelope.accountId) !== accountId) return false
    if (envelope.draftKey ? String(envelope.draftKey) !== draftKey
        : !replyMessageId || String(envelope.replyMessageId || "") !== replyMessageId) return false
    bodyQuote = String(envelope.replyQuote || "")
    subjectField.text = String(envelope.subject)
    replaceBody(envelope.body)
    return true
  }
  function sendProposal(envelope, proposalId, parentId) {
    if (!service || proposalRoutingChanged(envelope)) return false
    // Invariant: create recovery state before dispatch without replacing newer manual edits.
    var draft = Agent.proposalDraft(envelope, parentId, String(envelope.draftKey || newDraftKey()))
    var accepted = service.sendAgentProposal(proposalId, fieldsForDraft(draft))
    if (!accepted) return false
    parkDraftForSend(String(accepted), draft)
    return accepted
  }

  function proposalRoutingChanged(envelope) {
    if (!opened || !envelope) return false
    // Invariant: a matched draft owns its current routing; a proposal must not restore stale
    // recipients.
    var sameDraft = envelope.draftKey ? String(envelope.draftKey) === draftKey
      : replyMessageId !== "" && String(envelope.replyMessageId || "") === replyMessageId
    if (!sameDraft) return false
    return String(envelope.accountId || "") !== accountId
      || String(envelope.from || "") !== fromEmail
      || String(envelope.to || "") !== toField.text
      || String(envelope.cc || "") !== ccField.text
      || String(envelope.bcc || "") !== bccField.text
      || String(envelope.replyTo || "") !== replyToField.text
  }

  function replaceBody(text) {
    bodyEdit.remove(0, bodyEdit.length)
    bodyEdit.insert(0, String(text || ""))
    bodyWasEdited = true
    bodyEdit.cursorPosition = bodyEdit.length
    noteUserModified()
  }

  function insertAtCursor(text) {
    var insert = String(text || "")
    if (insert === "") return
    var at = Math.max(0, Math.min(bodyEdit.length, bodyEdit.cursorPosition))
    bodyEdit.insert(at, insert)
    bodyWasEdited = true
    noteUserModified()
  }
  property string fromEmail: ""
  property var replyRecipients: []
  property bool fromWasChosen: false
  property var toSuggestions: []
  property var ccSuggestions: []
  property var bccSuggestions: []
  property var originalAttachments: []
  property var forwardedAttachments: []
  property bool forwardAttachmentsLoading: false
  property string forwardAttachmentError: ""
  property int forwardLoadSerial: 0
  property string attachmentSourceMessageId: ""
  property string attachmentRecoveryError: ""
  property var pendingProviderLoads: []
  property var activeAttachJob: null
  property var attachmentReadGrants: []
  property var attachmentRecoveryJobs: []
  property var attachmentRecoveryFiles: []
  property var draftAttachments: []
  readonly property var attachmentPreviews: previewsFor(draftAttachments)
  function previewsFor(attachments) {
    var remaining = Html.MAX_DECODED_DOCUMENT_BYTES
    return attachments.map(function(attachment) {
      var source = "data:" + String(attachment.mimeType || "") + ";base64," + String(attachment.data || "")
      var decodedBytes = Html.rasterDecodedBytes(source)
      if (!decodedBytes || decodedBytes > remaining) return ""
      remaining -= decodedBytes
      return source
    })
  }
  property var attachJobs: []
  property bool attaching: false
  property bool pasteInFlight: false

  function noteDraftChanged() {
    if (opened) draftChanged()
  }

  function noteUserModified() {
    if (!opened) return
    userModified = true
    draftChanged()
  }

  function setBodyText(value) {
    settingBodyText = true
    bodyEdit.text = value
    settingBodyText = false
  }

  function hasUserChanges() { return userModified || draftAttachmentsPending(snapshotDraft()) }

  onAccountIdChanged: noteDraftChanged()
  onModeChanged: noteDraftChanged()
  onThreadIdChanged: noteDraftChanged()
  onInReplyToChanged: noteDraftChanged()
  onCcVisibleChanged: noteDraftChanged()
  onBccVisibleChanged: noteDraftChanged()
  onReplyToVisibleChanged: noteDraftChanged()
  onFromEmailChanged: noteDraftChanged()
  onDraftAttachmentsChanged: noteDraftChanged()
  onForwardedAttachmentsChanged: noteDraftChanged()
  onAttachJobsChanged: noteDraftChanged()
  onActiveAttachJobChanged: noteDraftChanged()
  onForwardAttachmentsLoadingChanged: noteDraftChanged()
  onAttachmentRecoveryErrorChanged: noteDraftChanged()

  readonly property string composeDir: service && typeof service.cachePath === "function"
    ? service.cachePath("compose") : ""
  property bool attachmentHostPending: false

  readonly property var contactBook: root.service
    && Array.isArray(root.service.recipientContacts)
    ? root.service.recipientContacts : []

  readonly property var fromAliases: {
    if (!root.service || !Array.isArray(root.service.sendAsAliases)) return []
    return root.service.sendAsAliases
  }

  // Invariant: send-as choices belong to the draft’s mailbox, including replies from the merged
  // list.
  readonly property var fromIdentities: Senders.visible(
    root.service ? root.service.sendIdentities : [],
    root.accountId !== "" ? root.accountId
      : (root.service ? String(root.service.activeAccountId || "") : ""),
    root.mode)

  readonly property bool canChooseFrom: fromIdentities.length > 1

  readonly property string title: {
    if (mode === "reply") return "Reply"
    if (mode === "replyAll") return "Reply all"
    if (mode === "forward") return "Forward"
    if (mode === "draft") return "Draft"
    return "New message"
  }

  function forgetOwned(attachments) {
    var owned = Array.isArray(attachments) ? attachments : []
    for (var entryIndex = 0; entryIndex < owned.length; entryIndex++) {
      if (owned[entryIndex] && owned[entryIndex].owned && owned[entryIndex].path)
        enqueueAttach("forget", owned[entryIndex].path)
    }
  }

  function clearCurrentDraft(forgetAttachments) {
    agentParentJobId = ""
    replyMessageId = ""
    composeTextSerial++
    pendingQuoteSummary = null
    pendingQuoteText = ""
    draftKey = newDraftKey()
    forwardLoadSerial++
    fromMenu.close()
    // Invariant: popups live in the window overlay and must close when this persistent composer is
    // hidden.
    contactsPicker.close()
    toField.text = ""
    ccField.text = ""
    bccField.text = ""
    replyToField.text = ""
    subjectField.text = ""
    setBodyText("")
    placedBody = ""
    bodyWasEdited = false
    bodyPrefix = ""
    bodyQuote = ""
    accountId = ""
    sourceDraftId = ""
    mode = "new"
    threadId = ""
    inReplyTo = ""
    ccVisible = false
    bccVisible = false
    replyToVisible = false
    fromEmail = ""
    replyRecipients = []
    fromWasChosen = false
    toSuggestions = []
    ccSuggestions = []
    bccSuggestions = []
    originalAttachments = []
    forwardedAttachments = []
    forwardAttachmentsLoading = false
    forwardAttachmentError = ""
    attachmentSourceMessageId = ""
    attachmentRecoveryError = ""
    attachmentRecoveryJobs = []
    attachmentRecoveryFiles = []
    var owned = draftAttachments
    draftAttachments = []
    attachJobs = []
    attaching = false
    pasteInFlight = false
    userModified = false
    if (forgetAttachments) forgetOwned(owned)
  }

  // Invariant: replacing a signature by text search could change a sign-off inside the quoted
  // message.
  property int composeTextSerial: 0
  property var pendingQuoteSummary: null
  property string pendingQuoteText: ""

  function placeBody() {
    var serial = ++composeTextSerial
    var account = accountId
    var previous = bodyEdit.text
    var previouslyEdited = bodyWasEdited
    var previousSubject = subjectField.text
    var parameters = { signature: accountSignature, quote: bodyQuote }
    if (pendingQuoteSummary) {
      parameters.summary = pendingQuoteSummary
      parameters.body = pendingQuoteText
    }
    if (!service || !service.backend) return
    service.backend.call("message.composeText", parameters, function(result, error) {
      if (serial !== root.composeTextSerial || account !== root.accountId || !root.opened) return
      if (error || !result) {
        if (root.service && typeof root.service.fail === "function") root.service.fail("Could not prepare the message text")
        return
      }
      if (bodyEdit.text !== previous || root.bodyWasEdited !== previouslyEdited) return
      root.bodyQuote = String(result.quote || "")
      root.pendingQuoteSummary = null
      root.pendingQuoteText = ""
      root.placedBody = root.bodyPrefix + String(result.body || "")
      root.setBodyText(root.placedBody)
      if (parameters.summary && (root.mode === "reply" || root.mode === "replyAll") && subjectField.text === previousSubject)
        subjectField.text = String(result.replySubject || previousSubject)
    })
  }

  // Invariant: changing From may rebuild only an untouched placed body, never the user’s edits.
  onAccountSignatureChanged: {
    if (!opened || mode === "draft") return
    if (bodyWasEdited || bodyEdit.text !== placedBody) return
    placeBody()
  }

  function snapshotDraft() {
    var jobs = attachJobs.concat(attachmentRecoveryJobs).filter(function(job) {
      return job.mode !== "forget"
    }).map(attachmentJobSnapshot)
    var pending = activeAttachJob && activeAttachJob.mode !== "forget" && activeAttachJob.owner === draftKey
      && activeAttachJob.accountId === accountId ? attachmentJobSnapshot(activeAttachJob) : null
    if (!pending && jobs.length > 1000) pending = jobs.shift()
    return ({
      draftKey: draftKey,
      replyMessageId: replyMessageId,
      agentParentJobId: agentParentJobId,
      to: toField.text,
      cc: ccField.text,
      bcc: bccField.text,
      replyTo: replyToField.text,
      subject: subjectField.text,
      body: bodyEdit.text,
      bodyQuote: bodyQuote,
      placedBody: placedBody,
      bodyWasEdited: bodyWasEdited,
      userModified: userModified,
      accountId: accountId,
      sourceDraftId: sourceDraftId,
      mode: mode,
      threadId: threadId,
      inReplyTo: inReplyTo,
      ccVisible: ccVisible,
      bccVisible: bccVisible,
      replyToVisible: replyToVisible,
      fromEmail: fromEmail,
      replyRecipients: replyRecipients.slice(),
      fromWasChosen: fromWasChosen,
      originalAttachments: originalAttachments.slice(),
      forwardedAttachments: forwardedAttachments.slice(),
      draftAttachments: draftAttachments.concat(attachmentRecoveryFiles),
      attachmentSourceMessageId: attachmentSourceMessageId,
      forwardAttachmentsLoading: forwardAttachmentsLoading,
      forwardAttachmentError: forwardAttachmentError,
      forwardLoadSerial: forwardLoadSerial,
      attachmentRecoveryError: attachmentRecoveryError,
      attachJobs: jobs,
      pendingAttachment: pending
    })
  }

  function restoreDraft(draft) {
    var saved = draft || ({})
    draftKey = String(saved.draftKey || newDraftKey())
    replyMessageId = String(saved.replyMessageId || "")
    agentParentJobId = String(saved.agentParentJobId || "")
    mode = String(saved.mode || "new")
    accountId = String(saved.accountId || "")
    sourceDraftId = String(saved.sourceDraftId || "")
    attachmentSourceMessageId = String(saved.attachmentSourceMessageId || sourceDraftId || "")
    forwardAttachmentsLoading = saved.forwardAttachmentsLoading === true
    forwardAttachmentError = String(saved.forwardAttachmentError || "")
    forwardLoadSerial = Math.max(0, Number(saved.forwardLoadSerial) || 0)
    attachmentRecoveryError = String(saved.attachmentRecoveryError || "")
    threadId = String(saved.threadId || "")
    inReplyTo = String(saved.inReplyTo || "")
    ccVisible = saved.ccVisible === true
    bccVisible = saved.bccVisible === true
    replyToVisible = saved.replyToVisible === true || String(saved.replyTo || "") !== ""
    fromEmail = String(saved.fromEmail || "")
    replyRecipients = Array.isArray(saved.replyRecipients)
      ? saved.replyRecipients.slice() : []
    fromWasChosen = saved.fromWasChosen === true
    originalAttachments = Array.isArray(saved.originalAttachments)
      ? saved.originalAttachments.slice() : []
    forwardedAttachments = Array.isArray(saved.forwardedAttachments)
      ? saved.forwardedAttachments.slice() : []
    draftAttachments = Array.isArray(saved.draftAttachments)
      ? saved.draftAttachments.slice() : []
    if ((mode === "forward" || mode === "draft") && originalAttachments.length > 0) {
      var retained = mode === "forward" ? forwardedAttachments : draftAttachments
      if (retained.length === 0 && saved.forwardAttachmentsLoading === undefined)
        forwardAttachmentsLoading = true
    }
    toField.text = String(saved.to || "")
    ccField.text = String(saved.cc || "")
    bccField.text = String(saved.bcc || "")
    replyToField.text = String(saved.replyTo || "")
    subjectField.text = String(saved.subject || "")
    bodyQuote = typeof saved.bodyQuote === "string" ? saved.bodyQuote : ""
    setBodyText(String(saved.body || ""))
    placedBody = String(saved.placedBody || "")
    bodyWasEdited = saved.bodyWasEdited === true
    userModified = typeof saved.userModified === "boolean"
      ? saved.userModified : hasMeaningfulDraft()
    opened = true
    restoreAttachmentWork(saved)
    rehydrateDraftAttachments()
  }

  function attachmentJobSnapshot(job) {
    return {mode: String(job.mode || "read"), path: String(job.path || ""),
      owner: String(job.owner || root.draftKey), accountId: String(job.accountId || root.accountId)}
  }

  function attachmentDraft(owner, account) {
    function matches(draft) {
      return draft && String(draft.draftKey || "") === String(owner)
        && (account === undefined || String(draft.accountId || "") === String(account))
    }
    if (root.opened && matches(root)) return root
    if (matches(root.interruptedDraft)) return root.interruptedDraft
    var drafts = root.recoveryDrafts.concat(root.parkedDrafts.map(function(entry) { return entry.draft }))
    for (var draftIndex = 0; draftIndex < drafts.length; draftIndex++)
      if (matches(drafts[draftIndex])) return drafts[draftIndex]
    return null
  }

  function draftAttachmentsPending(draft) {
    return !!draft && (draft.forwardAttachmentsLoading === true
      || String(draft.forwardAttachmentError || "") !== ""
      || String(draft.attachmentRecoveryError || "") !== ""
      || !!draft.pendingAttachment || (Array.isArray(draft.attachJobs) && draft.attachJobs.length > 0))
  }

  function restoreAttachmentWork(saved) {
    var jobs = Array.isArray(saved.attachJobs) ? saved.attachJobs.slice() : []
    var pending = saved.pendingAttachment
    var running = activeAttachJob && activeAttachJob.owner === draftKey
      && activeAttachJob.accountId === accountId
    if (pending && !running) jobs.unshift(pending)
    var replay = []
    attachmentRecoveryJobs = []
    attachmentRecoveryFiles = []
    for (var jobIndex = 0; jobIndex < jobs.length; jobIndex++) {
      var job = jobs[jobIndex] || ({})
      if (String(job.owner || "") !== draftKey || String(job.accountId || "") !== accountId) {
        attachmentRecoveryError = "An attachment could not be restored. Choose the file again."
        continue
      }
      if (["read", "recover", "recover-owned"].indexOf(String(job.mode)) < 0) {
        attachmentRecoveryError = "Attachment selection was interrupted. Choose the files again."
        continue
      }
      if (!hasAttachmentReadGrant(job)) {
        holdAttachmentRecovery(job)
        continue
      }
      replay.push(attachmentJobSnapshot(job))
    }
    attachJobs = replay
    attaching = replay.length > 0 || !!running
    pumpAttach()
    if (!forwardAttachmentsLoading) return
    var loadRunning = pendingProviderLoads.some(function(load) {
      return load.owner === root.draftKey && load.accountId === root.accountId
        && load.serial === root.forwardLoadSerial
    })
    if (!loadRunning) loadOriginalAttachments()
  }

  function rehydrateDraftAttachments() {
    var listed = draftAttachments.slice()
    var kept = []
    var recover = []
    for (var entryIndex = 0; entryIndex < listed.length; entryIndex++) {
      var file = listed[entryIndex] || ({})
      if (String(file.path || "") !== "" && String(file.data || "") === ""
          && String(file.handle || "") === "")
        recover.push(file)
      else kept.push(file)
    }
    if (recover.length === 0) return
    draftAttachments = kept
    for (var recoveryIndex = 0; recoveryIndex < recover.length; recoveryIndex++) {
      var file = recover[recoveryIndex]
      var job = {mode:file.owned === true ? "recover-owned" : "recover", path:String(file.path || ""),
        owner:draftKey, accountId:accountId}
      if (!hasAttachmentReadGrant(job)) {
        attachmentRecoveryFiles = attachmentRecoveryFiles.concat([file])
        updateAttachmentRecoveryMessage()
        continue
      }
      enqueueAttach(job.mode, job.path)
    }
  }

  function hasAttachmentReadGrant(job) {
    return attachmentReadGrants.some(function(grant) {
      return grant.owner === job.owner && grant.accountId === job.accountId && grant.path === job.path
    })
  }

  function holdAttachmentRecovery(job) {
    attachmentRecoveryJobs = attachmentRecoveryJobs.concat([attachmentJobSnapshot(job)])
    updateAttachmentRecoveryMessage()
  }

  function updateAttachmentRecoveryMessage() {
    var missing = attachmentRecoveryJobs.concat(attachmentRecoveryFiles)
    if (missing.length === 0) { attachmentRecoveryError = ""; return }
    var names = missing.slice(0, 3).map(function(entry) {
      var name = String(entry.path || "").split("/").pop()
      return name.length > 80 ? name.substring(0, 77) + "..." : name
    }).join(", ")
    var remaining = missing.length - 3
    attachmentRecoveryError = "Choose these files again: " + names
      + (remaining > 0 ? " and " + remaining + " more." : ".")
  }

  function dismissAttachmentRecovery() {
    attachmentRecoveryJobs = []
    attachmentRecoveryFiles = []
    attachmentRecoveryError = ""
  }

  function reset() {
    clearCurrentDraft(true)
    attachmentReadGrants = []
    for (var candidateIndex = 0; candidateIndex < parkedDrafts.length; candidateIndex++)
      forgetOwned(parkedDrafts[candidateIndex].draft ? parkedDrafts[candidateIndex].draft.draftAttachments : [])
    forgetOwned(interruptedDraft ? interruptedDraft.draftAttachments : [])
    for (var entryIndex = 0; entryIndex < recoveryDrafts.length; entryIndex++)
      forgetOwned(recoveryDrafts[entryIndex] ? recoveryDrafts[entryIndex].draftAttachments : [])
    parkedDrafts = []
    interruptedDraft = null
    recoveryDrafts = []
    restoreRevision = 0
    restoreFlashOpacity = 0
  }

  function selectPreferredFrom() {
    var choice = root.service ? root.service.preferredSendAs(replyRecipients) : null
    fromEmail = choice ? String(choice.email || "") : ""
  }

  function chooseFrom(identity) {
    var row = identity && typeof identity === "object" ? identity : ({ email: identity })
    fromEmail = String(row.email || "")
    fromWasChosen = true
    noteUserModified()
    fromMenu.close()
    var accountId = String(row.accountId || "")
    if (accountId === "" || !root.service) return
    root.accountId = accountId
    if (String(root.service.activeAccountId || "") === accountId) return
    if (typeof root.service.switchTo === "function") root.service.switchTo(accountId)
  }

  // Invariant: outside-press closes the popup before the trigger’s click; remember closure time to
  // avoid reopening it on the same press.
  property double fromMenuClosedAt: 0

  function reopeningAfterOutsidePress(closedAt) {
    return Date.now() - closedAt < 250
  }

  function toggleFromMenu() {
    if (fromMenu.opened) {
      fromMenu.close()
      return
    }
    if (reopeningAfterOutsidePress(fromMenuClosedAt)) return
    fromMenu.open()
  }

  function placeFromMenu() {
    if (!fromMenu.visible) return
    var global = fromButton.mapToGlobal(0, 0)
    var at = root.mapFromGlobal(global.x, global.y)
    var tall = fromMenu.height > 0 ? fromMenu.height : fromMenu.implicitHeight
    var menuX = Math.max(0, Math.min(at.x, root.width - fromMenu.width))
    var menuY = at.y + fromButton.height
    if (menuY + tall > root.height) menuY = at.y - tall
    if (menuY + tall > root.height) menuY = root.height - tall
    if (menuY < 0) menuY = 0
    fromMenu.x = menuX
    fromMenu.y = menuY
  }

  function ownReplyAddresses() {
    if (!root.service) return []
    var own = [{email: root.service.accountEmailFor(root.accountId)}]
    var sources = Senders.asList(root.service.senderSources)
    for (var entryIndex = 0; entryIndex < sources.length; entryIndex++) {
      if (String(sources[entryIndex].id || "") !== root.accountId) continue
      own.push({email: sources[entryIndex].email})
      own = own.concat(Senders.asList(sources[entryIndex].aliases))
    }
    var identities = Senders.asList(root.service.sendIdentities)
    for (var identityIndex = 0; identityIndex < identities.length; identityIndex++) {
      if (String(identities[identityIndex].accountId || "") === root.accountId)
        own.push(identities[identityIndex])
    }
    return own
  }

  function updateRecipientSuggestions() {
    toSuggestions = toField.activeFocus
      ? Recipients.suggestIndexed(contactIndex, toField.text, 5) : []
    ccSuggestions = ccField.activeFocus
      ? Recipients.suggestIndexed(contactIndex, ccField.text, 5) : []
    bccSuggestions = bccField.activeFocus
      ? Recipients.suggestIndexed(contactIndex, bccField.text, 5) : []
  }
  readonly property var contactIndex: Recipients.index(contactBook)

  function acceptTo(contact) {
    toField.text = Recipients.accept(toField.text, contact)
    noteUserModified()
    toSuggestions = []
    toField.forceActiveFocus()
  }

  function acceptCc(contact) {
    ccField.text = Recipients.accept(ccField.text, contact)
    noteUserModified()
    ccSuggestions = []
    ccField.forceActiveFocus()
  }

  function acceptBcc(contact) {
    bccField.text = Recipients.accept(bccField.text, contact)
    noteUserModified()
    bccSuggestions = []
    bccField.forceActiveFocus()
  }

  function focusAfterTo() {
    if (root.ccVisible) ccField.forceActiveFocus()
    else if (root.bccVisible) bccField.forceActiveFocus()
    else subjectField.forceActiveFocus()
  }

  function focusAfterCc() {
    if (root.bccVisible) bccField.forceActiveFocus()
    else subjectField.forceActiveFocus()
  }

  function loadForwardAttachments() {
    loadOriginalAttachments()
  }

  function loadDraftAttachments(messageId, attachments) {
    attachmentSourceMessageId = String(messageId || sourceDraftId || "")
    originalAttachments = Array.isArray(attachments) ? attachments.slice() : []
    loadOriginalAttachments()
  }

  function loadOriginalAttachments() {
    if (!service || originalAttachments.length === 0) return
    if (attachmentSourceMessageId === "") {
      forwardAttachmentsLoading = false
      forwardAttachmentError = "The original message is unavailable. Reopen it to include its attachments."
      return
    }
    var load = {owner: draftKey, accountId: accountId, serial: ++forwardLoadSerial,
      mode: mode, messageId: attachmentSourceMessageId}
    pendingProviderLoads = pendingProviderLoads.concat([load])
    forwardAttachmentsLoading = true
    forwardAttachmentError = ""
    if (mode === "forward") forwardedAttachments = []
    service.loadAttachments(load.messageId, originalAttachments.slice(), function(loaded, error) {
      root.pendingProviderLoads = root.pendingProviderLoads.filter(function(candidate) { return candidate !== load })
      var target = root.attachmentDraft(load.owner, load.accountId)
      if (!target || target.forwardLoadSerial !== load.serial || target.mode !== load.mode) return
      target.forwardAttachmentsLoading = false
      target.forwardAttachmentError = String(error || "")
      if (load.mode === "forward") target.forwardedAttachments = error ? [] : loaded
      else if (!error) target.draftAttachments = (target.draftAttachments || []).concat(Array.isArray(loaded) ? loaded : [])
      if (target !== root) root.draftChanged()
    }, load.owner, load.accountId)
  }

  function begin(nextMode, summary, bodyText, attachments) {
    clearCurrentDraft(true)
    agentParentJobId = ""
    replyMessageId = summary && (nextMode === "reply" || nextMode === "replyAll") ? String(summary.id || "") : ""
    mode = String(nextMode || "new")
    // Invariant: replies use the message’s owning mailbox even when another mailbox is active.
    accountId = root.service ? String(root.service.composeAccountId || "") : ""
    opened = true

    if (summary && mode !== "new") {
      threadId = summary.threadId
      inReplyTo = summary.messageId
      // Invariant: Cc may name the addressed send-as alias, so both recipient fields determine the
      // default sender.
      if (mode === "reply" || mode === "replyAll") {
        replyRecipients = (Array.isArray(summary.to) ? summary.to : [])
          .concat(Array.isArray(summary.cc) ? summary.cc : [])
      }

      if (mode === "forward") {
        subjectField.text = "Fwd: " + summary.subject
        attachmentSourceMessageId = String(summary.id || "")
        originalAttachments = Array.isArray(attachments) ? attachments.slice() : []
        if (originalAttachments.length > 0) loadForwardAttachments()
      } else {
        var recipients = Recipients.replyFields(summary, mode, ownReplyAddresses())
        toField.text = recipients.to
        ccField.text = recipients.cc
        ccVisible = ccField.text !== ""
        if (recipients.outgoing) replyRecipients = [summary.from]
        subjectField.text = String(summary.subject || "")
      }
      pendingQuoteSummary = summary
      pendingQuoteText = String(bodyText || "")
    }

    bodyPrefix = ""
    bodyQuote = ""
    placeBody()

    selectPreferredFrom()
    if (root.service) root.service.refreshRecipientContacts()
    userModified = false

    // Invariant: the window’s keyboard context owns focus placement; begin must not compete with
    // it.
  }

  function beginDraft(draft, messageId, attachments) {
    begin("new", null, "", [])
    var values = draft || ({})
    mode = String(values.mode || "new") === "draft" ? "draft" : "new"
    sourceDraftId = String(messageId || values.sourceDraftId || "")
    threadId = String(values.threadId || "")
    inReplyTo = String(values.inReplyTo || "")
    toField.text = String(values.to || "")
    ccField.text = String(values.cc || "")
    ccVisible = ccField.text !== ""
    bccField.text = String(values.bcc || "")
    bccVisible = bccField.text !== ""
    replyToField.text = String(values.replyTo || "")
    replyToVisible = replyToField.text !== ""
    subjectField.text = String(values.subject || "")
    if (mode === "draft") {
      // Invariant: a restored draft is authored text, including its existing signature.
      root.setBodyText(String(values.body || ""))
      placedBody = ""
      bodyWasEdited = true
      bodyPrefix = ""
      bodyQuote = ""
    } else {
      bodyPrefix = String(values.body || "")
      bodyQuote = ""
      placeBody()
    }
    var chosenFrom = String(values.from || "")
    if (chosenFrom !== "") {
      fromEmail = chosenFrom
      fromWasChosen = true
    }
    if (mode === "draft") loadDraftAttachments(messageId, attachments)
    userModified = false
  }

  function takeFocus() {
    if (mode === "reply" || mode === "replyAll") {
      bodyEdit.forceActiveFocus()
      bodyEdit.cursorPosition = 0
    } else if (toField.text === "") {
      toField.forceActiveFocus()
    } else if (subjectField.text === "") {
      subjectField.forceActiveFocus()
    } else {
      bodyEdit.forceActiveFocus()
    }
  }

  property string contentDirection: Direction.MODE_DEFAULT
  readonly property string writingDirection: Direction.forced(root.contentDirection)
  readonly property var composeAlignment: Direction.hasAnswer(root.writingDirection)
    ? (Direction.isRightToLeft(root.writingDirection) ? Text.AlignRight : Text.AlignLeft)
    : undefined

  signal closed()
  signal closeRequested()
  signal sendQueued()
  signal draftChanged()

  function finish() {
    clearCurrentDraft(true)
    if (interruptedDraft) {
      var held = interruptedDraft
      interruptedDraft = null
      restoreDraft(held)
      return
    }
    if (recoveryDrafts.length > 0) {
      var queued = recoveryDrafts.slice()
      var recovered = queued.shift()
      recoveryDrafts = queued
      restoreDraft(recovered)
      restoreRevision++
      restoreFlash.restart()
      return
    }
    opened = false
    closed()
  }

  function hasMeaningfulDraft() {
    if (String(toField.text || "").trim() !== "") return true
    if (String(ccField.text || "").trim() !== "") return true
    if (String(bccField.text || "").trim() !== "") return true
    if (String(subjectField.text || "").trim() !== "") return true
    if ((bodyWasEdited || String(bodyEdit.text || "") !== placedBody)
      && String(bodyEdit.text || "").trim() !== "") return true
    return allOutgoingAttachments().length > 0 || draftAttachmentsPending(snapshotDraft())
  }

  function fieldsForDraft(saved) {
    var draft = saved || ({})
    var attachments = []
    var forwarded = draft.mode === "forward" && Array.isArray(draft.forwardedAttachments)
      ? draft.forwardedAttachments : []
    var owned = Array.isArray(draft.draftAttachments) ? draft.draftAttachments : []
    var entryIndex
    for (entryIndex = 0; entryIndex < forwarded.length; entryIndex++) attachments.push(forwarded[entryIndex])
    for (entryIndex = 0; entryIndex < owned.length; entryIndex++) attachments.push(owned[entryIndex])
    return ({
      accountId: String(draft.accountId || ""),
      draftKey: String(draft.draftKey || ""),
      draftId: String(draft.sourceDraftId || ""),
      from: String(draft.fromEmail || ""),
      to: String(draft.to || ""),
      cc: String(draft.cc || ""),
      bcc: String(draft.bcc || ""),
      replyTo: String(draft.replyTo || ""),
      subject: String(draft.subject || ""),
      body: String(draft.body || ""),
      attachments: attachments,
      threadId: draft.mode === "forward" ? "" : String(draft.threadId || ""),
      inReplyTo: draft.mode === "forward" ? "" : String(draft.inReplyTo || "")
    })
  }

  function detachForSave() {
    var saved = snapshotDraft()
    clearCurrentDraft(false)
    if (interruptedDraft) {
      var held = interruptedDraft
      interruptedDraft = null
      restoreDraft(held)
    } else {
      opened = false
      closed()
    }
    return saved
  }

  function completeDetachedSave(saved) {
    forgetOwned(saved && saved.draftAttachments ? saved.draftAttachments : [])
  }

  function recoverDetachedSave(saved) {
    if (!saved) return
    if (!opened) {
      restoreDraft(saved)
      restoreRevision++
      restoreFlash.restart()
      return
    }
    var queued = recoveryDrafts.slice()
    queued.push(saved)
    recoveryDrafts = queued
  }

  function parkForSend(sendId) {
    parkDraftForSend(sendId, snapshotDraft())
    clearCurrentDraft(false)
    opened = false
    if (interruptedDraft) {
      var held = interruptedDraft
      interruptedDraft = null
      restoreDraft(held)
    } else {
      sendQueued()
    }
  }

  function parkDraftForSend(sendId, draft) {
    var parked = parkedDrafts.slice()
    // Invariant: the outbox send ID identifies one recovery draft even when its proposal appears in
    // two views.
    if (parked.some(function(entry) { return entry.sendId === String(sendId) })) return
    parked.push({ sendId: String(sendId || ""), draft: draft })
    parkedDrafts = parked
    draftChanged()
  }

  // Invariant: an unknown named send must not restore another parked draft; unnamed legacy answers
  // follow dispatch order.
  function takeParked(sendId, oldest) {
    if (parkedDrafts.length === 0) return null
    var parked = parkedDrafts.slice()
    var index = -1
    var id = String(sendId || "")
    if (id !== "") {
      for (var entryIndex = 0; entryIndex < parked.length; entryIndex++) {
        if (parked[entryIndex].sendId === id) {
          index = entryIndex
          break
        }
      }
      if (index < 0) return null
    } else {
      index = oldest ? 0 : parked.length - 1
    }
    var entry = parked.splice(index, 1)[0]
    parkedDrafts = parked
    return entry.draft
  }

  function resumePendingSend(sendId, oldest) {
    var draft = takeParked(sendId, oldest === true)
    if (!draft) return false
    if (opened) {
      var displaced = snapshotDraft()
      if (interruptedDraft) {
        var queued = recoveryDrafts.slice()
        queued.push(displaced)
        recoveryDrafts = queued
      } else {
        interruptedDraft = displaced
      }
    }
    clearCurrentDraft(false)
    restoreDraft(draft)
    restoreRevision++
    restoreFlash.restart()
    return true
  }

  function interruptedFields() {
    var saved = interruptedDraft
    if (!saved || draftAttachmentsPending(saved)) return null
    return fieldsForDraft(saved)
  }

  function completeInterruptedSave(expected) {
    if (!interruptedDraft || interruptedDraft !== expected) return false
    forgetOwned(interruptedDraft.draftAttachments)
    interruptedDraft = null
    return true
  }

  function completePendingSend(sendId) {
    var draft = takeParked(sendId, true)
    if (!draft) return false
    forgetOwned(draft.draftAttachments)
    return true
  }

  function cancelOrFinish() {
    closeRequested()
  }

  function submit() {
    // Invariant: the shared compose keyboard context also covers calendar forms; a hidden mail
    // composer must not dispatch.
    if (!opened || !service) return
    if (!attachmentsReady) return
    var accepted = service.send(({
      // Invariant: account ownership cannot be inferred from a send-as alias shared by multiple
      // mailboxes.
      accountId: root.accountId,
      draftKey: root.draftKey,
      from: root.fromEmail,
      to: toField.text,
      cc: ccField.text,
      bcc: bccField.text,
      replyTo: replyToField.text,
      subject: subjectField.text,
      body: bodyEdit.text,
      attachments: root.allOutgoingAttachments(),
      // Invariant: sending an existing provider draft must identify the draft it replaces.
      draftId: root.sourceDraftId,
      // Invariant: forwarding starts a new conversation; replying preserves its thread.
      threadId: root.mode === "forward" ? "" : root.threadId,
      inReplyTo: root.mode === "forward" ? "" : root.inReplyTo
    }))
    if (accepted) parkForSend(accepted === true ? "" : String(accepted))
  }

  function allOutgoingAttachments() {
    var out = []
    var forwarded = root.mode === "forward" ? root.forwardedAttachments : []
    var entryIndex
    for (entryIndex = 0; entryIndex < forwarded.length; entryIndex++) out.push(forwarded[entryIndex])
    for (entryIndex = 0; entryIndex < root.draftAttachments.length; entryIndex++) out.push(root.draftAttachments[entryIndex])
    return out
  }

  function chooseFiles() {
    enqueueAttach("pick")
  }

  function paste() {
    if (root.pasteInFlight) return
    root.pasteInFlight = true
    enqueueAttach("clipboard", "", focusedPasteTarget())
  }

  function pasteKey(event) {
    if (!event) return
    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_V) {
      event.accepted = true
      root.paste()
    }
  }

  function focusedPasteTarget() {
    var fields = [toField, ccField, bccField, replyToField, subjectField]
    for (var fieldIndex = 0; fieldIndex < fields.length; fieldIndex++)
      if (fields[fieldIndex].activeFocus) return fields[fieldIndex]
    return bodyEdit
  }

  function enqueueAttach(mode, path, pasteTarget) {
    var jobs = root.attachJobs.slice()
    jobs.push({ mode: String(mode || "read"), path: String(path || ""), pasteTarget: pasteTarget,
      owner: root.draftKey, accountId: root.accountId })
    root.attachJobs = jobs
    pumpAttach()
  }

  function pumpAttach() {
    if (root.attachmentHostPending || root.attachmentReadPending || root.attachJobs.length === 0) return
    var job = root.attachJobs[0]
    var owner = String(job.owner || root.draftKey)
    var ownerAccount = String(job.accountId || root.accountId)
    job.owner = owner
    job.accountId = ownerAccount
    var rest = root.attachJobs.slice(1)
    root.attachJobs = rest
    if (job.mode !== "forget" && !attachmentDraft(owner, ownerAccount)) { pumpAttach(); return }
    if (["read", "recover", "recover-owned"].indexOf(job.mode) >= 0 && !hasAttachmentReadGrant(job)) {
      holdAttachmentRecovery(job)
      root.attaching = root.attachJobs.length > 0
      pumpAttach()
      return
    }
    root.activeAttachJob = job
    root.attaching = true
    if (job.mode === "read" || job.mode === "recover" || job.mode === "recover-owned"
        || job.mode === "forget") {
      if (!root.service || !root.service.backend || !root.service.backend.ready) {
        finishAttach(job.mode, JSON.stringify({ ok: false, error: "Mail backend unavailable" }), owner, undefined, ownerAccount)
        return
      }
      root.attachmentReadPending = true
      var mailbox = typeof root.service.findAccount === "function" ? root.service.findAccount(ownerAccount) : null
      var stored = job.mode !== "forget" && Number(root.service.backend.apiVersion) >= 8 && (!mailbox || mailbox.providerId !== "hey")
      var method = job.mode === "forget" ? "attachment.forget" : stored ? "attachment.import" : "attachment.read"
      var parameters = {path:job.path}
      if (stored) { parameters.accountId = ownerAccount; parameters.draftKey = owner }
      root.service.backend.call(method, parameters, function(result, error) {
        root.attachmentReadPending = false
        var code = error ? String(error.message || "") : ""
        finishAttach(job.mode, JSON.stringify(error ? { ok: false,
          error: code === "attachment_too_large" ? "That file is larger than the 20 MB send limit"
            : "That file could not be read" } : result), owner, undefined, ownerAccount)
      })
      return
    }
    if (!root.service) {
      finishAttach(job.mode, JSON.stringify({ ok: false, error: "Attachment service unavailable" }), owner, undefined, ownerAccount)
      return
    }
    root.attachmentHostPending = true
    if (job.mode === "clipboard" && typeof root.service.clipboardAttachment === "function") {
      root.service.clipboardAttachment(root.composeDir, function(result) {
        root.attachmentHostPending = false
        root.finishAttach(job.mode, JSON.stringify(result || {ok:false,error:"no-image"}), owner, job.pasteTarget, ownerAccount)
      })
    } else if (job.mode === "pick" && typeof root.service.chooseFiles === "function") {
      root.service.chooseFiles(function(result) {
        root.attachmentHostPending = false
        root.finishAttach(job.mode, JSON.stringify(result || {ok:false,error:"cancelled"}), owner, undefined, ownerAccount)
      })
    } else {
      root.attachmentHostPending = false
      finishAttach(job.mode, JSON.stringify({ ok: false, error: "Unknown attachment action" }), owner, undefined, ownerAccount)
    }
  }

  property bool attachmentReadPending: false

  function finishAttach(mode, text, owner, pasteTarget, ownerAccount) {
    var result = null
    try { result = JSON.parse(String(text || "")) }
    catch (parseError) { result = null }

    // Invariant: completion belongs to its exact draft/mailbox, including an interrupted draft.
    var target = owner === undefined ? root : attachmentDraft(owner, ownerAccount)
    var completedJob = activeAttachJob && activeAttachJob.owner === owner
      && (ownerAccount === undefined || activeAttachJob.accountId === ownerAccount) ? activeAttachJob : null
    if (completedJob) activeAttachJob = null
    if (target && target !== root) target.pendingAttachment = null
    if (mode !== "forget" && !target) {
      if (mode === "clipboard" && result && result.ok === true && result.path)
        root.forgetOwned([{owned:true,path:result.path}])
      root.attaching = root.attachJobs.length > 0
      pumpAttach()
      return
    }

    if (mode === "clipboard" && target === root) root.pasteInFlight = false

    if (mode === "forget") {
      root.attaching = root.attachJobs.length > 0
      pumpAttach()
      return
    }

    if (mode === "pick" || (mode === "clipboard" && result && result.ok === true
        && Array.isArray(result.paths))) {
      root.attaching = root.attachJobs.length > 0
      if (result && result.ok === true && Array.isArray(result.paths))
        queueSelectedAttachments(target, result.paths, owner, ownerAccount)
      pumpAttach()
      return
    }

    if (mode === "clipboard" && result && result.ok !== true
        && String(result.error || "") === "no-image") {
      root.attaching = root.attachJobs.length > 0
      if (target === root && pasteTarget) pasteTarget.paste()
      pumpAttach()
      return
    }

    if (!result || result.ok !== true) {
      root.attaching = root.attachJobs.length > 0
      var attachmentError = result && result.error ? String(result.error) : "That file could not be attached"
      if (target !== root) target.attachmentRecoveryError = attachmentError
      else if (service && typeof service.fail === "function") service.fail(attachmentError)
      pumpAttach()
      return
    }

    var entry = ({
      filename: String(result.filename || "attachment"),
      mimeType: String(result.mimeType || "application/octet-stream"),
      size: Math.max(0, Math.floor(Number(result.size) || 0)),
      data: String(result.data || ""),
      handle: String(result.handle || ""),
      path: String(result.path || ""),
      owned: mode === "clipboard" || mode === "recover-owned"
    })
    var selectedPath = completedJob ? String(completedJob.path || "") : entry.path
    var next = (target.draftAttachments || []).filter(function(file) {
      return String(file.path || "") !== selectedPath || String(file.data || "") !== ""
        || String(file.handle || "") !== ""
    })
    next.push(entry)
    target.draftAttachments = next
    var unrecovered = (target === root ? attachmentRecoveryJobs : target.attachJobs || []).filter(function(job) {
      return String(job.path || "") !== selectedPath
    })
    if (target === root) {
      attachmentRecoveryJobs = unrecovered
      attachmentRecoveryFiles = attachmentRecoveryFiles.filter(function(file) {
        return String(file.path || "") !== selectedPath
      })
      updateAttachmentRecoveryMessage()
    } else {
      target.attachJobs = unrecovered
      if (unrecovered.length === 0) target.attachmentRecoveryError = ""
    }
    if (mode === "clipboard" && entry.path !== "")
      attachmentReadGrants = attachmentReadGrants.concat([{owner:owner,accountId:ownerAccount,path:entry.path}])
    if (mode === "read" || mode === "clipboard") {
      if (target === root) noteUserModified()
      else target.userModified = true
    }
    if (target !== root) root.draftChanged()
    root.attaching = root.attachJobs.length > 0
    pumpAttach()
  }

  // Invariant: only a live file selection grants path reads; persisted draft metadata never recreates a grant.
  function queueSelectedAttachments(target, paths, owner, ownerAccount) {
    var jobs = []
    for (var pathIndex = 0; pathIndex < paths.length; pathIndex++) {
      var path = String(paths[pathIndex] || "")
      if (path === "") continue
      attachmentReadGrants = attachmentReadGrants.concat([{owner:owner,accountId:ownerAccount,path:path}])
      jobs.push({mode:"read",path:path,owner:owner,accountId:ownerAccount})
    }
    target.attachJobs = (target.attachJobs || []).concat(jobs)
    if (target !== root) root.draftChanged()
    pumpAttach()
  }

  function removeAttachment(at) {
    var list = root.draftAttachments.slice()
    if (at < 0 || at >= list.length) return
    var entry = list[at]
    list.splice(at, 1)
    root.draftAttachments = list
    noteUserModified()
    if (entry && entry.owned && entry.path)
      enqueueAttach("forget", entry.path)
  }

  function attachDroppedUrls(urls) {
    var list = urls || []
    for (var entryIndex = 0; entryIndex < list.length; entryIndex++) {
      var url = String(list[entryIndex] || "")
      var path = url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
      if (path !== "") queueSelectedAttachments(root, [path], draftKey, accountId)
    }
  }

  anchors.fill: parent
  keys: ["text/uri-list"]
  onDropped: function(drop) {
    if (!drop.hasUrls) return
    drop.acceptProposedAction()
    root.attachDroppedUrls(drop.urls)
  }

  onFromAliasesChanged: {
    if (opened && !fromWasChosen) selectPreferredFrom()
  }
  onContactBookChanged: updateRecipientSuggestions()

  SequentialAnimation {
    id: restoreFlash
    running: false
    NumberAnimation {
      target: root
      property: "restoreFlashOpacity"
      from: 0.32
      to: 0
      duration: 720
      easing.type: Easing.OutCubic
    }
  }

  Item {
    id: head
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: MailStyle.space(44)

    BackBar {
      id: backBar
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(14)
      anchors.verticalCenter: parent.verticalCenter
      textColor: root.textColor
      dimColor: root.dimColor
      panelFontFamily: root.panelFontFamily
      onActivated: root.cancelOrFinish()
    }

    Row {
      id: titleRow
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(10)

      Widgets.PanelSectionHeader {
        anchors.verticalCenter: parent.verticalCenter
        text: root.title
        foreground: root.textColor
        fontFamily: root.panelFontFamily
      }
    }

    PanelSeparator {
      anchors.bottom: parent.bottom
      width: parent.width
      foreground: root.textColor
    }
  }


  Column {
    id: fields
    objectName: "compose-fields"
    anchors.top: head.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    // Invariant: recipient suggestions must cross the body’s sibling boundary, so their containing
    // column needs the higher z.
    z: 10

    Item {
      width: parent.width
      implicitHeight: fromButton.implicitHeight + MailStyle.space(14)

      Text {
        id: fromLabel
        anchors.left: parent.left
        anchors.leftMargin: root.formInset
        anchors.verticalCenter: parent.verticalCenter
        width: root.formLabelWidth
        horizontalAlignment: Text.AlignRight
        text: "From"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }

      Widgets.Button {
        id: fromButton
        objectName: "compose-from-button"
        readonly property real trailing: root.canChooseFrom
          ? Style.font.iconSmall + Style.spacing.controlGap : 0

        anchors.left: fromLabel.right
        anchors.leftMargin: root.formLabelGap
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth + trailing,
          parent.width - fromLabel.width - MailStyle.space(46))
        text: root.fromEmail
        foreground: root.textColor
        accent: root.accentColor
        background: Style.normalFillFor(root.textColor, root.accentColor)
        bordered: true
        fontFamily: root.panelFontFamily
        fontSize: MailStyle.bodySmall
        verticalPadding: Style.spacing.inputPaddingY
        leftAlign: true
        selected: fromMenu.opened
        enabled: root.canChooseFrom
        onClicked: root.toggleFromMenu()

        ActionIcon {
          anchors.right: parent.right
          anchors.rightMargin: fromButton.horizontalPadding
          anchors.verticalCenter: parent.verticalCenter
          visible: root.canChooseFrom
          enabled: false
          name: "chevronDown"
          iconSize: Style.font.iconSmall
          color: root.dimColor
        }
      }

      PanelSeparator {
        anchors.bottom: parent.bottom
        width: parent.width
        foreground: root.textColor
      }
    }

    Item {
      width: parent.width
      z: root.toSuggestions.length > 0 ? 100 : 0
      // Invariant: derive row height from the scaled field to avoid applying font scale twice.
      implicitHeight: toField.implicitHeight + MailStyle.space(14)

      Text {
        id: toLabel
        anchors.left: parent.left
        anchors.leftMargin: root.formInset
        anchors.verticalCenter: parent.verticalCenter
        width: root.formLabelWidth
        horizontalAlignment: Text.AlignRight
        text: "To"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }

      Row {
        id: copyToggles
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(18)
        anchors.verticalCenter: parent.verticalCenter
        spacing: MailStyle.space(4)

        Widgets.Button {
          id: contactsButton
          objectName: "compose-contacts-button"
          text: "Contacts"
          foreground: contactsPicker.opened ? root.textColor : root.dimColor
          bordered: false
          fontSize: MailStyle.caption
          onClicked: {
            var global = contactsButton.mapToGlobal(0, contactsButton.height)
            contactsPicker.toggleAt(global.x, global.y)
          }
        }

        Widgets.Button {
          id: ccToggle
          objectName: "compose-cc-toggle"
          text: "Cc"
          foreground: root.ccVisible ? root.textColor : root.dimColor
          bordered: false
          fontSize: MailStyle.caption
          onClicked: { root.ccVisible = !root.ccVisible; root.noteUserModified() }
        }

        Widgets.Button {
          id: bccToggle
          objectName: "compose-bcc-toggle"
          text: "Bcc"
          foreground: root.bccVisible ? root.textColor : root.dimColor
          bordered: false
          fontSize: MailStyle.caption
          onClicked: { root.bccVisible = !root.bccVisible; root.noteUserModified() }
        }

        Widgets.Button {
          id: replyToToggle
          objectName: "compose-reply-to-toggle"
          text: "Reply-To"
          tooltipText: "Ask for answers at another address"
          foreground: root.replyToVisible ? root.textColor : root.dimColor
          bordered: false
          fontSize: MailStyle.caption
          onClicked: { root.replyToVisible = !root.replyToVisible; root.noteUserModified() }
        }
      }

      Widgets.TextField {
        id: toField
        objectName: "compose-to-field"
        Accessible.name: "To"
        TextMenuTrigger {}
        onTextEdited: root.noteUserModified()
        anchors.left: toLabel.right
        anchors.leftMargin: root.formLabelGap
        anchors.right: copyToggles.left
        anchors.rightMargin: MailStyle.space(8)
        anchors.verticalCenter: parent.verticalCenter
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "recipient@example.com"
        onTextChanged: {
          root.updateRecipientSuggestions()
          root.noteDraftChanged()
        }
        onActiveFocusChanged: root.updateRecipientSuggestions()
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          root.pasteKey(event)
          if (event.accepted) return
          if (root.toSuggestions.length === 0) return
          if (event.key === Qt.Key_Down) {
            toSuggestionsPopup.moveSelection(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            toSuggestionsPopup.moveSelection(-1)
            event.accepted = true
          }
        }
        onAccepted: {
          if (root.toSuggestions.length > 0) toSuggestionsPopup.acceptSelection()
          else root.focusAfterTo()
        }
      }

      RecipientSuggestions {
        id: toSuggestionsPopup
        objectName: "compose-to-suggestions"
        x: toField.x
        y: parent.height - MailStyle.space(2)
        width: toField.width
        z: 60
        contacts: root.toSuggestions
        textColor: root.textColor
        dimColor: root.dimColor
        accentColor: root.accentColor
        popupBackgroundColor: root.popupBackgroundColor
        popupBorderColor: root.popupBorderColor
        panelFontFamily: root.panelFontFamily
        onChosen: function(contact) { root.acceptTo(contact) }
      }

      PanelSeparator {
        anchors.bottom: parent.bottom
        width: parent.width
        foreground: root.textColor
      }
    }

    Item {
      visible: root.ccVisible
      width: parent.width
      z: root.ccSuggestions.length > 0 ? 100 : 0
      // Invariant: derive row height from the scaled field to avoid applying font scale twice.
      implicitHeight: ccField.implicitHeight + MailStyle.space(14)

      Text {
        id: ccLabel
        anchors.left: parent.left
        anchors.leftMargin: root.formInset
        anchors.verticalCenter: parent.verticalCenter
        width: root.formLabelWidth
        horizontalAlignment: Text.AlignRight
        text: "Cc"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }

      Widgets.TextField {
        id: ccField
        objectName: "compose-cc-field"
        Accessible.name: "Cc"
        TextMenuTrigger {}
        onTextEdited: root.noteUserModified()
        anchors.left: ccLabel.right
        anchors.leftMargin: root.formLabelGap
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(18)
        anchors.verticalCenter: parent.verticalCenter
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        onTextChanged: {
          root.updateRecipientSuggestions()
          root.noteDraftChanged()
        }
        onActiveFocusChanged: root.updateRecipientSuggestions()
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          root.pasteKey(event)
          if (event.accepted) return
          if (root.ccSuggestions.length === 0) return
          if (event.key === Qt.Key_Down) {
            ccSuggestionsPopup.moveSelection(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            ccSuggestionsPopup.moveSelection(-1)
            event.accepted = true
          }
        }
        onAccepted: {
          if (root.ccSuggestions.length > 0) ccSuggestionsPopup.acceptSelection()
          else root.focusAfterCc()
        }
      }

      RecipientSuggestions {
        id: ccSuggestionsPopup
        x: ccField.x
        y: parent.height - MailStyle.space(2)
        width: ccField.width
        z: 60
        contacts: root.ccSuggestions
        textColor: root.textColor
        dimColor: root.dimColor
        accentColor: root.accentColor
        popupBackgroundColor: root.popupBackgroundColor
        popupBorderColor: root.popupBorderColor
        panelFontFamily: root.panelFontFamily
        onChosen: function(contact) { root.acceptCc(contact) }
      }

      PanelSeparator {
        anchors.bottom: parent.bottom
        width: parent.width
        foreground: root.textColor
      }
    }

    Item {
      visible: root.bccVisible
      width: parent.width
      z: root.bccSuggestions.length > 0 ? 100 : 0
      implicitHeight: bccField.implicitHeight + MailStyle.space(14)

      Text {
        id: bccLabel
        anchors.left: parent.left
        anchors.leftMargin: root.formInset
        anchors.verticalCenter: parent.verticalCenter
        width: root.formLabelWidth
        horizontalAlignment: Text.AlignRight
        text: "Bcc"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }

      Widgets.TextField {
        id: bccField
        objectName: "compose-bcc-field"
        Accessible.name: "Bcc"
        TextMenuTrigger {}
        onTextEdited: root.noteUserModified()
        anchors.left: bccLabel.right
        anchors.leftMargin: root.formLabelGap
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(18)
        anchors.verticalCenter: parent.verticalCenter
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        onTextChanged: {
          root.updateRecipientSuggestions()
          root.noteDraftChanged()
        }
        onActiveFocusChanged: root.updateRecipientSuggestions()
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          root.pasteKey(event)
          if (event.accepted) return
          if (root.bccSuggestions.length === 0) return
          if (event.key === Qt.Key_Down) {
            bccSuggestionsPopup.moveSelection(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            bccSuggestionsPopup.moveSelection(-1)
            event.accepted = true
          }
        }
        onAccepted: {
          if (root.bccSuggestions.length > 0) bccSuggestionsPopup.acceptSelection()
          else subjectField.forceActiveFocus()
        }
      }

      RecipientSuggestions {
        id: bccSuggestionsPopup
        objectName: "compose-bcc-suggestions"
        x: bccField.x
        y: parent.height - MailStyle.space(2)
        width: bccField.width
        z: 60
        contacts: root.bccSuggestions
        textColor: root.textColor
        dimColor: root.dimColor
        accentColor: root.accentColor
        popupBackgroundColor: root.popupBackgroundColor
        popupBorderColor: root.popupBorderColor
        panelFontFamily: root.panelFontFamily
        onChosen: function(contact) { root.acceptBcc(contact) }
      }

      PanelSeparator {
        anchors.bottom: parent.bottom
        width: parent.width
        foreground: root.textColor
      }
    }

    Item {
      visible: root.replyToVisible
      width: parent.width
      implicitHeight: replyToField.implicitHeight + MailStyle.space(14)

      Text {
        id: replyToLabel
        anchors.left: parent.left
        anchors.leftMargin: root.formInset
        anchors.verticalCenter: parent.verticalCenter
        width: root.formLabelWidth
        horizontalAlignment: Text.AlignRight
        text: "Reply-To"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }

      Widgets.TextField {
        id: replyToField
        objectName: "compose-reply-to-field"
        Accessible.name: "Reply-To"
        TextMenuTrigger {}
        onTextEdited: root.noteUserModified()
        anchors.left: replyToLabel.right
        anchors.leftMargin: root.formLabelGap
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(18)
        anchors.verticalCenter: parent.verticalCenter
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        onTextChanged: root.noteDraftChanged()
      }

      PanelSeparator {
        anchors.bottom: parent.bottom
        width: parent.width
        foreground: root.textColor
      }
    }

    Item {
      width: parent.width
      // Invariant: derive row height from the scaled field to avoid applying font scale twice.
      implicitHeight: subjectField.implicitHeight + MailStyle.space(14)

      Text {
        id: subjectLabel
        anchors.left: parent.left
        anchors.leftMargin: root.formInset
        anchors.verticalCenter: parent.verticalCenter
        width: root.formLabelWidth
        horizontalAlignment: Text.AlignRight
        text: "Subject"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }

      Widgets.TextField {
        id: subjectField
        objectName: "compose-subject-field"
        Accessible.name: "Subject"
        TextMenuTrigger {}
        onTextEdited: root.noteUserModified()
        anchors.left: subjectLabel.right
        anchors.leftMargin: root.formLabelGap
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(18)
        anchors.verticalCenter: parent.verticalCenter
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "Subject"
        horizontalAlignment: root.composeAlignment
        KeyNavigation.tab: bodyEdit
        onTextChanged: root.noteDraftChanged()
        onAccepted: bodyEdit.forceActiveFocus()
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { root.pasteKey(event) }
      }

      PanelSeparator {
        anchors.bottom: parent.bottom
        width: parent.width
        foreground: root.textColor
      }
    }

    Column {
      objectName: "compose-attachment-recovery-notice"
      visible: root.attachmentRecoveryError !== ""
      width: parent.width
      leftPadding: root.formInset
      rightPadding: root.formInset
      spacing: MailStyle.space(6)

      Text {
        width: parent.width - parent.leftPadding - parent.rightPadding
        text: root.attachmentRecoveryError
        textFormat: Text.PlainText
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        wrapMode: Text.WordWrap
      }
      Flow {
        width: parent.width - parent.leftPadding - parent.rightPadding
        spacing: MailStyle.space(8)
        Widgets.Button {
          objectName: "compose-recovery-choose-files"
          text: "Choose files..."
          focusable: true
          foreground: root.textColor
          onClicked: root.chooseFiles()
        }
        Widgets.Button {
          objectName: "compose-recovery-dismiss"
          text: "Continue without missing files"
          focusable: true
          foreground: root.textColor
          onClicked: root.dismissAttachmentRecovery()
        }
      }
    }

    Item {
      visible: (root.mode === "forward" || root.mode === "draft") && root.originalAttachments.length > 0
      width: parent.width
      implicitHeight: attachmentSummary.implicitHeight + MailStyle.space(14)

      Text {
        id: attachmentLabel
        anchors.left: parent.left
        anchors.leftMargin: root.formInset
        anchors.top: parent.top
        anchors.topMargin: MailStyle.space(9)
        width: root.formLabelWidth
        horizontalAlignment: Text.AlignRight
        text: "Files"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }

      Column {
        id: attachmentSummary
        anchors.left: attachmentLabel.right
        anchors.leftMargin: root.formLabelGap
        anchors.right: retryAttachments.left
        anchors.rightMargin: MailStyle.space(8)
        anchors.top: parent.top
        anchors.topMargin: MailStyle.space(7)
        spacing: MailStyle.space(3)

        Text {
          width: parent.width
          text: root.forwardAttachmentsLoading
            ? "Loading original attachments..."
            : (root.forwardAttachmentError !== ""
              ? root.forwardAttachmentError
              : Mail.formatCount(root.mode === "forward" ? root.forwardedAttachments.length
                  : root.originalAttachments.length, "original attachment")
                + (root.mode === "forward" ? " will be forwarded" : " included"))
          textFormat: Text.PlainText
          color: root.forwardAttachmentError !== "" ? root.accentColor : root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: root.originalAttachments
          Text {
            required property var modelData
            width: attachmentSummary.width
            textFormat: Text.PlainText
            text: String(modelData.filename || "attachment") + "  "
              + Mail.formatSize(modelData.size)
            color: root.dimColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.caption
            elide: Text.ElideMiddle
          }
        }
      }

      Widgets.Button {
        id: retryAttachments
        visible: root.forwardAttachmentError !== ""
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(18)
        anchors.top: parent.top
        anchors.topMargin: MailStyle.space(6)
        text: "Retry"
        foreground: root.textColor
        bordered: false
        fontSize: MailStyle.caption
        focusable: true
        onClicked: root.loadOriginalAttachments()
      }

      PanelSeparator {
        anchors.bottom: parent.bottom
        width: parent.width
        foreground: root.textColor
      }
    }
  }

  Rectangle {
    objectName: "compose-fields-restore-flash"
    anchors.fill: fields
    z: 20
    enabled: false
    color: root.accentColor
    opacity: root.restoreFlashOpacity
  }

  QQC.Popup {
    id: fromMenu
    objectName: "compose-from-menu"
    width: Math.min(MailStyle.space(360), root.width - MailStyle.space(36))
    implicitHeight: Math.min(fromRows.implicitHeight + MailStyle.space(8), MailStyle.space(260))
    padding: MailStyle.space(4)
    modal: false
    focus: opened
    z: 50
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    onHeightChanged: root.placeFromMenu()
    onOpened: root.placeFromMenu()
    onClosed: root.fromMenuClosedAt = Date.now()
    background: Rectangle {
      radius: Style.cornerRadius
      color: Qt.rgba(root.popupBackgroundColor.r, root.popupBackgroundColor.g,
        root.popupBackgroundColor.b, 1)
      border.width: 1
      border.color: root.popupBorderColor
    }

    contentItem: ListView {
      id: fromRows

      WheelScroller { view: fromRows }
      implicitHeight: contentHeight
      clip: true
      model: root.fromIdentities

      delegate: Rectangle {
        id: fromRow
        required property var modelData

        width: fromMenu.width - fromMenu.leftPadding - fromMenu.rightPadding
        implicitHeight: MailStyle.space(42)
        radius: Style.cornerRadius
        color: root.fromEmail.toLowerCase() === String(modelData.email || "").toLowerCase()
          ? Style.selectedFillFor(root.textColor, root.accentColor)
          : (fromHover.hovered
            ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent")

        Column {
          anchors.left: parent.left
          anchors.leftMargin: MailStyle.space(9)
          anchors.right: parent.right
          anchors.rightMargin: MailStyle.space(9)
          anchors.verticalCenter: parent.verticalCenter
          spacing: MailStyle.space(1)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: String(fromRow.modelData.email || "")
            color: root.textColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.bodySmall
            font.bold: root.fromEmail.toLowerCase()
              === String(fromRow.modelData.email || "").toLowerCase()
            elide: Text.ElideMiddle
          }

          Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: Senders.subtitle(fromRow.modelData)
            color: root.dimColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.caption
            elide: Text.ElideRight
          }
        }

        HoverHandler { id: fromHover }
        TapHandler { onTapped: root.chooseFrom(fromRow.modelData) }
      }
    }
  }

  ContactsPicker {
    id: contactsPicker
    objectName: "compose-contacts-picker"
    contacts: root.contactBook
    textColor: root.textColor
    dimColor: root.dimColor
    accentColor: root.accentColor
    popupBackgroundColor: root.popupBackgroundColor
    popupBorderColor: root.popupBorderColor
    panelFontFamily: root.panelFontFamily
    onContactChosen: function(contact, target) {
      root.noteUserModified()
      if (target === "cc") {
        root.ccVisible = true
        ccField.text = Recipients.append(ccField.text, contact)
        ccField.forceActiveFocus()
      } else if (target === "bcc") {
        root.bccVisible = true
        bccField.text = Recipients.append(bccField.text, contact)
        bccField.forceActiveFocus()
      } else {
        toField.text = Recipients.append(toField.text, contact)
        toField.forceActiveFocus()
      }
    }
  }

  Flickable {
    id: bodyFlick

    WheelScroller { view: bodyFlick }
    objectName: "compose-body"
    anchors.top: fields.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: attachStrip.top
    anchors.leftMargin: MailStyle.space(18)
    anchors.rightMargin: MailStyle.space(18)
    anchors.topMargin: MailStyle.space(12)
    contentWidth: width
    contentHeight: bodyEdit.height
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    TextEdit {
      id: bodyEdit
      objectName: "compose-body-editor"
      Accessible.name: "Message body"
      TextMenuTrigger {}
      activeFocusOnTab: true
      width: bodyFlick.width
      // Invariant: the editor must fill the viewport so clicking below a short draft still places
      // the cursor.
      Binding on height {
        value: Math.max(bodyEdit.implicitHeight, bodyFlick.height)
        delayed: true
      }
      selectByMouse: true
      wrapMode: TextEdit.Wrap
      textFormat: TextEdit.PlainText
      horizontalAlignment: root.composeAlignment
      color: root.textColor
      selectionColor: Style.selectionFillFor(root.textColor, root.accentColor)
      selectedTextColor: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      onTextChanged: {
        root.noteDraftChanged()
        if (!root.settingBodyText && activeFocus) {
          root.bodyWasEdited = true
          root.noteUserModified()
        }
      }
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { root.pasteKey(event) }
    }
  }

  Rectangle {
    objectName: "compose-body-restore-flash"
    anchors.fill: bodyFlick
    z: bodyFlick.z + 1
    enabled: false
    color: root.accentColor
    opacity: root.restoreFlashOpacity
  }

  Item {
    id: attachStrip
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: actions.top
    height: root.draftAttachments.length > 0
      ? Math.min(attachFlick.contentHeight, MailStyle.space(240)) + MailStyle.space(12)
      : 0

    Flickable {
      id: attachFlick

      WheelScroller { view: attachFlick }
      anchors.fill: parent
      anchors.leftMargin: MailStyle.space(18)
      anchors.rightMargin: MailStyle.space(18)
      anchors.topMargin: MailStyle.space(4)
      visible: root.draftAttachments.length > 0
      clip: true
      contentWidth: width
      contentHeight: attachList.height
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: attachList
        width: attachFlick.width
        spacing: MailStyle.space(8)

        Repeater {
          model: root.draftAttachments

          Column {
            id: attachItem
            required property var modelData
            required property int index
            width: attachList.width
            spacing: MailStyle.space(4)

            Image {
              objectName: "compose-attachment-preview-" + attachItem.index
              visible: source.toString() !== ""
              width: parent.width
              height: visible
                ? Math.min(Math.max(sourceSize.height, MailStyle.space(72)), MailStyle.space(200))
                : 0
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              cache: false
              source: root.attachmentPreviews[attachItem.index] || ""
            }

            Row {
              spacing: MailStyle.space(6)
              width: parent.width

              ActionIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "attachment"
                iconSize: Style.font.iconSmall
                color: root.dimColor
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - MailStyle.space(120))
                textFormat: Text.PlainText
                text: String(attachItem.modelData.filename || "attachment")
                color: root.textColor
                font.family: root.panelFontFamily
                font.pixelSize: MailStyle.caption
                elide: Text.ElideMiddle
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Mail.formatSize(attachItem.modelData.size)
                color: root.dimmerColor
                font.family: root.panelFontFamily
                font.pixelSize: MailStyle.caption
              }

              IconButton {
                anchors.verticalCenter: parent.verticalCenter
                iconName: "close"
                tooltipText: "Remove"
                foreground: root.dimColor
                hoverColor: root.textColor
                fontFamily: root.panelFontFamily
                iconSize: Style.font.iconSmall
                onClicked: root.removeAttachment(attachItem.index)
              }
            }
          }
        }
      }
    }
  }


  Item {
    id: actions
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    height: MailStyle.space(52)

    PanelSeparator {
      anchors.top: parent.top
      width: parent.width
      foreground: root.textColor
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(18)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(10)

      IconTextButton {
        iconName: "send"
        objectName: "compose-send-button"
        tooltipText: "Send · ctrl+enter"
        // Invariant: a queued send does not lock the composer; each draft has its own recovery
        // state.
        text: "Send"
        foreground: root.textColor
        fontFamily: root.panelFontFamily
        enabled: !!root.service
          && root.attachmentsReady
        onClicked: root.submit()
      }

      IconTextButton {
        iconName: "attachment"
        tooltipText: "Attach files..."
        text: root.attaching ? "Attaching" : "Attach..."
        foreground: root.textColor
        fontFamily: root.panelFontFamily
        enabled: !!root.service && !root.attaching
        onClicked: root.chooseFiles()
      }

      Widgets.Button {
        objectName: "compose-discard-button"
        text: "Discard"
        foreground: root.dimColor
        bordered: false
        fontSize: MailStyle.bodySmall
        onClicked: root.finish()
      }
    }

  }

  // Invariant: context-menu Paste follows the image-aware clipboard path and focuses the clicked
  // field first.
  component TextMenuTrigger: MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.RightButton
    onPressed: function(mouse) {
      var scene = parent.mapToGlobal(mouse.x, mouse.y)
      textMenu.openAt(parent, scene.x, scene.y, "")
    }
  }

  TextMenu {
    id: textMenu
    objectName: "compose-text-menu"
    editable: true
    textColor: root.textColor
    popupBackgroundColor: root.popupBackgroundColor
    popupBorderColor: root.popupBorderColor
    panelFontFamily: root.panelFontFamily
    onCopyRequested: function(text) {
      if (root.service && typeof root.service.copyText === "function") root.service.copyText(text)
    }
    onPasteRequested: function(target) {
      if (target) target.forceActiveFocus()
      root.paste()
    }
  }
}

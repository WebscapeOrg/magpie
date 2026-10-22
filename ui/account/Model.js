.pragma library

.import "Conversation.js" as Conversation

function mailboxAfterAccountSwitch(currentKey, targetMailboxes) {
  var key = String(currentKey || "")
  var mailboxes = Array.isArray(targetMailboxes) ? targetMailboxes : []
  for (var mailboxIndex = 0; mailboxIndex < mailboxes.length; mailboxIndex++) {
    if (mailboxes[mailboxIndex] && String(mailboxes[mailboxIndex].key || "") === key) return key
  }
  return ""
}

function setupState(status) {
  var value = status || {}
  if (!value.toolsPresent) return "tools_missing"
  if (!value.credentialsPresent) return "no_credentials"
  if (value.signingIn) return "signing_in"
  if (value.recoveringSession) return "reconnecting"
  if (!value.signedIn) return "signed_out"
  return "ready"
}

// Invariant: Accounts saved before provider selection default to Gmail.
function providerName(provider) {
  var name = String(provider === undefined || provider === null ? "" : provider).trim()
  return name === "" ? "Gmail" : name
}

function setupHeadline(state, provider, authKind) {
  var name = providerName(provider)
  if (state === "unavailable") return name + " integration is coming later"

  if (state === "tools_missing")
    return authKind === "cli" ? "Install the HEY CLI" : "Missing system tools"

  if (state === "no_credentials") {
    if (authKind === "password") return "Add this mailbox"
    if (authKind === "cli") return "Sign in to " + name
    if (name === "Outlook") return "Add this Outlook mailbox"
    return "Connect a Google Cloud project"
  }
  if (state === "signing_in") {
    if (authKind === "password") return "Checking the mailbox…"
    if (authKind === "cli") return "Waiting for " + name + "…"
    if (name === "Outlook") return "Waiting for Microsoft…"
    return "Waiting for Google…"
  }
  if (state === "reconnecting") return "Reconnecting to " + name + "…"
  if (state === "signed_out") return "Sign in to " + name
  return ""
}

function setupDetail(state, missingTools, reason, provider, authKind) {
  var name = providerName(provider)
  if (state === "unavailable") return String(reason || "")
  if (state === "tools_missing") {
    var tools = Array.isArray(missingTools) ? missingTools.join(", ") : ""
    if (authKind === "cli")
      return "HEY does not speak IMAP or POP, so Omamail reads it through the "
        + "HEY CLI, the client 37signals publish for exactly this. Install it, "
        + "then come back — nothing else here needs setting up."
    return "Omamail needs " + (tools || "a few base tools")
      + " on PATH before it can sign in."
  }
  if (state === "no_credentials") {
    if (authKind === "password")
      return "Enter the server and the password for this mailbox. Most providers want an app password rather than the one you sign in to the website with."
    if (authKind === "cli")
      return "The HEY CLI is installed. Signing in opens HEY in your browser; the token it comes back with is the CLI's own, and Omamail never sees it."
    if (name === "Outlook")
      return "Add the mailbox and a Microsoft public-client ID. Sign-in happens on Microsoft's page; Omamail never sees the account password."
    return "Gmail has no shared app to sign in through, so this plugin uses an OAuth client you own. It takes about two minutes to create."
  }
  if (state === "signing_in") {
    if (authKind === "password") return "Trying the server with those details."
    return "Finish the sign-in in your browser. This window updates by itself."
  }
  if (state === "signed_out") {
    if (authKind === "password")
      return "This mailbox is set up. Enter its password to let it read your mail."
    if (authKind === "cli")
      return "The HEY CLI is installed but signed out. Sign in to let it read this mailbox."
    return "Your OAuth client is ready. Sign in to let it read this mailbox."
  }
  if (state === "reconnecting")
    return "The saved session is intact. Omamail will retry automatically when the network is available."
  return ""
}

function setupActionLabel(state, provider, authKind) {

  if (state === "unavailable") return ""
  // Invariant: CLI setup may check installation but must not run a downloaded installer.
  if (state === "tools_missing")
    return authKind === "cli" ? "Check again" : "See what is missing..."
  if (state === "no_credentials") {
    if (authKind === "password") return "Add the mailbox..."
    // Invariant: The HEY CLI owns the complete credential; no OAuth configuration is required here.
    if (authKind === "cli") return "Sign in to " + providerName(provider) + "..."
    return "Set up the OAuth client..."
  }
  if (state === "signing_in") return "Cancel"
  if (state === "reconnecting") return ""
  if (state === "signed_out") return "Sign in to " + providerName(provider) + "..."
  return ""
}

// Invariant: Star applies to one message; unstar applies to every counted member so the conversation star can clear.
var CONVERSATION_ACTIONS = [
  "archive", "unarchive", "trash", "untrash",
  "spam", "markRead", "markUnread", "unstar"
]

function actionScope(action) {
  return CONVERSATION_ACTIONS.indexOf(String(action || "")) >= 0
    ? "conversation" : "message"
}

// Invariant: Conversation actions use exactly the member IDs counted by the displayed row, without fetching a wider thread.
function actionTargets(row, action) {
  var id = row && row.id !== undefined && row.id !== null ? String(row.id) : ""
  var own = id === "" ? [] : [id]
  if (actionScope(action) !== "conversation") return own
  var block = Conversation.blockOf(row ? row.thread : null)
  if (!block || block.count === 0) return own
  return block.memberIds.slice()
}

function rowHoldsMember(row, id) {
  var wanted = String(id || "")
  if (wanted === "") return false
  if (row && String(row.id || "") === wanted) return true
  return Conversation.holdsMember(row ? row.thread : null, wanted)
}

// Invariant: Match a row's own ID before member IDs so another conversation cannot capture its representative.
function rowIndexForMember(messages, id) {
  var list = Array.isArray(messages) ? messages : []
  var wanted = String(id || "")
  if (wanted === "") return -1
  var own = indexById(list, wanted)
  if (own >= 0) return own
  for (var entryIndex = 0; entryIndex < list.length; entryIndex++) {
    if (Conversation.holdsMember(list[entryIndex] ? list[entryIndex].thread : null, wanted)) return entryIndex
  }
  return -1
}

// Invariant: Unknown members cannot clear existing conversation flags. Known members use their own labels, not flags aggregated from the conversation.
function threadAfterMemberChange(row, memberSummaries) {
  var block = Conversation.blockOf(row ? row.thread : null)
  if (!block) return null
  var store = memberSummaries && typeof memberSummaries === "object"
    ? memberSummaries : {}
  var unread = false
  var flagged = false
  var unknown = false
  for (var memberIndex = 0; memberIndex < block.memberIds.length; memberIndex++) {
    var summary = store[block.memberIds[memberIndex]]
    if (!summary || typeof summary !== "object") {
      unknown = true
      continue
    }
    if (Conversation.memberHasLabel(summary, "UNREAD")) unread = true
    if (Conversation.memberHasLabel(summary, "STARRED")) flagged = true
  }
  block.unread = unread || (unknown && block.unread)
  block.flagged = flagged || (unknown && block.flagged)
  return block
}

function threadAfterAction(row, action) {
  var block = Conversation.blockOf(row ? row.thread : null)
  if (!block) return null
  if (actionScope(action) !== "conversation") return block
  var verb = String(action || "")
  if (verb === "markRead") block.unread = false
  else if (verb === "markUnread") block.unread = true
  else if (verb === "unstar") block.flagged = false
  return block
}

// Invariant: Move destinations stay inside the action value so guards, optimistic edits, cache repair and rollback share one intent.
var MOVE_PREFIX = "label:"

// Invariant: Gmail system labels are mailbox state, not user filing destinations; label removal uses this same classification.
var SYSTEM_LABEL_IDS = ["INBOX", "UNREAD", "STARRED", "IMPORTANT", "SENT",
  "DRAFT", "TRASH", "SPAM", "CHAT"]

function isSystemLabelId(id) {
  var value = String(id || "")
  if (SYSTEM_LABEL_IDS.indexOf(value) >= 0) return true
  return value.indexOf("CATEGORY_") === 0
}

function labelTarget(action) {
  var verb = String(action || "")
  if (verb.indexOf(MOVE_PREFIX) !== 0) return ""
  return verb.slice(MOVE_PREFIX.length)
}

// Invariant: Conversation rows remain in Unread or Starred while their recomputed member flags still match that view.
function survivesAction(mailboxKey, action, rawQuery, labels, sourceLabelId, row) {
  var key = String(mailboxKey || "inbox")
  var verb = String(action || "")
  var block = Conversation.blockOf(row ? row.thread : null)
  if (block && block.count > 0) {
    if (verb === "markRead" && key === "unread") return block.unread
    if (verb === "unstar" && key === "starred") return block.flagged
  }
  if (verb === "trash") return key === "trash"
  if (verb === "untrash") return key !== "trash"
  if (verb === "unarchive") {
    // Invariant: A folder move changes the message UID, so the old row must leave even when its destination is Inbox.
    if (labels !== true) return false
    // Invariant: A label view retains the row only when the same labelChangesFor rule keeps its label attached.
    if (String(rawQuery || "") === "") return true
    var filed = String(sourceLabelId || "")
    // Invariant: An unnamed label view cannot prove membership; remove the row and let revalidation restore it if needed.
    if (filed === "") return false
    return labelChangesFor("unarchive", filed).remove.length === 0
  }

  if (labelTarget(verb) !== "" && String(rawQuery || "") !== "") return false
  if (verb === "archive" || labelTarget(verb) !== "")
    return key !== "inbox" && key !== "unread"
  if (verb === "markRead") return key !== "unread"
  if (verb === "unstar") return key !== "starred"
  return true
}

// Invariant: Coalescing cannot cross an opposite intent; read/unread/read must retain all three transitions.
function enqueueAction(requests, request) {
  var queued = requests.slice()
  for (var actionIndex = queued.length - 1; actionIndex >= 0; actionIndex--) {
    var previous = queued[actionIndex]
    if (previous.id !== request.id) continue
    if (previous.action === request.action && previous.cacheKey === request.cacheKey
        && previous.sourceLabelId === request.sourceLabelId
        && (previous.memberOnly === true) === (request.memberOnly === true)
        && (previous.quiet === true) === (request.quiet === true)) {
      // Invariant: Repeated intents retain the first dispatch and rollback; quiet and explicit actions remain distinct.
      queued[actionIndex] = {
        id: request.id, action: request.action, cacheKey: request.cacheKey,
        sourceLabelId: request.sourceLabelId,
        memberOnly: request.memberOnly === true,
        quiet: request.quiet === true,
        dispatch: previous.dispatch
      }
      return queued
    }
    break
  }
  queued.push(request)
  return queued
}

function holdsDispatch(requests, dispatch) {
  var queued = Array.isArray(requests) ? requests : []
  for (var actionIndex = 0; actionIndex < queued.length; actionIndex++) {
    if (queued[actionIndex] && queued[actionIndex].dispatch === dispatch) return true
  }
  return false
}

function labelChangesFor(action, sourceLabelId) {
  if (action === "markRead") return { add: [], remove: ["UNREAD"] }
  if (action === "markUnread") return { add: ["UNREAD"], remove: [] }
  if (action === "star") return { add: ["STARRED"], remove: [] }
  if (action === "unstar") return { add: [], remove: ["STARRED"] }
  if (action === "archive") return { add: [], remove: ["INBOX"] }
  // Invariant: Returning to Inbox removes a user filing label, while system labels remain; folder providers pass no sourceLabelId.
  if (action === "unarchive") {
    var filed = String(sourceLabelId || "")
    if (filed === "" || isSystemLabelId(filed)) return { add: ["INBOX"], remove: [] }
    return { add: ["INBOX"], remove: [filed] }
  }
  if (action === "spam") return { add: ["SPAM"], remove: ["INBOX"] }

  var target = labelTarget(action)
  if (target !== "") {
    var remove = ["INBOX"]
    var source = String(sourceLabelId || "")
    if (source !== "" && source !== target && remove.indexOf(source) < 0)
      remove.push(source)
    return { add: [target], remove: remove }
  }
  return null
}

// Invariant: A move cannot target the current folder or system mailboxes. Untyped destinations retain tree order; typed matches are flat.
function movableLabels(labels, query, currentLabelId) {
  var candidates = Array.isArray(labels) ? labels : []
  var typed = String(query || "").trim()
  var current = String(currentLabelId || "")
  var destinations = []
  if (typed === "") {
    var rows = labelTree(candidates, [])
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      if (!rows[rowIndex].selectable || rows[rowIndex].id === current) continue
      var at = indexById(candidates, rows[rowIndex].id)
      if (at < 0) continue
      var copy = {}
      for (var key in candidates[at]) copy[key] = candidates[at][key]
      copy.depth = rows[rowIndex].depth
      copy.leaf = rows[rowIndex].name
      destinations.push(copy)
    }
    return destinations
  }
  for (var candidateIndex = 0; candidateIndex < candidates.length; candidateIndex++) {
    var label = candidates[candidateIndex]
    if (!label || label.system === true) continue
    if (String(label.id || "") === current) continue
    var labelName = String(label.name || "")
    var score = fuzzyScore(typed, labelName)
    if (score <= 0) continue
    var kept = {}
    for (var field in label) kept[field] = label[field]
    kept.depth = 0
    kept.leaf = labelName
    kept.score = score
    kept.sourceIndex = candidateIndex
    destinations.push(kept)
  }
  // Invariant: Equal fuzzy scores prefer the shorter path so a parent ranks before matching descendants.
  destinations.sort(function(left, right) {
    return right.score - left.score || left.leaf.length - right.leaf.length || left.sourceIndex - right.sourceIndex
  })
  return destinations
}

// Invariant: Case-folded label ties use the ID to keep a deterministic order across refreshes.
function compareLabelNames(left, right) {
  var leftName = String(left && left.name || "").toLowerCase()
  var rightName = String(right && right.name || "").toLowerCase()
  if (leftName !== rightName) return leftName < rightName ? -1 : 1
  var leftId = String(left && left.id || "")
  var rightId = String(right && right.id || "")
  return leftId < rightId ? -1 : (leftId > rightId ? 1 : 0)
}

function railLabels(labels) {
  var all = Array.isArray(labels) ? labels : []
  var result = []
  for (var labelIndex = 0; labelIndex < all.length; labelIndex++) {
    if (!all[labelIndex] || all[labelIndex].system === true) continue
    result.push(all[labelIndex])
  }
  result.sort(compareLabelNames)
  return result
}

// Invariant: Keyboard actions require the same capability checks as visible buttons before optimistic state changes.
function actionCapability(action) {
  var verb = String(action || "")
  if (verb === "archive" || verb === "unarchive") return "archive"
  if (verb === "star" || verb === "unstar") return "star"
  if (verb === "spam") return "spam"
  if (labelTarget(verb) !== "") return "move"
  return ""
}

function actionUnavailable(action, provider) {
  var name = providerName(provider)
  var needs = actionCapability(action)
  if (needs === "archive") return name + " has no archive"
  if (needs === "star") return name + " has no star"
  if (needs === "spam") return name + " has no junk verb to report to"
  if (needs === "move") return name + " has no destination you can name"
  return ""
}

// Invariant: Keyboard hints must not offer actions the provider cannot perform.
function unavailableActions(capabilities) {
  var caps = capabilities || {}
  var result = []
  if (caps.archive !== true) result.push("archive")
  if (caps.star !== true) result.push("star")
  if (caps.move !== true) result.push("move")
  return result
}

// Invariant: Row unread/starred flags include every counted member; recomputing only from the representative would hide unread replies.
function rowWithThread(summary, thread) {
  if (!summary) return summary
  var next = {}
  for (var key in summary) next[key] = summary[key]
  if (thread) next.thread = thread
  var block = Conversation.blockOf(next.thread)
  var labels = Array.isArray(next.labelIds) ? next.labelIds : []
  next.unread = labels.indexOf("UNREAD") >= 0 || (!!block && block.unread)
  next.starred = labels.indexOf("STARRED") >= 0 || (!!block && block.flagged)
  return next
}

// Invariant: Replay reads current member summaries and the representative's edited labels; unknown members cannot clear conversation flags.
function rowAfterMemberEdit(row, ownLabels, rowId, memberSummaries, targets, after) {
  var nextMembers = {}
  for (var held in memberSummaries) nextMembers[held] = memberSummaries[held]
  var ids = Array.isArray(targets) ? targets : []
  for (var messageIndex = 0; messageIndex < ids.length; messageIndex++) {
    if (ids[messageIndex] !== rowId && memberSummaries[ids[messageIndex]]) nextMembers[ids[messageIndex]] = after(memberSummaries[ids[messageIndex]])
  }
  nextMembers[rowId] = ownLabels
  return rowWithThread(ownLabels, threadAfterMemberChange(row, nextMembers))
}

// Invariant: The supplied thread block expresses action scope: asserted for conversation edits, recomputed for member edits.
function applyLabelChange(summary, action, sourceLabelId, thread) {
  if (!summary) return summary
  var change = labelChangesFor(action, sourceLabelId)
  if (!change) return summary
  var labels = Array.isArray(summary.labelIds) ? summary.labelIds.slice() : []
  for (var removalIndex = 0; removalIndex < change.remove.length; removalIndex++) {
    var at = labels.indexOf(change.remove[removalIndex])
    if (at >= 0) labels.splice(at, 1)
  }
  for (var additionIndex = 0; additionIndex < change.add.length; additionIndex++) {
    if (labels.indexOf(change.add[additionIndex]) < 0) labels.push(change.add[additionIndex])
  }
  return rowWithThread(withLabels(summary, labels), thread)
}

// Invariant: Label edits must update every mirrored mailbox flag; unread and starred also depend on the conversation block.
function withLabels(summary, labels) {
  var next = {}
  for (var key in summary) next[key] = summary[key]
  next.labelIds = labels
  next.inInbox = labels.indexOf("INBOX") >= 0
  next.inTrash = labels.indexOf("TRASH") >= 0
  next.inSpam = labels.indexOf("SPAM") >= 0
  next.isSent = labels.indexOf("SENT") >= 0
  next.isDraft = labels.indexOf("DRAFT") >= 0
  return next
}

// Invariant: Reader zoom is independent of theme scaling and quantized so saved values survive repeated steps.
var ZOOM_MIN = 0.6
var ZOOM_MAX = 2.5
var ZOOM_STEPS_PER_UNIT = 20

function clampZoom(value) {
  if (value === null || value === undefined || value === "") return 1
  var zoom = Number(value)
  if (!isFinite(zoom)) return 1
  return Math.max(ZOOM_MIN, Math.min(ZOOM_MAX,
    Math.round(zoom * ZOOM_STEPS_PER_UNIT) / ZOOM_STEPS_PER_UNIT))
}

// Invariant: Invalid or nonpositive persisted pane widths use the default layout rather than collapsing a pane.
function paneWidth(value) {
  var widthPixels = Math.floor(Number(value))
  if (!isFinite(widthPixels) || widthPixels <= 0) return 0
  return Math.min(widthPixels, 4000)
}

function stringList(value) {
  var list = Array.isArray(value) ? value : []
  var result = []
  for (var entryIndex = 0; entryIndex < list.length; entryIndex++) {
    var item = String(list[entryIndex] === undefined || list[entryIndex] === null ? "" : list[entryIndex])
    if (item !== "" && result.indexOf(item) < 0) result.push(item)
  }
  return result
}

function windowPrefs(raw) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (error) { parsed = null }
  if (!parsed || typeof parsed !== "object") {
    return {
      sidebarCollapsed: false,
      sidebarWidth: 0,
      listWidth: 0,
      collapsedFolders: [],
      bodyZoom: 1,
      bodyMode: "reader",
      alwaysShowImages: false,
      windowOpen: false
    }
  }
  var bodyMode = String(parsed.bodyMode || "")
  if (bodyMode !== "reader" && bodyMode !== "original" && bodyMode !== "plain")
    bodyMode = parsed.plainTextForced === true ? "plain" : "reader"
  return {
    sidebarCollapsed: parsed.sidebarCollapsed === true,
    sidebarWidth: paneWidth(parsed.sidebarWidth),
    listWidth: paneWidth(parsed.listWidth),
    collapsedFolders: stringList(parsed.collapsedFolders),
    bodyZoom: clampZoom(parsed.bodyZoom),
    bodyMode: bodyMode,
    alwaysShowImages: parsed.alwaysShowImages === true,
    windowOpen: parsed.windowOpen === true
  }
}

function zoomAfterStep(zoom, step) {
  var by = Number(step)
  return clampZoom(clampZoom(zoom) + (isFinite(by) ? by : 0))
}

function showInitialListSkeleton(loading, messageCount) {
  return !!loading && Math.max(0, Number(messageCount) || 0) === 0
}

function showListFooter(messageCount) {
  return Math.max(0, Number(messageCount) || 0) > 0
}

// Invariant: Rehydrated summaries require value comparison. Exhausting the depth bound means changed, so uncertain equality never hides a mail update.
function sameSummaryValue(left, right, depth) {
  if (left === right) return true
  if (!left || !right) return false
  if (typeof left !== "object" || typeof right !== "object") return false
  // Invariant: Rehydrated Date objects compare by timestamp, not object identity.
  if (typeof left.getTime === "function" || typeof right.getTime === "function") {
    return typeof left.getTime === "function" && typeof right.getTime === "function"
      && left.getTime() === right.getTime()
  }
  if (depth <= 0) return false
  var leftIsList = Array.isArray(left)
  if (leftIsList !== Array.isArray(right)) return false
  if (leftIsList) {
    if (left.length !== right.length) return false
    for (var entryIndex = 0; entryIndex < left.length; entryIndex++) {
      if (!sameSummaryValue(left[entryIndex], right[entryIndex], depth - 1)) return false
    }
    return true
  }
  // Invariant: Cache serialization drops undefined fields; comparison must treat their absence symmetrically.
  for (var key in left) {
    if (!Object.prototype.hasOwnProperty.call(left, key)) continue
    if (!sameSummaryValue(left[key], right[key], depth - 1)) return false
  }
  for (var extra in right) {
    if (!Object.prototype.hasOwnProperty.call(right, extra)) continue
    if (Object.prototype.hasOwnProperty.call(left, extra)) continue
    if (right[extra] !== undefined) return false
  }
  return true
}

// Performance: Unchanged hydrated rows retain the existing list to avoid recomputing every QML consumer.
function sameSummaries(previous, next) {
  var before = Array.isArray(previous) ? previous : []
  var after = Array.isArray(next) ? next : []
  if (before === after) return true
  if (before.length !== after.length) return false
  for (var entryIndex = 0; entryIndex < after.length; entryIndex++) {
    if (!sameSummaryValue(before[entryIndex], after[entryIndex], 4)) return false
  }
  return true
}

function removeById(list, id) {
  var source = Array.isArray(list) ? list : []
  var result = []
  for (var sourceIndex = 0; sourceIndex < source.length; sourceIndex++) {
    if (source[sourceIndex] && source[sourceIndex].id === id) continue
    result.push(source[sourceIndex])
  }
  return result
}

// Invariant: Rollback anchors against the list before the first pending edit; each edit's shortened snapshot can restore rows in the wrong order.
function restoreRow(list, row, order, index) {
  var source = Array.isArray(list) ? list : []
  var settled = Array.isArray(order) ? order : []
  var pos = indexById(settled, row ? row.id : "")
  var at
  for (var after = pos + 1; pos >= 0 && after < settled.length; after++) {
    at = indexById(source, settled[after] ? settled[after].id : "")
    if (at >= 0) return source.slice(0, at).concat([row], source.slice(at))
  }
  for (var ahead = pos - 1; ahead >= 0; ahead--) {
    at = indexById(source, settled[ahead] ? settled[ahead].id : "")
    if (at >= 0) return source.slice(0, at + 1).concat([row], source.slice(at + 1))
  }
  var held = pos >= 0 ? pos : (Number(index) || 0)
  var clamped = Math.max(0, Math.min(held, source.length))
  return source.slice(0, clamped).concat([row], source.slice(clamped))
}

// Invariant: A failed edit cannot restore a row removed again by a later pending edit; the same rule repairs cached and visible lists.
function listAfterRestore(list, row, removed, stillRemoved, order, index) {
  var source = Array.isArray(list) ? list : []
  if (!row) return source
  if (indexById(source, row.id) >= 0) return replaceById(source, row)
  if (removed === true && stillRemoved !== true) return restoreRow(source, row, order, index)
  return source
}

// Invariant: Success drops one intent; failure replays later intents from the failed intent's baseline without undoing them.

function withoutIntent(entries, token) {
  var list = Array.isArray(entries) ? entries : []
  var result = []
  for (var rowIndex = 0; rowIndex < list.length; rowIndex++) {
    if (!list[rowIndex] || list[rowIndex].token === token) continue
    result.push(list[rowIndex])
  }
  return result
}

function rebaseIntents(entries, token) {
  var list = Array.isArray(entries) ? entries : []
  var at = -1
  for (var rowIndex = 0; rowIndex < list.length; rowIndex++) {
    if (list[rowIndex] && list[rowIndex].token === token) { at = rowIndex; break }
  }
  if (at < 0) return null
  var result = list.slice(0, at)
  var summary = list[at].before
  for (var followingIndex = at + 1; followingIndex < list.length; followingIndex++) {
    var entry = {}
    for (var key in list[followingIndex]) entry[key] = list[followingIndex][key]
    entry.before = summary
    summary = typeof entry.apply === "function" ? entry.apply(summary) : summary
    result.push(entry)
  }
  return { entries: result, summary: summary }
}

function intentsWith(intents, id, entry) {
  var all = {}
  for (var key in intents) all[key] = intents[key]
  all[id] = (all[id] || []).concat([entry])
  return all
}

// Invariant: An answer for an unheld intent uses the supplied fallback without changing unrelated intents.
function intentsSettled(intents, id, token, failed, fallback) {
  var all = {}
  for (var key in intents) all[key] = intents[key]
  var held = all[id] || []
  var outcome = failed ? rebaseIntents(held, token) : null
  if (!outcome) outcome = { entries: withoutIntent(held, token), summary: fallback }
  if (outcome.entries.length === 0) delete all[id]
  else all[id] = outcome.entries
  return { intents: all, outcome: outcome }
}

// Invariant: A later pending removal keeps a row absent when an earlier edit fails.
function anyIntentRemoved(entries) {
  var list = Array.isArray(entries) ? entries : []
  for (var rowIndex = 0; rowIndex < list.length; rowIndex++) {
    if (list[rowIndex] && list[rowIndex].removed === true) return true
  }
  return false
}

// Invariant: Keep the first pending edit's list order until every edit in that query settles.
function settledListsHeld(lists, query, messages, previews) {
  var all = {}
  for (var key in lists) all[key] = lists[key]
  var held = all[query]
  all[query] = {
    messages: held ? held.messages : (Array.isArray(messages) ? messages.slice() : []),
    previews: held ? held.previews : (Array.isArray(previews) ? previews.slice() : []),
    pending: (held ? held.pending : 0) + 1
  }
  return all
}

function settledListsReleased(lists, query) {
  var all = {}
  for (var key in lists) all[key] = lists[key]
  var held = all[query]
  if (!held) return all
  if (held.pending <= 1) delete all[query]
  else all[query] = { messages: held.messages, previews: held.previews, pending: held.pending - 1 }
  return all
}

function previewAfterRestore(list, row, present, order, index) {
  var source = Array.isArray(list) ? list : []
  var at = indexById(source, row ? row.id : "")
  if (present) return at >= 0 ? replaceById(source, row) : restoreRow(source, row, order, index)
  return at >= 0 ? removeById(source, row.id) : source
}

function replaceById(list, summary) {
  var source = Array.isArray(list) ? list : []
  var result = []
  for (var rowIndex = 0; rowIndex < source.length; rowIndex++) {
    result.push(source[rowIndex] && summary && source[rowIndex].id === summary.id ? summary : source[rowIndex])
  }
  return result
}

// Invariant: Live search metadata replaces cached rows by ID while completion order cannot reorder equal-date matches.
function mergeSearchResults(cached, live) {
  var lists = [Array.isArray(cached) ? cached : [], Array.isArray(live) ? live : []]
  var positions = {}
  var merged = []
  var order = 0
  for (var listIndex = 0; listIndex < lists.length; listIndex++) {
    for (var rowIndex = 0; rowIndex < lists[listIndex].length; rowIndex++) {
      var row = lists[listIndex][rowIndex]
      var id = String(row && row.id ? row.id : "")
      if (id === "") continue
      if (positions[id] !== undefined) {
        merged[positions[id]].row = row
        continue
      }
      positions[id] = merged.length
      merged.push({ row: row, order: order++ })
    }
  }

  merged.sort(function(left, right) {
    var leftTimeMs = left.row && left.row.date && typeof left.row.date.getTime === "function"
      ? Number(left.row.date.getTime()) : 0
    var rightTimeMs = right.row && right.row.date && typeof right.row.date.getTime === "function"
      ? Number(right.row.date.getTime()) : 0
    if (leftTimeMs !== rightTimeMs) return rightTimeMs - leftTimeMs
    return left.order - right.order
  })
  var result = []
  for (var mergedIndex = 0; mergedIndex < merged.length; mergedIndex++) result.push(merged[mergedIndex].row)
  return result
}

// Invariant: A settled search page contains only server-confirmed IDs; cached metadata may fill a confirmed read failure, never an unconfirmed match.
function settledSearchResults(existing, preview, live, ids, append) {
  var known = {}
  var cached = Array.isArray(preview) ? preview : []
  var fresh = Array.isArray(live) ? live : []
  for (var cachedIndex = 0; cachedIndex < cached.length; cachedIndex++) {
    if (cached[cachedIndex] && cached[cachedIndex].id) known[String(cached[cachedIndex].id)] = cached[cachedIndex]
  }
  for (var freshIndex = 0; freshIndex < fresh.length; freshIndex++) {
    if (fresh[freshIndex] && fresh[freshIndex].id) known[String(fresh[freshIndex].id)] = fresh[freshIndex]
  }

  var page = []
  var wanted = Array.isArray(ids) ? ids : []
  for (var wantedIndex = 0; wantedIndex < wanted.length; wantedIndex++) {
    var id = String(wanted[wantedIndex] || "")
    if (known[id]) page.push(known[id])
  }
  return append === true ? mergeSearchResults(existing, page) : page
}

// Invariant: Missing fresh summaries invalidate continuation even when cached rows can temporarily fill the page.
function missingSearchSummaryIds(summaries, ids) {
  var known = {}
  var rows = Array.isArray(summaries) ? summaries : []
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    if (rows[rowIndex] && rows[rowIndex].id) known[String(rows[rowIndex].id)] = true
  }
  var missing = []
  var wanted = Array.isArray(ids) ? ids : []
  for (var wantedIndex = 0; wantedIndex < wanted.length; wantedIndex++) {
    var id = String(wanted[wantedIndex] || "")
    if (id !== "" && !known[id]) missing.push(id)
  }
  return missing
}

// Invariant: Detail responses may omit listing metadata, notably HEY subjects; preserve the known value when the detail carries no replacement.
function detailSummary(previous, summary) {
  if (!summary) return previous
  if (!previous) return summary
  var merged = {}
  for (var key in summary) merged[key] = summary[key]
  if (merged.subject === "(no subject)" && previous.subject) merged.subject = previous.subject
  if (!merged.from || (!merged.from.name && !merged.from.email)) merged.from = previous.from
  if (!merged.snippet) merged.snippet = previous.snippet
  // Invariant: Restore date, relative time and full time together so they describe the same instant.
  if (!merged.date && previous.date) {
    merged.date = previous.date
    merged.time = previous.time
    merged.fullTime = previous.fullTime
  }
  // Invariant: An unknown detail thread count preserves the listing block, but its fresh unread and starred flags remain authoritative.
  if (merged.thread && merged.thread.count === 0
      && previous.thread && previous.thread.count > 0)
    merged.thread = previous.thread
  return merged
}

// Invariant: Current account labels and thread state override stale detail-cache state for the same message; otherwise a read message can become unread again.
function cachedDetailSummary(known, summary) {
  if (!summary || !known || known.id !== summary.id || !Array.isArray(known.labelIds)) return summary
  var block = known.thread && known.thread.count > 0 ? known.thread : null
  return rowWithThread(withLabels(summary, known.labelIds.slice()), block)
}

function indexById(list, id) {
  var source = Array.isArray(list) ? list : []
  for (var rowIndex = 0; rowIndex < source.length; rowIndex++) {
    if (source[rowIndex] && source[rowIndex].id === id) return rowIndex
  }
  return -1
}

function messageById(primary, fallback, id) {
  var first = Array.isArray(primary) ? primary : []
  var index = indexById(first, id)
  if (index >= 0) return first[index]
  var second = Array.isArray(fallback) ? fallback : []
  index = indexById(second, id)
  return index >= 0 ? second[index] : null
}

function currentFolderName(view) {
  if (!view) return "Inbox"
  var labelId = String(view.rawLabelId || "")
  var labels = view.labels || []
  for (var labelIndex = 0; labelId !== "" && labelIndex < labels.length; labelIndex++) {
    if (String(labels[labelIndex].id || "") === labelId)
      return String(labels[labelIndex].name || labels[labelIndex].rawName || "Mail")
  }
  if (view.searchQuery || view.rawQuery) return "Search results"
  var mailboxes = view.mailboxes || []
  var key = String(view.mailboxKey || "inbox")
  for (var mailboxIndex = 0; mailboxIndex < mailboxes.length; mailboxIndex++) {
    if (mailboxes[mailboxIndex].key === key) return String(mailboxes[mailboxIndex].label)
  }
  return key === "inbox" ? "Inbox" : "Mail"
}

// Invariant: Sidebar badges and digit shortcuts share one displayed order; Ctrl+0 remains reserved for zoom reset.
function sidebarSlots(mailboxes, labels, limit) {
  var maximum = Math.max(0, Math.floor(Number(limit) || 0))
  var result = []
  var boxes = Array.isArray(mailboxes) ? mailboxes : []
  for (var mailboxIndex = 0; mailboxIndex < boxes.length && result.length < maximum; mailboxIndex++) {
    if (!boxes[mailboxIndex] || !boxes[mailboxIndex].key) continue
    result.push({ kind: "mailbox", key: String(boxes[mailboxIndex].key), name: String(boxes[mailboxIndex].label || ""),
      icon: String(boxes[mailboxIndex].icon || "mail") })
  }
  // Invariant: Preserve the supplied visible tree order; sorting labels here would make shortcut numbers open different rows.
  var all = Array.isArray(labels) ? labels : []
  for (var labelIndex = 0; labelIndex < all.length && result.length < maximum; labelIndex++) {
    if (!all[labelIndex] || all[labelIndex].system === true) continue
    result.push({ kind: "label", id: String(all[labelIndex].id || ""),
      name: String(all[labelIndex].rawName || all[labelIndex].name || "") })
  }
  return result
}

function slotNumberOf(slots, kind, handle) {
  var list = Array.isArray(slots) ? slots : []
  for (var slotIndex = 0; slotIndex < list.length; slotIndex++) {
    if (list[slotIndex].kind !== kind) continue
    if (String(kind === "mailbox" ? list[slotIndex].key : list[slotIndex].id) !== String(handle)) continue
    return slotIndex + 1
  }
  return 0
}

function wrappedIndex(index, delta, count) {
  var total = Math.max(0, Math.floor(Number(count) || 0))
  if (total === 0) return 0
  var from = Math.floor(Number(index) || 0)
  var step = Math.floor(Number(delta) || 0)
  return ((from + step) % total + total) % total
}

// Invariant: Cursor movement anchors on the representative row, even while the reader shows another conversation member.
function cursorAfterOffset(list, cursorId, delta) {
  var source = Array.isArray(list) ? list : []
  if (source.length === 0) return ""
  var step = Math.floor(Number(delta) || 0)
  var index = indexById(source, cursorId)

  if (index < 0) return step < 0 ? source[source.length - 1].id : source[0].id
  var next = index + step
  if (next < 0) next = 0
  if (next > source.length - 1) next = source.length - 1
  return source[next].id
}

// Invariant: Choose the surviving neighbour before removing a row; a missing cursor would restart later movement at the top.
function cursorAfterRemoval(list, cursorId) {
  var source = Array.isArray(list) ? list : []
  var index = indexById(source, cursorId)
  if (index < 0) return ""
  if (index + 1 < source.length) return source[index + 1].id
  if (index > 0) return source[index - 1].id
  return ""
}

function cursorAfterReload(list, cursorId) {
  var source = Array.isArray(list) ? list : []
  if (source.length === 0) return ""
  if (indexById(source, cursorId) >= 0) return cursorId
  return source[0].id
}

// Invariant: Revealing an already visible row must not recenter the scroller.
function contentYToReveal(contentY, viewportHeight, itemY, itemHeight,
                          contentHeight, margin, originY, topMargin, bottomMargin) {
  var top = Number(contentY) || 0
  var view = Number(viewportHeight) || 0
  var itemTop = Number(itemY) || 0
  var height = Number(itemHeight) || 0
  var padding = Number(margin) || 0
  var next = top
  // Invariant: An oversized row reveals its beginning, so bottom alignment cannot push the text being read offscreen.
  if (height + padding + padding > view) next = itemTop - padding
  else if (itemTop - padding < top) next = itemTop - padding
  else if (itemTop + height + padding > top + view) next = itemTop + height + padding - view
  // Invariant: Keyboard reveal and wheel movement use the same bounds, including origin and margins.
  return clampContentY(next, contentYBounds(originY, contentHeight, view,
    topMargin, bottomMargin))
}

function unreadCount(list) {
  var source = Array.isArray(list) ? list : []
  var count = 0
  for (var rowIndex = 0; rowIndex < source.length; rowIndex++) {
    if (source[rowIndex] && source[rowIndex].unread) count++
  }
  return count
}

function badgeText(count, cap) {
  var value = Math.max(0, Math.floor(Number(count) || 0))
  var limit = Math.max(1, Math.floor(Number(cap) || 99))
  if (value === 0) return ""
  return value > limit ? limit + "+" : String(value)
}

function barTooltip(state, email, unread, provider, authKind) {
  var name = providerName(provider)
  if (state !== "ready")
    return name + " · " + (setupHeadline(state, name, authKind) || "Not connected")
  var address = String(email || "").trim()
  var count = Math.max(0, Math.floor(Number(unread) || 0))
  var suffix = count === 0 ? "No unread mail"
    : (count === 1 ? "1 unread message" : count + " unread messages")
  return address ? address + " · " + suffix : name + " · " + suffix
}

// Invariant: Notification priming uses the mailbox's timestamp domain rather than the local machine clock.
function newestDate(summaries) {
  var list = Array.isArray(summaries) ? summaries : []
  var newest = 0
  for (var rowIndex = 0; rowIndex < list.length; rowIndex++) {
    var summary = list[rowIndex]
    if (!summary || !summary.date || typeof summary.date.getTime !== "function") continue
    var time = summary.date.getTime()
    if (isFinite(time) && time > newest) newest = time
  }
  return newest
}

// Invariant: Initial inbox mail never notifies. The fixed server-time floor suppresses older fetched rows without losing later out-of-order arrivals; undated unseen rows remain eligible.
function newArrivals(summaries, seenIds, primed, floorMs) {
  if (!primed) return []
  var list = Array.isArray(summaries) ? summaries : []
  var seen = seenIds || {}
  var arrivals = []
  var floor = typeof floorMs === "number" && isFinite(floorMs) && floorMs > 0 ? floorMs : 0
  for (var summaryIndex = 0; summaryIndex < list.length; summaryIndex++) {
    var summary = list[summaryIndex]
    if (!summary || !summary.unread || !summary.inInbox) continue
    if (seen[summary.id]) continue
    if (floor > 0 && summary.date && typeof summary.date.getTime === "function") {
      var time = summary.date.getTime()
      if (isFinite(time) && time < floor) continue
    }
    arrivals.push(summary)
  }
  return arrivals
}

// Invariant: Notification text remains plain until the platform boundary escapes markup and separates command arguments.
function notificationText(value) {
  return String(value === undefined || value === null ? "" : value)
}

function notificationTitle(summary) {
  var title = summary && summary.from ? notificationText(summary.from.display) : ""
  return title === "" ? "New message" : title
}

function notificationBody(summary) {
  if (!summary) return ""
  var subject = notificationText(String(summary.subject || "").trim())
  var snippet = notificationText(String(summary.snippet || "").trim())
  if (!snippet) return subject
  return subject + "\n" + (snippet.length > 140 ? snippet.substring(0, 139) + "…" : snippet)
}

function pluralize(count, singular, plural) {
  var value = Math.max(0, Math.floor(Number(count) || 0))
  return value + " " + (value === 1 ? singular : (plural || singular + "s"))
}

// Invariant: Bulk-action counts describe the displayed rows, using conversations only when those rows actually grouped members.
function markAllReadNote(rows, expanded) {
  return pluralize(rows, expanded === true ? "conversation" : "message")
    + " marked read"
}

// Invariant: Provider conversation capability alone cannot justify a conversation count; the displayed rows must carry member evidence.
function listNoun(list) {
  var rows = Array.isArray(list) ? list : []
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    if (badgeCount(rows[rowIndex]) > 0) return "conversation"
  }
  return "message"
}

// Invariant: A missing or zero thread count means grouping is unknown; only at least MINIMUM_MEMBERS earns a badge.
function badgeCount(summary) {
  var block = Conversation.blockOf(summary ? summary.thread : null)
  return block && block.count >= Conversation.MINIMUM_MEMBERS ? block.count : 0
}

// Invariant: Reloads retain the paginated depth so refreshes cannot discard rows the reader already reached.
var RELOAD_CEILING = 100

function reloadLimit(pageSize, loadedDepth) {
  var page = Math.max(1, Math.floor(Number(pageSize)) || 1)
  var depth = Math.floor(Number(loadedDepth)) || 0
  if (depth <= page) return page
  return Math.min(Math.max(page, RELOAD_CEILING), depth)
}

// Invariant: Projection identity includes account, thread and mailbox, with JSON framing so equal provider IDs or embedded delimiters cannot collide.
function projectionKey(source) {
  var fields = source && typeof source === "object" ? source : ({})
  var thread = fields.thread
  var id = thread && typeof thread === "object" && thread.id ? String(thread.id) : ""
  return JSON.stringify([String(fields.accountId || ""), id, String(fields.mailboxKey || "")])
}

// Invariant: Pending projections disable stale navigation, including first/last fallbacks; a different rail also drops the previous stops.
function blankProjection() {
  return { showsRail: false, stops: [], caption: "", navigation: {}, memberIds: [] }
}

function pendingProjection(projection, sameRail) {
  if (!sameRail || !projection || typeof projection !== "object") return blankProjection()
  return Object.assign({}, projection, { navigation: {}, first: "", last: "" })
}

function resultSummary(list, estimate, hasMore) {
  var shown = Array.isArray(list) ? list.length : 0
  if (shown === 0) return "No messages"
  var noun = listNoun(list)
  if (!hasMore) return pluralize(shown, noun)
  var total = Math.floor(Number(estimate) || 0)
  // Invariant: An unfinished listing without a larger total reports rows so far, not a fabricated complete count.
  if (total <= shown) return pluralize(shown, noun) + " so far"
  return shown + " of about " + total
}

function syncedShort(syncLabel) {
  var label = String(syncLabel || "")
  if (label === "") return ""
  if (label === "Checking for mail") return "checking"
  var match = /^Synced (.+)$/.exec(label)
  return match ? match[1] : label
}

var UNIFIED_LABEL = "All mailboxes"

// Invariant: A unified status cannot reuse one account's address or sync age as evidence for every account.
function readingStatusLine(unified, email, syncLabel) {
  if (unified === true) return UNIFIED_LABEL
  return accountStatusLine(email, syncLabel)
}

function accountStatusLine(email, syncLabel) {
  var address = String(email || "")
  if (address === "") return "Not connected"
  var age = syncedShort(syncLabel)
  return age === "" ? address : address + " · " + age
}

function splitBrand(title, brand) {
  var text = String(title === undefined || title === null ? "" : title)
  var word = String(brand === undefined || brand === null ? "" : brand)
  var at = word === "" ? -1 : text.indexOf(word)
  if (at < 0) return { before: text, brand: "", after: "" }
  return {
    before: text.slice(0, at),
    brand: word,
    after: text.slice(at + word.length)
  }
}

function truncate(text, limit) {
  var value = String(text || "")
  var maximum = Math.max(4, Math.floor(Number(limit) || 80))
  return value.length <= maximum ? value : value.substring(0, maximum - 1) + "…"
}

function sortedSections(sections) {
  var values = Array.isArray(sections) ? sections.slice() : []
  var known = []
  for (var sectionIndex = 0; sectionIndex < values.length; sectionIndex++) {
    var entry = values[sectionIndex] || {}
    var sectionY = Number(entry.y)
    if (!isFinite(sectionY) || String(entry.key || "") === "") continue
    known.push({ key: String(entry.key), y: sectionY })
  }
  known.sort(function(left, right) { return left.y - right.y })
  return known
}

// Invariant: Every settings heading must be able to reach the viewport top, or the final sections can never become active.
function activeSettingsSection(sections, contentY) {
  var known = sortedSections(sections)
  if (known.length === 0) return ""
  var top = Number(contentY) || 0
  var active = known[0].key
  for (var sectionIndex = 0; sectionIndex < known.length; sectionIndex++) {
    if (known[sectionIndex].y <= top) active = known[sectionIndex].key
  }
  return active
}

function settingsContentHeight(sections, pageHeight, viewportHeight) {
  var known = sortedSections(sections)
  var page = Math.max(0, Number(pageHeight) || 0)
  var viewport = Math.max(0, Number(viewportHeight) || 0)
  if (known.length === 0) return page
  return Math.max(page, known[known.length - 1].y + viewport)
}

// Invariant: Scroll bounds include originY and margins. Clamping to zero would make ListView headers and Flickable top margins unreachable.
function contentYBounds(originY, contentHeight, viewportHeight, topMargin, bottomMargin) {
  var origin = Number(originY) || 0
  var content = Number(contentHeight) || 0
  var view = Number(viewportHeight) || 0
  var top = Number(topMargin) || 0
  var bottom = Number(bottomMargin) || 0
  var minimum = origin - top

  var maximum = Math.max(minimum, origin + content + bottom - view)
  return { min: minimum, max: maximum }
}

function clampContentY(value, bounds) {
  var limits = bounds || { min: 0, max: 0 }
  return Math.max(limits.min, Math.min(limits.max, Number(value) || 0))
}

// Invariant: Wheel distance depends on total rotation, not event chunking; per-event caps would make equal gestures travel different distances. Qt angleDelta uses eighths of a degree, with 120 units per notch.
var WHEEL_UNITS_PER_NOTCH = 120
var WHEEL_PIXELS_PER_NOTCH = 120

var WHEEL_GAIN = 2

// Invariant: Rotation units and pixel distance remain separate even when their conversion ratio is one.
function wheelDistance(angleDelta) {
  return (Number(angleDelta) || 0) / WHEEL_UNITS_PER_NOTCH * WHEEL_PIXELS_PER_NOTCH
}

// Invariant: Device pixel deltas take precedence over angle deltas, with gain applied once.
function wheelPixels(angleDelta, pixelDelta) {
  var pixels = Number(pixelDelta) || 0
  if (pixels === 0) pixels = wheelDistance(angleDelta)
  return pixels * WHEEL_GAIN
}

function wheelScrollByPixels(contentY, pixels, contentHeight, viewportHeight,
                             originY, topMargin, bottomMargin) {
  var bounds = contentYBounds(originY, contentHeight, viewportHeight,
    topMargin, bottomMargin)
  return clampContentY((Number(contentY) || 0) - (Number(pixels) || 0), bounds)
}

function wheelScrollTarget(contentY, angleDelta, contentHeight, viewportHeight,
                           originY, topMargin, bottomMargin) {
  return wheelScrollByPixels(contentY, wheelDistance(angleDelta), contentHeight,
    viewportHeight, originY, topMargin, bottomMargin)
}

function settingsScrollTarget(sections, key, contentHeight, viewportHeight) {
  var known = sortedSections(sections)
  var wanted = String(key || "")
  for (var sectionIndex = 0; sectionIndex < known.length; sectionIndex++) {
    if (known[sectionIndex].key !== wanted) continue
    var content = Number(contentHeight) || 0
    var viewport = Number(viewportHeight) || 0
    var limit = Math.max(0, content - viewport)
    return Math.max(0, Math.min(known[sectionIndex].y, limit))
  }
  return -1
}

// Invariant: A preview must not mark mail read; explicit opening may mark its unread message.
function marksReadOnArrival(summary, isPreview) {
  return !!summary && summary.unread === true && isPreview !== true
}

function previewReadable(messages, id) {
  var at = indexById(messages, id)
  return at >= 0 && !!messages[at] && messages[at].unread === true
}

// Invariant: Standing image permission applies to an explicitly opened message; a preview must not contact tracking hosts.
function showsRemoteImages(alwaysShow, isPreview) {
  return alwaysShow === true && isPreview !== true
}

// Invariant: Selection belongs to interaction state rather than provider-owned message summaries.
function toggleId(ids, id) {
  var list = Array.isArray(ids) ? ids.slice() : []
  var key = String(id || "")
  if (key === "") return list
  var at = list.indexOf(key)
  if (at >= 0) list.splice(at, 1)
  else list.push(key)
  return list
}

function idsBetween(list, fromId, toId) {
  var source = Array.isArray(list) ? list : []
  var fromIndex = indexById(source, fromId)
  var toIndex = indexById(source, toId)
  if (fromIndex < 0 && toIndex < 0) return []
  if (fromIndex < 0) fromIndex = toIndex
  if (toIndex < 0) toIndex = fromIndex
  var firstIndex = Math.min(fromIndex, toIndex)
  var lastIndex = Math.max(fromIndex, toIndex)
  var result = []
  for (var rowIndex = firstIndex; rowIndex <= lastIndex; rowIndex++) result.push(source[rowIndex].id)
  return result
}

function unionIds(ids, more) {
  var result = Array.isArray(ids) ? ids.slice() : []
  var extra = Array.isArray(more) ? more : []
  for (var labelIndex = 0; labelIndex < extra.length; labelIndex++) {
    if (result.indexOf(extra[labelIndex]) < 0) result.push(extra[labelIndex])
  }
  return result
}

// Invariant: Range toggling follows the endpoint's next state; clearing cannot select unchecked gaps or affect rows outside the range.
function toggleRange(ids, list, fromId, toId) {
  var checked = Array.isArray(ids) ? ids : []
  if (indexById(list, toId) < 0) return checked.slice()
  var range = idsBetween(list, fromId, toId)
  if (checked.indexOf(toId) < 0) return unionIds(checked, range)
  var result = []
  for (var messageIndex = 0; messageIndex < checked.length; messageIndex++) {
    if (range.indexOf(checked[messageIndex]) < 0) result.push(checked[messageIndex])
  }
  return result
}

// Invariant: Selection drops rows that are no longer visible so later bulk actions cannot target hidden messages.
function retainIds(ids, list) {
  var source = Array.isArray(list) ? list : []
  var checked = Array.isArray(ids) ? ids : []
  var result = []
  for (var messageIndex = 0; messageIndex < checked.length; messageIndex++) {
    if (indexById(source, checked[messageIndex]) >= 0) result.push(checked[messageIndex])
  }
  return result
}

function allIds(list) {
  var source = Array.isArray(list) ? list : []
  var result = []
  for (var rowIndex = 0; rowIndex < source.length; rowIndex++) result.push(source[rowIndex].id)
  return result
}

function summariesById(list, ids) {
  var source = Array.isArray(list) ? list : []
  var checked = Array.isArray(ids) ? ids : []
  var result = []
  for (var messageIndex = 0; messageIndex < checked.length; messageIndex++) {
    var index = indexById(source, checked[messageIndex])
    if (index >= 0) result.push(source[index])
  }
  return result
}

// Invariant: Bulk removal chooses the next surviving cursor row from the original order, before those rows disappear.
function cursorAfterRemovals(list, removedIds, cursorId) {
  var source = Array.isArray(list) ? list : []
  var gone = Array.isArray(removedIds) ? removedIds : []
  var index = indexById(source, cursorId)
  if (index < 0) return ""
  var candidateIndex
  for (candidateIndex = index; candidateIndex < source.length; candidateIndex++) {
    if (gone.indexOf(source[candidateIndex].id) < 0) return source[candidateIndex].id
  }
  for (candidateIndex = index - 1; candidateIndex >= 0; candidateIndex--) {
    if (gone.indexOf(source[candidateIndex].id) < 0) return source[candidateIndex].id
  }
  return ""
}

// Invariant: A mixed selection uses one star action; only an entirely starred selection is unstarred.
function starActionFor(summaries) {
  var rows = Array.isArray(summaries) ? summaries : []
  if (rows.length === 0) return "star"
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    if (!rows[rowIndex] || !rows[rowIndex].starred) return "star"
  }
  return "unstar"
}

function batchNote(count, actionLabel) {
  var label = String(actionLabel || "")
  if (label === "") return pluralize(count, "message")
  return pluralize(count, "message") + " " + label.charAt(0).toLowerCase() + label.slice(1)
}

function selectionStatus(count) {
  var selectedCount = Math.max(0, Math.floor(Number(count) || 0))
  return selectedCount === 0 ? "" : selectedCount + " selected"
}

// Invariant: Batch rollback restores only failed rows; successful removals remain removed.
function restoreRows(current, before, failedIds) {
  var now = Array.isArray(current) ? current.slice() : []
  var was = Array.isArray(before) ? before : []
  var ids = Array.isArray(failedIds) ? failedIds : []
  for (var rowIndex = 0; rowIndex < was.length; rowIndex++) {
    var row = was[rowIndex]
    if (!row || ids.indexOf(String(row.id)) < 0) continue
    var at = indexById(now, row.id)
    if (at >= 0) { now[at] = row; continue }

    var insertAt = now.length
    for (var followingIndex = rowIndex + 1; followingIndex < was.length; followingIndex++) {
      var later = indexById(now, was[followingIndex].id)
      if (later >= 0) { insertAt = later; break }
    }
    now.splice(insertAt, 0, row)
  }
  return now
}

function batchFailureNote(asked, failed, actionLabel, error) {
  var label = String(actionLabel || "")
  var verb = label === "" ? "acted on" : label.charAt(0).toLowerCase() + label.slice(1)
  var reason = String(error || "").trim()
  return failed + " of " + asked + " could not be " + verb + (reason === "" ? "" : ": " + reason)
}

// Invariant: Missing ancestors remain nonselectable tree rows. A folded parent includes descendant unread counts so folding cannot hide unread mail.
function labelTree(labels, collapsedPaths) {
  var all = Array.isArray(labels) ? labels : []
  var folded = Array.isArray(collapsedPaths) ? collapsedPaths : []
  // Invariant: Server-controlled names such as constructor and __proto__ must remain ordinary child keys.
  var root = { children: Object.create(null), order: [] }
  for (var labelIndex = 0; labelIndex < all.length; labelIndex++) {
    var label = all[labelIndex]
    if (!label || label.system) continue
    var delimiter = labelDelimiter(label)
    var full = String(label.name || label.rawName || "")
    if (full === "") continue
    var parts = delimiter === "" ? [full] : full.split(delimiter)
    var node = root
    var path = ""
    for (var partIndex = 0; partIndex < parts.length; partIndex++) {
      var part = parts[partIndex]
      if (part === "" && partIndex > 0) continue
      path = path === "" ? part : path + delimiter + part
      if (!node.children[part]) {
        node.children[part] = { name: part, path: path, label: null,
          unread: 0, children: Object.create(null), order: [] }
        node.order.push(part)
      }
      node = node.children[part]
    }
    node.label = label
    node.unread = Math.max(0, Math.floor(Number(label.unread) || 0))
  }

  function subtreeUnread(node) {
    var sum = node.unread
    for (var childIndex = 0; childIndex < node.order.length; childIndex++) sum += subtreeUnread(node.children[node.order[childIndex]])
    return sum
  }

  var result = []
  function walk(node, depth) {
    var names = node.order.slice().sort(function(leftName, rightName) {
      var left = leftName.toLowerCase(), right = rightName.toLowerCase()
      return left < right ? -1 : (left > right ? 1 : 0)
    })
    for (var nameIndex = 0; nameIndex < names.length; nameIndex++) {
      var child = node.children[names[nameIndex]]
      var hasChildren = child.order.length > 0
      var expanded = !hasChildren || folded.indexOf(child.path) < 0
      result.push({
        id: child.label ? String(child.label.id || "") : "",
        rawName: child.label ? String(child.label.rawName || child.label.name || "") : "",
        name: child.name,
        path: child.path,
        depth: depth,
        hasChildren: hasChildren,
        expanded: expanded,
        selectable: !!child.label,
        unread: expanded ? child.unread : subtreeUnread(child)
      })
      if (expanded) walk(child, depth + 1)
    }
  }
  walk(root, 0)
  return result
}

// Invariant: Digit shortcuts number only selectable labels in the visible folded-tree order.
function visibleLabels(labels, collapsedPaths) {
  var rows = labelTree(labels, collapsedPaths)
  var all = Array.isArray(labels) ? labels : []
  // Performance: Index labels once because a large folder rail is rebuilt on every fold.
  var byId = Object.create(null)
  for (var listIndex = 0; listIndex < all.length; listIndex++) {
    if (all[listIndex] && byId[String(all[listIndex].id || "")] === undefined) byId[String(all[listIndex].id || "")] = all[listIndex]
  }
  var result = []
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    if (!rows[rowIndex].selectable) continue
    var label = byId[rows[rowIndex].id]
    if (label !== undefined) result.push(label)
  }
  return result
}

// Invariant: An absent delimiter defaults to slash; an explicitly empty IMAP delimiter means no hierarchy.
function labelDelimiter(label) {
  if (!label || label.delimiter === undefined || label.delimiter === null) return "/"
  return String(label.delimiter)
}

function togglePath(paths, path) {
  return toggleId(paths, path)
}

function activityStatus(counts) {
  var activityCounts = counts || {}
  function count(value) { return Math.max(0, Math.floor(Number(value)) || 0) }
  var sending = count(activityCounts.sending)
  var queuedSends = count(activityCounts.queuedSends)
  var running = count(activityCounts.running)
  var waiting = count(activityCounts.waiting)
  var parts = []
  if (sending > 0) parts.push(sending === 1 ? "Sending" : "Sending " + sending)
  if (queuedSends > 0) parts.push(queuedSends + " queued to send")
  if (running > 0) parts.push(running === 1 ? "1 action running" : running + " actions running")
  if (waiting > 0) parts.push(waiting + " waiting")
  return parts.join(" \u00b7 ")
}

// Invariant: Empty delimiters keep each path as one leaf; no parent or nested destination can be inferred.
function labelLeaf(path, delimiter) {
  var text = String(path || "")
  var sep = String(delimiter === undefined || delimiter === null ? "/" : delimiter)
  if (sep === "") return text
  var at = text.lastIndexOf(sep)
  return at < 0 ? text : text.slice(at + sep.length)
}

function labelParent(path, delimiter) {
  var text = String(path || "")
  var sep = String(delimiter === undefined || delimiter === null ? "/" : delimiter)
  if (sep === "") return ""
  var at = text.lastIndexOf(sep)
  return at < 0 ? "" : text.slice(0, at)
}

function labelPathJoin(parent, leaf, delimiter) {
  var head = String(parent || "")
  var tail = String(leaf || "").trim()
  var sep = String(delimiter === undefined || delimiter === null ? "/" : delimiter)
  if (head === "" || sep === "") return tail
  return head + sep + tail
}

function labelNameProblem(name, delimiter) {
  var text = String(name || "").trim()
  var sep = String(delimiter === undefined || delimiter === null ? "/" : delimiter)
  if (text === "") return "A label needs a name"
  if (sep !== "" && text.indexOf(sep) >= 0) return "A name cannot contain " + sep + "; use New sub-label to nest"
  return ""
}

function labelNestProblem(parentPath, delimiter) {
  var sep = String(delimiter === undefined || delimiter === null ? "/" : delimiter)
  if (sep !== "" || String(parentPath || "") === "") return ""
  return "This server keeps its folders in one flat list, so nothing can go under " + String(parentPath)
}

// Invariant: A label cannot move under itself or a descendant.
function labelMoveTargets(labels, movingPath, delimiter) {
  var all = Array.isArray(labels) ? labels : []
  var sep = String(delimiter === undefined || delimiter === null ? "/" : delimiter)
  var moving = String(movingPath || "")
  var result = [{ id: "", name: "Top level", path: "" }]

  if (sep === "") return result
  for (var accountIndex = 0; accountIndex < all.length; accountIndex++) {
    var label = all[accountIndex]
    if (!label || label.system) continue
    var path = String(label.name || label.rawName || "")
    if (path === "" || path === moving) continue
    if (moving !== "" && path.indexOf(moving + sep) === 0) continue
    if (path === labelParent(moving, sep)) continue
    result.push({ id: String(label.id || ""), name: path, path: path })
  }
  return result
}

// Invariant: IMAP folder renames change watched wire IDs, while stable provider IDs survive; removed folders stop being watched.
function migrateMonitoredIds(monitored, before, after, oldPath, newPath, delimiter) {
  return migrateMonitoredChanges(monitored, [{ before: before, oldPath: oldPath,
    newPath: newPath, delimiter: delimiter }], after)
}

// Invariant: Apply chained renames before matching the final listing, which may never contain their intermediate paths.
function pathAfterLabelMoves(id, moves) {
  var path = ""
  for (var moveIndex = 0; moveIndex < moves.length; moveIndex++) {
    var move = moves[moveIndex]
    var before = Array.isArray(move.before) ? move.before : []
    if (path === "") {
      var oldIndex = indexById(before, id)
      if (oldIndex >= 0) path = String(before[oldIndex].name || before[oldIndex].rawName || "")
    }
    var from = String(move.oldPath || "")
    var to = String(move.newPath || "")
    var delimiter = String(move.delimiter === undefined || move.delimiter === null ? "/" : move.delimiter)
    if (from === "" || path === "") continue
    if (path !== from && (delimiter === "" || path.indexOf(from + delimiter) !== 0)) continue
    if (to === "") return ""
    path = to + path.slice(from.length)
  }
  return path
}

function migrateMonitoredChanges(monitored, moves, after) {
  var ids = Array.isArray(monitored) ? monitored : []
  var now = Array.isArray(after) ? after : []
  var result = []
  for (var idIndex = 0; idIndex < ids.length; idIndex++) {
    var id = String(ids[idIndex] || "")
    if (id === "") continue
    if (indexById(now, id) >= 0) { result.push(id); continue }
    var path = pathAfterLabelMoves(id, moves)
    if (path === "") continue
    for (var labelIndex = 0; labelIndex < now.length; labelIndex++) {
      var label = now[labelIndex]
      var labelPath = label ? String(label.name || label.rawName || "") : ""
      var labelId = String(label && label.id || "")
      if (labelPath !== path || labelId === "") continue
      if (result.indexOf(labelId) < 0) result.push(labelId)
      break
    }
  }
  if (result.length !== ids.length) return result
  for (var comparisonIndex = 0; comparisonIndex < ids.length; comparisonIndex++)
    if (result[comparisonIndex] !== ids[comparisonIndex]) return result
  return ids
}

function monitoredNote(grown) {
  var list = Array.isArray(grown) ? grown.slice() : []
  if (list.length === 0) return ""
  list.sort(function(left, right) { return Number(right.delta || 0) - Number(left.delta || 0) })
  var parts = []
  for (var activityIndex = 0; activityIndex < list.length && activityIndex < 2; activityIndex++)
    parts.push(Math.max(1, Math.floor(Number(list[activityIndex].delta) || 1)) + " new in " + String(list[activityIndex].name || ""))
  var more = list.length - parts.length
  return parts.join(", ") + (more > 0 ? " and " + more + " more" : "")
}

function fuzzyScore(query, text) {
  var needle = String(query || "").toLowerCase().replace(/\s+/g, "")
  var hay = String(text || "").toLowerCase()
  if (needle === "") return 1
  if (hay === "") return 0
  var at = hay.indexOf(needle)
  if (at >= 0) return 1000 - at + (at === 0 || /[^a-z0-9]/.test(hay.charAt(at - 1)) ? 200 : 0)
  var score = 0
  var from = 0
  var last = -2
  for (var characterIndex = 0; characterIndex < needle.length; characterIndex++) {
    var found = hay.indexOf(needle.charAt(characterIndex), from)
    if (found < 0) return 0
    score += 10
    if (found === last + 1) score += 8
    if (found === 0 || /[^a-z0-9]/.test(hay.charAt(found - 1))) score += 12
    last = found
    from = found + 1
  }
  return score
}

// Invariant: sourceIndex preserves the original row identity; index is reserved for the Repeater delegate's displayed position.
function filterRows(rows, query) {
  var list = Array.isArray(rows) ? rows : []
  var typed = String(query || "").trim()
  var result = []
  for (var rowIndex = 0; rowIndex < list.length; rowIndex++) {
    var row = list[rowIndex]
    if (!row) continue
    var text = [row.name, row.label, row.email].filter(function(fieldValue) { return fieldValue !== undefined && fieldValue !== null && String(fieldValue) !== "" }).join(" ")
    var score = typed === "" ? 1 : fuzzyScore(typed, text)
    if (score <= 0) continue
    var kept = {}
    for (var key in row) kept[key] = row[key]
    kept.sourceIndex = rowIndex
    kept.score = score
    result.push(kept)
  }
  if (typed !== "") result.sort(function(left, right) { return right.score - left.score || left.sourceIndex - right.sourceIndex })
  return result
}

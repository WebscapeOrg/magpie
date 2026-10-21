.pragma library

.import "../../message/Message.js" as Mail

// Invariant: This test oracle models the rail; Rust owns the live conversation projection.

// Invariant: Zero members means unknown; a one-message conversation needs no rail.
var MINIMUM_MEMBERS = 2

// Performance: Retain recent summaries within a bounded cache; preserve visible members on reset.
var MAX_REMEMBERED = 500

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/^\s+|\s+$/g, "")
}

// Invariant: Cached rows can predate thread blocks, so absent blocks remain unknown.
function blockOf(value) {
  if (!value || typeof value !== "object") return null
  return Mail.normalizeThread(value, "")
}

// Invariant: Member labels take precedence over row flags, which can aggregate unread replies.
var FLAG_OF_LABEL = { UNREAD: "unread", STARRED: "starred" }

function memberHasLabel(summary, label) {
  if (!summary || typeof summary !== "object") return false
  var wanted = trimmed(label).toUpperCase()
  if (Array.isArray(summary.labelIds)) return summary.labelIds.indexOf(wanted) >= 0
  var flag = FLAG_OF_LABEL[wanted]
  return flag !== undefined && summary[flag] === true
}

function threadOfSummary(summary) {
  if (!summary || typeof summary !== "object") return null
  return blockOf(summary.thread)
}

function drawsRail(conversations, block) {
  if (conversations !== true) return false
  var thread = blockOf(block)
  return !!thread && thread.count >= MINIMUM_MEMBERS
}

function holdsMember(block, id) {
  var thread = blockOf(block)
  if (!thread) return false
  return thread.memberIds.indexOf(trimmed(id)) >= 0
}

// Invariant: A detail read can omit its thread block; keep the held thread when selecting one of its members.
function threadAfterSelect(current, id, summary) {
  if (holdsMember(current, id)) return current
  var block = threadOfSummary(summary)
  return block && block.count >= MINIMUM_MEMBERS ? block : null
}

// Invariant: Resetting the cache must retain visible members or their loaded stops become permanent skeletons.
function mergedSummaries(existing, additions, limit, kept) {
  var source = existing && typeof existing === "object" ? existing : {}
  var extra = additions && typeof additions === "object" ? additions : {}
  var cap = Math.floor(Number(limit))
  if (isFinite(cap) && cap > 0) {
    var held = 0
    for (var counted in source) {
      held = held + 1
      if (held >= cap) break
    }
    if (held >= cap) {
      var survivors = {}
      var ids = Array.isArray(kept) ? kept : []
      for (var memberIndex = 0; memberIndex < ids.length; memberIndex++) {
        var wanted = trimmed(ids[memberIndex])
        if (wanted !== "" && source[wanted]) survivors[wanted] = source[wanted]
      }
      source = survivors
    }
  }
  var output = {}
  for (var key in source) output[key] = source[key]
  for (var added in extra) {
    var id = trimmed(added)
    if (id !== "" && extra[added]) output[id] = extra[added]
  }
  return output
}

function summaryFor(summaries, id) {
  var store = summaries && typeof summaries === "object" ? summaries : {}
  var found = store[trimmed(id)]
  return found && typeof found === "object" ? found : null
}

// Invariant: Missing summaries retain member order so loading does not rearrange the rail.
function missingMemberIds(block, summaries) {
  var thread = blockOf(block)
  if (!thread) return []
  var output = []
  for (var itemIndex = 0; itemIndex < thread.memberIds.length; itemIndex++) {
    if (summaryFor(summaries, thread.memberIds[itemIndex])) continue
    output.push(thread.memberIds[itemIndex])
  }
  return output
}

// Invariant: Trash, Junk and Drafts take precedence when a message carries several mailbox labels.
var MAILBOX_OF_LABEL = [
  { label: "TRASH", key: "trash" },
  { label: "SPAM", key: "spam" },
  { label: "DRAFT", key: "drafts" },
  { label: "SENT", key: "sent" },
  { label: "INBOX", key: "inbox" }
]

// Invariant: Unknown membership stays unnamed instead of suggesting the wrong mailbox.
function mailboxKeyOf(summary) {
  var labels = summary && Array.isArray(summary.labelIds) ? summary.labelIds : []
  for (var itemIndex = 0; itemIndex < MAILBOX_OF_LABEL.length; itemIndex++) {
    if (labels.indexOf(MAILBOX_OF_LABEL[itemIndex].label) >= 0) return MAILBOX_OF_LABEL[itemIndex].key
  }
  return ""
}

// Invariant: Unread and Flagged are Inbox views; a search has no single viewed mailbox.
function viewedMailboxKey(mailboxKey, searching) {
  if (searching === true) return ""
  var key = trimmed(mailboxKey)
  if (key === "unread" || key === "starred") return "inbox"
  return key
}

function mailboxLabel(mailboxes, key) {
  var list = Array.isArray(mailboxes) ? mailboxes : []
  var wanted = trimmed(key)
  if (wanted === "") return ""
  for (var itemIndex = 0; itemIndex < list.length; itemIndex++) {
    if (list[itemIndex] && trimmed(list[itemIndex].key) === wanted) return String(list[itemIndex].label || "")
  }
  return ""
}

function mailboxNameFor(summary, viewKey, mailboxes) {
  var key = mailboxKeyOf(summary)
  if (key === "") return ""
  if (key === trimmed(viewKey)) return ""
  return mailboxLabel(mailboxes, key)
}

function senderOf(summary) {
  var from = summary && summary.from ? summary.from : null
  if (!from) return ""
  var display = trimmed(from.display)
  return display !== "" ? display : trimmed(from.email)
}

// Invariant: Thread member IDs arrive oldest first; the rail displays newest first.
function railOrder(thread) {
  var ids = thread.memberIds.slice()
  ids.reverse()
  return ids
}

// Invariant: Missing summaries retain their stop and order while the view displays a skeleton.
function stops(block, summaries, openId, viewKey, mailboxes) {
  var thread = blockOf(block)
  if (!thread) return []
  var open = trimmed(openId)
  var output = []
  var ids = railOrder(thread)
  for (var itemIndex = 0; itemIndex < ids.length; itemIndex++) {
    var id = ids[itemIndex]
    var summary = summaryFor(summaries, id)
    output.push({
      id: id,
      known: !!summary,
      open: id === open,
      sender: summary ? senderOf(summary) : "",
      time: summary ? String(summary.time || "") : "",
      fullTime: summary ? String(summary.fullTime || "") : "",
      unread: memberHasLabel(summary, "UNREAD"),
      flagged: memberHasLabel(summary, "STARRED"),
      mailbox: summary ? mailboxNameFor(summary, viewKey, mailboxes) : ""
    })
  }
  return output
}

function pluralize(count, singular, plural) {
  return String(count) + " " + (count === 1 ? singular : plural)
}

// Invariant: Total members are known immediately; the unread count includes only loaded summaries.
function caption(block, summaries) {
  var thread = blockOf(block)
  if (!thread || thread.count < MINIMUM_MEMBERS) return ""
  var unread = 0
  for (var itemIndex = 0; itemIndex < thread.memberIds.length; itemIndex++) {
    if (memberHasLabel(summaryFor(summaries, thread.memberIds[itemIndex]), "UNREAD"))
      unread = unread + 1
  }
  var text = pluralize(thread.count, "message", "messages")
  return unread > 0 ? text + " · " + unread + " unread" : text
}

// Invariant: Removing a member selects its newer neighbor, then its older neighbor, without wrapping.
function neighbourStop(block, memberId) {
  var thread = blockOf(block)
  if (!thread || thread.count === 0) return ""
  var ids = railOrder(thread)
  var index = ids.indexOf(trimmed(memberId))
  if (index < 0) return ""
  if (index > 0) return ids[index - 1]
  return ids.length > 1 ? ids[1] : ""
}

function memberStep(block, openId, delta) {
  var thread = blockOf(block)
  if (!thread || thread.count === 0) return ""
  var step = Math.floor(Number(delta) || 0)
  var ids = railOrder(thread)
  var index = ids.indexOf(trimmed(openId))
  // Invariant: When the selected member left the rail, movement starts at the end it came from.
  if (index < 0) return step < 0 ? ids[ids.length - 1] : ids[0]
  var next = index + step
  if (next < 0 || next > ids.length - 1) return ""
  return ids[next]
}

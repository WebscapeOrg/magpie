.pragma library

.import "../providers/Registry.js" as Provider

// Invariant: Unified mailbox controls use capabilities shared by every participating account.
function messageTime(item) {
  var value = item ? item.date : null
  if (value && typeof value.getTime === "function") return value.getTime()
  var numeric = Number(value)
  if (isFinite(numeric) && numeric > 0) return numeric
  var parsed = Date.parse(String(value || ""))
  if (isFinite(parsed) && parsed > 0) return parsed
  return Number(item && item.internalDate) || 0
}

// Invariant: Equal timestamps sort by account and message id to keep cursor order stable across refreshes.
function compareTiebreak(left, right) {
  var leftKey = String(left && left.accountId || "") + " " + String(left && left.id || "")
  var rightKey = String(right && right.accountId || "") + " " + String(right && right.id || "")
  return leftKey < rightKey ? -1 : (leftKey > rightKey ? 1 : 0)
}

// Performance: Read cross-engine Date values once per row; repeated conversion inside the comparator previously dominated merges.
function compareTimedRows(left, right) {
  var difference = right.at - left.at
  if (difference !== 0) return difference
  return compareTiebreak(left.row, right.row)
}

// Invariant: Composed ids use account plus U+001F plus provider id; spaces cannot delimit IMAP ids such as 42:Sent Items.
var ID_SEPARATOR = "\u001f"

function unifiedId(accountId, messageId) {
  var account = String(accountId === undefined || accountId === null ? "" : accountId)
  var id = String(messageId === undefined || messageId === null ? "" : messageId)
  if (account === "" || id === "") return ""
  return account + ID_SEPARATOR + id
}

function splitUnifiedId(value) {
  var text = String(value === undefined || value === null ? "" : value)
  var at = text.indexOf(ID_SEPARATOR)
  if (at <= 0) return { accountId: "", id: "" }
  return { accountId: text.substring(0, at), id: text.substring(at + 1) }
}

// Invariant: Stop at the shallowest incomplete source watermark so deeper sources cannot expose a chronological gap.
function pageWatermark(sources) {
  var values = Array.isArray(sources) ? sources : []
  var watermark = 0
  for (var accountIndex = 0; accountIndex < values.length; accountIndex++) {
    var source = values[accountIndex] || ({})
    var messages = Array.isArray(source.messages) ? source.messages : []
    if (messages.length === 0) continue
    if (source.hasMore !== true) continue
    var oldest = messageTime(messages[messages.length - 1])
    if (oldest > watermark) watermark = oldest
  }
  return watermark
}

// Invariant: Compose conversation member ids for routing, but retain the provider's thread id.
function composeThread(accountId, thread) {
  if (!thread || typeof thread !== "object") return thread
  if (!Array.isArray(thread.memberIds)) return thread
  var result = ({})
  for (var field in thread) result[field] = thread[field]
  var composed = []
  for (var memberIndex = 0; memberIndex < thread.memberIds.length; memberIndex++) {
    composed.push(unifiedId(accountId, thread.memberIds[memberIndex]))
  }
  result.memberIds = composed
  return result
}

// Invariant: Compose both summary map keys and each summary's id; actions use the latter.
function composeMembers(accountId, summaries) {
  var source = summaries && typeof summaries === "object" ? summaries : ({})
  var result = ({})
  for (var key in source) {
    var summary = source[key]
    var copy = summary
    if (summary && typeof summary === "object") {
      copy = ({})
      for (var field in summary) copy[field] = summary[field]
      copy.sourceId = String(summary.id || "")
      copy.id = unifiedId(accountId, summary.id)
      if (summary.thread) copy.thread = composeThread(accountId, summary.thread)
    }
    result[unifiedId(accountId, key)] = copy
  }
  return result
}

function mergeMessages(sources) {
  var values = Array.isArray(sources) ? sources : []
  var result = []
  var seen = ({})
  for (var sourceIndex = 0; sourceIndex < values.length; sourceIndex++) {
    var source = values[sourceIndex] || ({})
    var accountId = String(source.id || "")
    if (accountId === "") continue
    var messages = Array.isArray(source.messages) ? source.messages : []
    for (var messageIndex = 0; messageIndex < messages.length; messageIndex++) {
      var item = messages[messageIndex]
      if (!item || String(item.id || "") === "") continue
      // Invariant: A provider id is unique only inside its account.
      var key = unifiedId(accountId, item.id)
      if (seen[key] === true) continue
      seen[key] = true
      var copy = ({})
      for (var field in item) copy[field] = item[field]
      copy.sourceId = String(item.id)
      copy.id = key
      copy.accountId = accountId
      if (item.thread) copy.thread = composeThread(accountId, item.thread)
      copy.sourceLabel = String(source.label || "Mailbox")
      // Performance: Use the copied row fields instead of crossing the source engine boundary again.
      result.push({ at: messageTime(copy), row: copy })
    }
  }
  result.sort(compareTimedRows)
  var floor = pageWatermark(values)
  var rows = []
  for (var resultIndex = 0; resultIndex < result.length; resultIndex++) {
    if (floor > 0 && result[resultIndex].at < floor) break
    rows.push(result[resultIndex].row)
  }
  return rows
}

// Invariant: Decode routing from the id so an action still reaches its owner after its row leaves the visible list.
function accountOf(id) {
  return splitUnifiedId(id).accountId
}

function sourceIdOf(id) {
  return splitUnifiedId(id).id
}

function groupByAccount(ids) {
  var values = Array.isArray(ids) ? ids : []
  var groups = []
  var at = ({})
  for (var sourceIndex = 0; sourceIndex < values.length; sourceIndex++) {
    var parts = splitUnifiedId(values[sourceIndex])
    if (parts.accountId === "") continue
    if (!(parts.accountId in at)) {
      at[parts.accountId] = groups.length
      groups.push({ accountId: parts.accountId, ids: [] })
    }
    groups[at[parts.accountId]].ids.push(parts.id)
  }
  return groups
}

function rowOf(messages, id) {
  var values = Array.isArray(messages) ? messages : []
  var wanted = String(id === undefined || id === null ? "" : id)
  if (wanted === "") return null
  for (var sourceIndex = 0; sourceIndex < values.length; sourceIndex++) {
    if (String(values[sourceIndex] && values[sourceIndex].id || "") === wanted) return values[sourceIndex]
  }
  return null
}

function cursorOffset(messages, cursorId, delta) {
  var values = Array.isArray(messages) ? messages : []
  if (values.length === 0) return ""
  var step = Math.floor(Number(delta)) || 0
  var at = -1
  var wanted = String(cursorId === undefined || cursorId === null ? "" : cursorId)
  for (var sourceIndex = 0; sourceIndex < values.length; sourceIndex++) {
    if (String(values[sourceIndex] && values[sourceIndex].id || "") === wanted) {
      at = sourceIndex
      break
    }
  }
  if (at < 0) return String(values[step < 0 ? values.length - 1 : 0].id || "")
  var next = at + step
  if (next < 0 || next >= values.length) return ""
  return String(values[next].id || "")
}

// Invariant: Intersect live account capabilities and mailbox directories; provider defaults may offer folders the server lacks.
function everyMailboxCan(abilities, capability) {
  var rows = Array.isArray(abilities) ? abilities : []
  if (rows.length === 0) return false
  for (var sourceIndex = 0; sourceIndex < rows.length; sourceIndex++) {
    if (!rows[sourceIndex] || rows[sourceIndex][capability] !== true) return false
  }
  return true
}

function sharedMailboxRows(abilities) {
  var rows = Array.isArray(abilities) ? abilities : []
  if (rows.length === 0) return []
  var first = rowsOf(rows[0])
  var result = []
  for (var capabilityIndex = 0; capabilityIndex < first.length; capabilityIndex++) {
    var key = String(first[capabilityIndex].key || "")
    if (key === "") continue
    var everyone = true
    for (var sourceIndex = 1; sourceIndex < rows.length; sourceIndex++) {
      if (!holdsMailbox(rows[sourceIndex], key)) {
        everyone = false
        break
      }
    }
    if (everyone) result.push(first[capabilityIndex])
  }
  return result
}

function rowsOf(row) {
  return row && Array.isArray(row.mailboxes) ? row.mailboxes : []
}

function holdsMailbox(row, key) {
  var list = rowsOf(row)
  for (var sourceIndex = 0; sourceIndex < list.length; sourceIndex++) {
    if (String(list[sourceIndex].key || "") === key) return true
  }
  return false
}





function totalUnread(summaries) {
  var values = Array.isArray(summaries) ? summaries : []
  var total = 0
  for (var sourceIndex = 0; sourceIndex < values.length; sourceIndex++) {
    var count = Math.floor(Number(values[sourceIndex] && values[sourceIndex].unread))
    if (isFinite(count) && count > 0) total += count
  }
  return total
}

function anyLoading(states) {
  var values = Array.isArray(states) ? states : []
  for (var sourceIndex = 0; sourceIndex < values.length; sourceIndex++) {
    if (values[sourceIndex] && values[sourceIndex].loading === true) return true
  }
  return false
}

function anyServerSearchLoading(states) {
  var values = Array.isArray(states) ? states : []
  for (var sourceIndex = 0; sourceIndex < values.length; sourceIndex++) {
    if (values[sourceIndex] && values[sourceIndex].serverSearchLoading === true) return true
  }
  return false
}

function rowIsConversation(row) {
  var thread = row && row.thread
  return !!thread && Number(thread.count) >= 2
}

// Invariant: A settled error ends loading even without a loaded flag; an account still retrying remains busy.
function allLoaded(states) {
  var values = Array.isArray(states) ? states : []
  if (values.length === 0) return false
  for (var sourceIndex = 0; sourceIndex < values.length; sourceIndex++) {
    var state = values[sourceIndex]
    if (!state) return false
    if (state.loaded === true) continue
    if (state.loading !== true && String(state.error || "").trim() !== "") continue
    return false
  }
  return true
}

function anyHasMore(states) {
  var values = Array.isArray(states) ? states : []
  for (var sourceIndex = 0; sourceIndex < values.length; sourceIndex++) {
    if (values[sourceIndex] && values[sourceIndex].hasMore === true) return true
  }
  return false
}

function firstError(states) {
  var values = Array.isArray(states) ? states : []
  for (var sourceIndex = 0; sourceIndex < values.length; sourceIndex++) {
    var state = values[sourceIndex] || ({})
    var text = String(state.error || "").trim()
    if (text === "") continue
    var label = String(state.label || "").trim()
    return label === "" ? text : label + ": " + text
  }
  return ""
}

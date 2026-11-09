.pragma library
.import "../account/Unified.js" as Unified

// Dave's one Point for mails that are really one Point (Q-019, Q-020, C-073). The engine decides
// the bundles; this file only shapes rows for the Inbox.
// Invariant: Archive, Trash, Snooze and read state on a bundled row reach every mail in it (Q-020);
// Report spam and Move to label stay on the mail Dave pressed them on. Every id named here came from
// the engine's answer for the same account as the row it is attached to.

var EXPANDING = ["archive", "trash", "markRead", "markUnread"]
var UNDOABLE = ["archive", "trash", "snooze"]

function expandsAction(action) { return EXPANDING.indexOf(String(action || "")) >= 0 }

function undoable(action) { return UNDOABLE.indexOf(String(action || "")) >= 0 }

function plural(count) { return count + " message" + (count === 1 ? "" : "s") }

// The toast's words, in Q-020's "Archived 2 messages" form.
function actionText(action, count) {
  if (action === "archive") return "Archived " + plural(count)
  if (action === "trash") return "Moved " + plural(count) + " to trash"
  if (action === "snooze") return "Snoozed " + plural(count)
  return plural(count)
}

// Undo can only take back a change still waiting to sync. Past that, say so and say what to do.
function whereToFind(action, these) {
  return action === "trash" ? "Find " + these + " in Trash and restore " + these + "."
    : action === "archive" ? "Find " + these + " in All mail and choose Move to Inbox."
    : action === "snooze" ? "Find " + these + " under Snoozed mail."
    : ""
}

function pronoun(mails, total) { return (Number(mails) > 0 ? Number(mails) : total) === 1 ? "it" : "them" }

function undoFailedText(action, total, mails) {
  return "Undo could not finish. " + whereToFind(action, pronoun(mails, total))
}

function refusalText(action, refused, total, mails) {
  var these = pronoun(mails, total)
  var where = whereToFind(action, these)
  if (refused >= total)
    return "Gmail already has this change, so Undo can't bring " + these + " back. " + where
  return refused + " of " + total + " had already reached Gmail, so they stayed. " + where
}

function sourceId(row) { return String(row.sourceId || row.id || "") }

function memberRowId(row, account, id) { return row.sourceId ? Unified.unifiedId(account, id) : String(id) }

function indexState(state) {
  var fronts = {}, covers = {}, proposals = {}
  var bundles = state && Array.isArray(state.bundles) ? state.bundles : []
  for (var bundleIndex = 0; bundleIndex < bundles.length; bundleIndex++) {
    var bundle = bundles[bundleIndex], front = String(bundle.front || "")
    var covered = Array.isArray(bundle.covered) ? bundle.covered.map(String) : []
    if (front === "" || covered.length === 0) continue
    fronts[front] = covered
    for (var coveredIndex = 0; coveredIndex < covered.length; coveredIndex++) covers[covered[coveredIndex]] = front
  }
  var offers = state && Array.isArray(state.proposals) ? state.proposals : []
  for (var offerIndex = 0; offerIndex < offers.length; offerIndex++) {
    var offer = offers[offerIndex], newer = String(offer.front || "")
    if (newer === "" || !Array.isArray(offer.covered) || offer.covered.length === 0) continue
    proposals[newer] = {covered: offer.covered.map(String), sender: offer.sender || {}}
  }
  return {fronts: fronts, covers: covers, proposals: proposals}
}

function hasAny(states) {
  for (var account in states) {
    var state = states[account]
    if (state && ((Array.isArray(state.bundles) && state.bundles.length) || (Array.isArray(state.proposals) && state.proposals.length))) return true
  }
  return false
}

// Shapes the Inbox's rows: covered mail is left out, a front row carries bundleCount, bundleIds and
// an unread state taken from every mail in it, and a newer row with a waiting proposal carries
// bundleProposal. The raw rows are never changed, so every other view keeps one row per mail.
function project(rows, states, accountOf, summaryOf) {
  var empty = {rows: rows, groups: {}, proposals: {}}
  if (!hasAny(states)) return empty
  var indexes = {}, loaded = {}
  function indexFor(account) {
    if (!indexes[account]) indexes[account] = indexState(states[account])
    return indexes[account]
  }
  function key(account, id) { return account + "\n" + id }
  for (var loadIndex = 0; loadIndex < rows.length; loadIndex++) {
    var owner = accountOf(rows[loadIndex])
    if (owner !== "") loaded[key(owner, sourceId(rows[loadIndex]))] = rows[loadIndex]
  }
  function summary(account, id) { return loaded[key(account, id)] || summaryOf(account, id) || null }
  var out = [], groups = {}, proposals = {}
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    var row = rows[rowIndex], account = accountOf(row), id = sourceId(row)
    if (account === "") { out.push(row); continue }
    var index = indexFor(account), coveredBy = index.covers[id]
    // Invariant: a covered mail hides only while its front row is on screen to stand for it.
    if (coveredBy !== undefined && loaded[key(account, coveredBy)]) continue
    var covered = index.fronts[id]
    if (covered) {
      var unread = row.unread === true
      var memberIds = []
      var members = [{id: row.id, sourceId: id, summary: row}]
      for (var memberIndex = 0; memberIndex < covered.length; memberIndex++) {
        var memberId = memberRowId(row, account, covered[memberIndex])
        var known = summary(account, covered[memberIndex])
        memberIds.push(memberId)
        members.push({id: memberId, sourceId: covered[memberIndex], summary: known})
        unread = unread || (known !== null && known.unread === true)
      }
      var group = {accountId: account, frontId: row.id, frontSource: id, covered: covered, memberIds: memberIds, members: members}
      groups[row.id] = group
      for (var groupIndex = 0; groupIndex < memberIds.length; groupIndex++) groups[memberIds[groupIndex]] = group
      out.push(Object.assign({}, row, {unread: unread, bundleCount: covered.length + 1, bundleIds: memberIds}))
      continue
    }
    var offer = index.proposals[id]
    if (offer) {
      proposals[row.id] = {accountId: account, front: id, covered: offer.covered, sender: offer.sender}
      out.push(Object.assign({}, row, {bundleProposal: true}))
      continue
    }
    out.push(row)
  }
  return {rows: out, groups: groups, proposals: proposals}
}

// The ids an action should reach. Selecting or acting on a bundled row means every mail in it.
function plan(ids, action, groups) {
  var expanded = [], frontOf = {}, bundled = false
  function add(id) { if (expanded.indexOf(id) < 0) expanded.push(id) }
  for (var idIndex = 0; idIndex < ids.length; idIndex++) {
    var id = String(ids[idIndex])
    var group = expandsAction(action) ? groups[id] : null
    add(id)
    if (!group || group.frontId !== id) continue
    bundled = true
    for (var memberIndex = 0; memberIndex < group.memberIds.length; memberIndex++) {
      add(group.memberIds[memberIndex])
      frontOf[group.memberIds[memberIndex]] = id
    }
  }
  return {ids: expanded, frontOf: frontOf, bundled: bundled}
}

// A failed older mail stands behind its front row while that row is still there. If the front itself
// went, the older mail comes back as its own row and keeps its own id.
function mapFailed(failedIds, frontOf) {
  var ids = Array.isArray(failedIds) ? failedIds.map(String) : []
  var mapped = []
  for (var index = 0; index < ids.length; index++) {
    var front = frontOf[ids[index]]
    var id = front && ids.indexOf(front) >= 0 ? front : ids[index]
    if (mapped.indexOf(id) < 0) mapped.push(id)
  }
  return mapped
}

// The reader's "Also in this Point": the other mails by sender, time and subject, never their
// Points. Ids the engine named but whose summary has not arrived yet show the rail's loading bars.
function readerStops(group, openId) {
  if (!group) return []
  var stops = []
  for (var index = 0; index < group.members.length; index++) {
    var member = group.members[index]
    if (String(member.id) === String(openId)) continue
    var row = member.summary
    stops.push({id: member.id, known: !!row, open: false, flagged: false, mailbox: "",
      sender: row && row.from ? String(row.from.display || row.from.email || "") : "",
      time: row ? String(row.time || "") : "",
      subject: row ? String(row.subject || "") : "",
      unread: !!row && row.unread === true})
  }
  return stops
}

// Mail that must be marked read when its bundled row opens.
function unreadCovered(group) {
  if (!group) return []
  return group.members.filter(function(member) { return member.id !== group.frontId && member.summary && member.summary.unread === true })
    .map(function(member) { return member.id })
}

function chunks(ids, size) {
  var parts = []
  for (var start = 0; start < ids.length; start += size) parts.push(ids.slice(start, start + size))
  return parts
}

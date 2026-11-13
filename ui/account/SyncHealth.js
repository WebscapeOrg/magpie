.pragma library

// What Magpie on Linux says about mail sync, with the rules and words of Magpie for iPhone
// (MagpieCore SyncHealth and MailSyncStatus), so both say the same thing. The counts come from
// local.status. Progress belongs in Settings; only a problem goes above the Inbox (Q-011).
// Invariant: a problem Magpie retries by itself (TEMPORARY, or downloads that failed) is shown only
// after it has lasted ten minutes without progress, so a passing blip never reaches the Inbox.

var TEMPORARY = ["gmail_rate_limited", "gmail_server_rate_limited", "gmail_request_deferred",
  "gmail_http_failed", "gmail_timeout"]
var LASTING = 600000
var CURRENT = 120000
var FRESH = 120000

function whole(value) {
  var number = typeof value === "number" ? value
    : typeof value === "string" && /^[0-9]{1,16}$/.test(value) ? Number(value) : NaN
  return isFinite(number) && number >= 0 && Math.floor(number) === number ? number : null
}

// Counts read as on the iPhone, with thousands separated: "4,599 messages".
function group(count) {
  return String(count).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

function messages(count) {
  return group(count) + (count === 1 ? " message" : " messages")
}

function code(status) {
  return status && typeof status.error === "string" ? status.error : ""
}

function temporary(status) {
  return TEMPORARY.indexOf(code(status)) >= 0
}

function paused(status) {
  return !!status && status.paused === true
}

function progress(status) {
  var value = status ? whole(status.updated) : null
  return value === null ? null : value
}

function step(previous, mark, now) {
  if (!previous || !(previous.began <= now) || previous.progress !== mark || !current(previous, now))
    return { began: now, progress: mark, observed: now }
  return { began: previous.began, progress: previous.progress, observed: now }
}

function current(episode, now) {
  return !!episode && now - episode.observed >= 0 && now - episode.observed <= CURRENT
}

function lasting(episode, now) {
  return current(episode, now) && now - episode.began >= LASTING
}

// The warnings state after seeing status at now. A paused account has none.
function observe(previous, status, now) {
  var before = previous || {}
  if (paused(status)) return { episode: null, downloads: null }
  return {
    episode: temporary(status) ? step(before.episode, progress(status), now) : null,
    downloads: whole(status && status.failed) > 0 ? step(before.downloads, null, now) : null
  }
}

function errorText(error) {
  if (disk(error))
    return "Downloads paused: free at least 1 GB of disk space. Saved mail is available."
  if (signIn(error))
    return "Sign in to Gmail again to resume syncing. Saved mail and queued changes are kept."
  return "Downloads are waiting for Gmail. Saved mail is available."
}

function stalledText(error) {
  if (error === "gmail_request_deferred")
    return "Mail sync has stalled. New mail may be delayed. Magpie Mail will keep trying."
  if (error === "gmail_rate_limited" || error === "gmail_server_rate_limited")
    return "Google is still limiting mail requests. New mail may be delayed. Magpie Mail will keep trying."
  return "Magpie Mail still cannot reach Gmail. New mail may be delayed. Check your connection; Magpie Mail will keep trying."
}

function signIn(error) {
  return error === "gmail_unauthorized" || error === "gmail_invalid_token"
}

function disk(error) {
  return error === "local_disk_low" || error === "local_disk_full"
}

// The sync problem to show above the Inbox, or "" when there is none.
// Invariant: a paused account still sends its queued changes (sync.rs step), so an error that is not
// temporary is theirs and is shown; pausing does not hide it, on the iPhone either.
function problem(status, warnings, now) {
  if (!status) return ""
  var error = code(status)
  var state = warnings || {}
  if (paused(status)) {
    if (error === "" || temporary(status)) return ""
    if (signIn(error) || disk(error)) return errorText(error)
    // Without a queued change the error is a download's from just before pausing, cleared by the next step.
    return whole(status.pendingEdits) > 0
      ? "A mailbox change could not reach Gmail. Magpie Mail will keep trying while sync is paused." : ""
  }
  if (error !== "" && !temporary(status)) return errorText(error)
  if (error !== "" && lasting(state.episode, now)) return stalledText(error)
  if (whole(status.failed) > 0 && lasting(state.downloads, now))
    return "Some mail downloads are still failing. Magpie Mail will keep trying."
  return ""
}

function conflicts(status) {
  return status ? whole(status.editConflicts) || 0 : 0
}

function health(status) {
  return status && status.health && typeof status.health === "object" ? status.health : {}
}

function checked(status, now) {
  var value = whole(health(status).lastChecked)
  return value !== null && value > 0 && value <= now ? value : null
}

function fresh(status, now) {
  var value = checked(status, now)
  return value !== null && now - value <= FRESH
}

function lastChecked(status, now) {
  var value = checked(status, now)
  if (value === null) return "Not yet checked"
  var age = (now - value) / 1000
  if (age < 60) return "Moments ago"
  if (age < 3600) { var minutes = Math.floor(age / 60); return minutes + (minutes === 1 ? " minute ago" : " minutes ago") }
  if (age < 86400) { var hours = Math.floor(age / 3600); return hours + (hours === 1 ? " hour ago" : " hours ago") }
  var days = Math.floor(age / 86400)
  return days + (days === 1 ? " day ago" : " days ago")
}

function summary(status, warning, unavailable, now) {
  if (warning !== "" || conflicts(status) > 0) return "Needs attention"
  if (paused(status)) return "Sync paused"
  if (unavailable) return "Status unavailable"
  if (!fresh(status, now)) return checked(status, now) === null ? "Checking Gmail…" : "Waiting for a fresh check"
  if (health(status).inboxKnown !== true) return "Checking your inbox…"
  return "Everything is working"
}

function inbox(status, now) {
  var counts = health(status)
  if (counts.inboxKnown !== true) return "Checking…"
  if (!fresh(status, now) || paused(status)) return "Waiting for a fresh check"
  if (counts.inboxComplete === true) return "Fully updated"
  var missing = whole(counts.inboxMissing)
  if (missing !== null && missing > 0) return messages(missing) + " still downloading"
  return "Updating…"
}

function otherMail(status, now) {
  var remaining = whole(health(status).otherMissing)
  if (remaining === null) return "Checking how much is left…"
  var live = fresh(status, now) && !paused(status)
  if (remaining === 0) return live ? "Fully downloaded" : "Downloaded through the last check"
  return messages(remaining) + (live ? " still downloading" : " left to download")
}

function changes(status) {
  var waiting = status ? whole(status.pendingEdits) || 0 : 0
  var failed = conflicts(status)
  var parts = []
  if (waiting > 0) parts.push(group(waiting) + " waiting to sync")
  if (failed > 0) parts.push(group(failed) + " could not sync")
  return parts.length > 0 ? parts.join(", ") : "All synced"
}

// What an empty mailbox says while Magpie is still finding mail, as on the iPhone: "" while a
// problem is shown above it, and null when the usual empty text applies.
function emptyText(status, warning) {
  if (!status) return null
  if (warning !== "") return ""
  if (paused(status)) return "Sync is paused. Resume it in Settings → Mailboxes."
  if (temporary(status)) return "Checking for mail. Saved messages will appear here."
  if (status.inventoryComplete !== true && code(status) === "") return "Checking Gmail…"
  return null
}

// The empty text for a mailbox read from the offline copy, or null when the usual text applies.
function emptyFor(mailbox, searching, loading) {
  if (!mailbox || mailbox.available !== true || searching || loading) return null
  return emptyText(mailbox.status, mailbox.error !== "" ? mailbox.error : mailbox.problem)
}

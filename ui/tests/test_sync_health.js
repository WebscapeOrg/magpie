const assert = require("assert")
const { load } = require("./load")

const sync = load("account/SyncHealth.js")
const minute = 60000
const start = 1793700000000

// Routine work is never a problem: a download in progress, queued changes, mail that cannot be saved.
const routine = { complete: false, inventoryComplete: true, pending: 4, pendingEdits: 2, unsaved: 1, textComplete: 5030, estimatedTotal: 4599 }
assert.strictEqual(sync.problem(routine, sync.observe(null, routine, start), start), "")

// A problem only Dave can solve shows at once.
const changeFailed = "A mailbox change could not reach Gmail. Magpie Mail will keep trying while sync is paused."
for (const [code, text, whilePaused] of [
  ["gmail_unauthorized", "Sign in to Gmail again to resume syncing. Saved mail and queued changes are kept."],
  ["gmail_invalid_token", "Sign in to Gmail again to resume syncing. Saved mail and queued changes are kept."],
  ["local_disk_low", "Downloads paused: free at least 1 GB of disk space. Saved mail is available."],
  ["local_disk_full", "Downloads paused: free at least 1 GB of disk space. Saved mail is available."],
  ["gmail_forbidden", "Downloads are waiting for Gmail. Saved mail is available.", changeFailed]
]) {
  const status = { error: code, updated: "1" }
  assert.strictEqual(sync.problem(status, sync.observe(null, status, start), start), text, code)
  // A paused account still sends its queued changes, so their error still shows.
  const paused = { error: code, paused: true, pendingEdits: 1 }
  assert.strictEqual(sync.problem(paused, sync.observe(null, paused, start), start), whilePaused || text, code + " while paused")
  assert.strictEqual(sync.summary(paused, sync.problem(paused, null, start), false, start), "Needs attention", code + " summary while paused")
  assert.strictEqual(sync.emptyFor({ available: true, status: paused, error: "", problem: sync.problem(paused, null, start) }, false, false), "",
    code + " empty text while paused")
}
// A download's error from just before pausing is not blamed on a change when none is queued.
for (const code of ["gmail_invalid_response", "gmail_forbidden"]) {
  for (const paused of [{ paused: true, error: code, pendingEdits: 0 }, { paused: true, error: code }]) {
    assert.strictEqual(sync.problem(paused, null, start), "", code + " while paused with nothing queued")
    assert.strictEqual(sync.summary(paused, sync.problem(paused, null, start), false, start), "Sync paused", code + " summary with nothing queued")
  }
}
assert.strictEqual(sync.problem({ paused: true, error: "gmail_unauthorized", pendingEdits: 0 }, null, start),
  "Sign in to Gmail again to resume syncing. Saved mail and queued changes are kept.", "sign-in still shows with nothing queued")
// A passing limit while paused is not shown; pausing is not a problem.
assert.strictEqual(sync.problem({ paused: true, error: "gmail_rate_limited" }, null, start), "")
assert.strictEqual(sync.problem({ paused: true, error: "" }, null, start), "")

// A problem Magpie retries by itself shows only after ten minutes without progress.
function watch(statuses, step) {
  let warnings = null
  let now = start
  for (const status of statuses) { warnings = sync.observe(warnings, status, now); now += step }
  return { warnings, now: now - step }
}
for (const [code, text] of [
  ["gmail_request_deferred", "Mail sync has stalled. New mail may be delayed. Magpie Mail will keep trying."],
  ["gmail_rate_limited", "Google is still limiting mail requests. New mail may be delayed. Magpie Mail will keep trying."],
  ["gmail_server_rate_limited", "Google is still limiting mail requests. New mail may be delayed. Magpie Mail will keep trying."],
  ["gmail_http_failed", "Magpie Mail still cannot reach Gmail. New mail may be delayed. Check your connection; Magpie Mail will keep trying."],
  ["gmail_timeout", "Magpie Mail still cannot reach Gmail. New mail may be delayed. Check your connection; Magpie Mail will keep trying."]
]) {
  const stuck = { error: code, updated: "100" }
  const early = watch(Array(20).fill(stuck), 30000)
  assert.strictEqual(sync.problem(stuck, early.warnings, early.now), "", code + " after 9.5 minutes")
  const late = watch(Array(21).fill(stuck), 30000)
  assert.strictEqual(sync.problem(stuck, late.warnings, late.now), text, code + " after 10 minutes")
  // Progress (a new updated time) starts the ten minutes again.
  const moving = watch(Array.from({ length: 40 }, (_, index) => ({ error: code, updated: String(100 + Math.floor(index / 10)) })), 30000)
  assert.strictEqual(sync.problem({ error: code, updated: "103" }, moving.warnings, moving.now), "", code + " while progressing")
}
// A gap of more than two minutes (the computer slept) starts the ten minutes again.
{
  const stuck = { error: "gmail_timeout", updated: "7" }
  let warnings = sync.observe(null, stuck, start)
  warnings = sync.observe(warnings, stuck, start + 3 * minute)
  warnings = sync.observe(warnings, stuck, start + 11 * minute)
  assert.strictEqual(sync.problem(stuck, warnings, start + 11 * minute), "")
  // An observation older than two minutes is not current, so nothing shows from it.
  const steady = watch(Array(21).fill(stuck), 30000)
  assert.strictEqual(sync.problem(stuck, steady.warnings, steady.now + 3 * minute), "")
}
// Failed downloads show after ten minutes, and pausing clears them.
{
  const failing = { failed: 3, updated: "1" }
  const early = watch(Array(20).fill(failing), 30000)
  assert.strictEqual(sync.problem(failing, early.warnings, early.now), "")
  const late = watch(Array(21).fill(failing), 30000)
  assert.strictEqual(sync.problem(failing, late.warnings, late.now), "Some mail downloads are still failing. Magpie Mail will keep trying.")
  const paused = sync.observe(late.warnings, { failed: 3, paused: true }, late.now + 1000)
  assert.deepStrictEqual({ ...paused }, { episode: null, downloads: null })
  const cleared = sync.observe(late.warnings, { failed: 0 }, late.now + 1000)
  assert.strictEqual(cleared.downloads, null)
}
// Counts that are not whole numbers are ignored.
assert.strictEqual(sync.whole("12"), 12)
assert.strictEqual(sync.whole(12), 12)
for (const bad of [null, undefined, "", "1.5", "-1", "x", true, 1.5, -2, Infinity, "99999999999999999"]) assert.strictEqual(sync.whole(bad), null, String(bad))

// Settings wording, as on the iPhone.
const now = start
const healthy = { inventoryComplete: true, pendingEdits: 0, editConflicts: 0,
  health: { lastChecked: now - 5000, inboxKnown: true, inboxComplete: true, inboxMissing: 0, otherMissing: 0 } }
assert.strictEqual(sync.summary(healthy, "", false, now), "Everything is working")
assert.strictEqual(sync.lastChecked(healthy, now), "Moments ago")
assert.strictEqual(sync.inbox(healthy, now), "Fully updated")
assert.strictEqual(sync.otherMail(healthy, now), "Fully downloaded")
assert.strictEqual(sync.changes(healthy), "All synced")
assert.strictEqual(sync.summary({ ...healthy, paused: true }, "", false, now), "Sync paused")
assert.strictEqual(sync.summary(healthy, "Some mail downloads are still failing. Magpie Mail will keep trying.", false, now), "Needs attention")
assert.strictEqual(sync.summary({ ...healthy, editConflicts: 1 }, "", false, now), "Needs attention")
assert.strictEqual(sync.summary({}, "", false, now), "Checking Gmail…")
assert.strictEqual(sync.lastChecked({}, now), "Not yet checked")
const stale = { ...healthy, health: { ...healthy.health, lastChecked: now - 5 * minute } }
assert.strictEqual(sync.summary(stale, "", false, now), "Waiting for a fresh check")
assert.strictEqual(sync.lastChecked(stale, now), "5 minutes ago")
assert.strictEqual(sync.lastChecked({ health: { lastChecked: now - minute } }, now), "1 minute ago")
assert.strictEqual(sync.lastChecked({ health: { lastChecked: now - 3 * 3600000 } }, now), "3 hours ago")
assert.strictEqual(sync.lastChecked({ health: { lastChecked: now - 86400000 } }, now), "1 day ago")
assert.strictEqual(sync.lastChecked({ health: { lastChecked: now + minute } }, now), "Not yet checked", "a time in the future")
assert.strictEqual(sync.inbox(stale, now), "Waiting for a fresh check")
assert.strictEqual(sync.otherMail(stale, now), "Downloaded through the last check")
const downloading = { ...healthy, health: { ...healthy.health, inboxComplete: false, inboxMissing: 12, otherMissing: 431 } }
assert.strictEqual(sync.inbox(downloading, now), "12 messages still downloading")
assert.strictEqual(sync.otherMail(downloading, now), "431 messages still downloading")
assert.strictEqual(sync.otherMail({ ...downloading, paused: true }, now), "431 messages left to download")
assert.strictEqual(sync.inbox({ health: { inboxKnown: false } }, now), "Checking…")
assert.strictEqual(sync.inbox({ ...healthy, health: { ...healthy.health, inboxComplete: false, inboxMissing: 0 } }, now), "Updating…")
assert.strictEqual(sync.otherMail({ health: { otherMissing: null } }, now), "Checking how much is left…")
assert.strictEqual(sync.summary({ ...healthy, health: { ...healthy.health, inboxKnown: false } }, "", false, now), "Checking your inbox…")
assert.strictEqual(sync.changes({ pendingEdits: 2, editConflicts: 1 }), "2 waiting to sync, 1 could not sync")
assert.strictEqual(sync.changes({ pendingEdits: 1 }), "1 waiting to sync")
assert.strictEqual(sync.changes({ pendingEdits: 1200 }), "1,200 waiting to sync")
assert.strictEqual(sync.otherMail({ ...downloading, health: { ...downloading.health, otherMissing: 4599 } }, now), "4,599 messages still downloading")
// The old estimate is never shown: nothing here reads estimatedTotal.
assert.ok(!/about/.test(sync.otherMail({ ...downloading, estimatedTotal: 4599 }, now)))

// An empty mailbox says why, as on the iPhone; null keeps the usual text.
const mailbox = (status, extra) => ({ available: true, status, error: "", problem: "", ...extra })
assert.strictEqual(sync.emptyFor(mailbox({ paused: true }), false, false), "Sync is paused. Resume it in Settings → Mailboxes.")
assert.strictEqual(sync.emptyFor(mailbox({ error: "gmail_rate_limited" }), false, false), "Checking for mail. Saved messages will appear here.")
assert.strictEqual(sync.emptyFor(mailbox({ inventoryComplete: false, error: "" }), false, false), "Checking Gmail…")
assert.strictEqual(sync.emptyFor(mailbox({ inventoryComplete: true, error: "" }), false, false), null)
assert.strictEqual(sync.emptyFor(mailbox({ inventoryComplete: false }, { problem: "Some mail downloads are still failing. Magpie Mail will keep trying." }), false, false), "", "the problem above says it")
assert.strictEqual(sync.emptyFor(mailbox({ paused: true }), true, false), null, "searching keeps the search text")
assert.strictEqual(sync.emptyFor(mailbox({ paused: true }), false, true), null, "loading keeps its text")
assert.strictEqual(sync.emptyFor(null, false, false), null)
assert.strictEqual(sync.emptyFor(mailbox({ paused: true }, { available: false }), false, false), null)

console.log("sync health tests passed")

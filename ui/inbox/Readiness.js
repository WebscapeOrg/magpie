.pragma library
// The longest Point a row may show, in characters; the engine's POINT_LIMIT in src/inbox/mod.rs.
var POINT_LIMIT = 300
function ready(value, at) {
  if (!value || value.version !== 2 || value.state !== "ready" || typeof value.text !== "string") return false
  if (value.text.trim() === "" || Array.from(value.text).length > POINT_LIMIT || /[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff<>]/.test(value.text)) return false
  return typeof value.expiresAt === "number" && isFinite(value.expiresAt) && Math.floor(value.expiresAt) === value.expiresAt && value.expiresAt <= 9007199254740991 && (value.expiresAt === 0 || value.expiresAt > at)
}
// Codes an unfinished row keeps when something other than the message holds it up; the engine's
// ROW_PROBLEMS in src/inbox/mod.rs. Every Claude subscription being out holds every Point; the
// others mean Claude or Magpie's AI worker did not answer this time.
var SUBSCRIPTIONS_OUT = "overview_ai_paused"
var UNANSWERED = ["overview_ai_unavailable", "overview_start_failed", "ai_rate_limited", "ai_unavailable", "ai_unreachable"]
function problem(value) {
  var code = value && typeof value.problem === "string" ? value.problem : ""
  return code === SUBSCRIPTIONS_OUT || UNANSWERED.indexOf(code) >= 0 ? code : ""
}
// How an Inbox row shows its Point: "ready", "writing" (moving lines while Magpie writes it) or
// "plain" (subject and preview), once the message's own attempt failed or while a lasting problem
// holds every Point. Magpie asks again quietly, and the Point fades in if it works.
function status(value, at, held) {
  if (ready(value, at)) return "ready"
  if (held || failedOnItsOwn(value)) return "plain"
  return value && value.state === "failed" && problem(value) === "" ? "plain" : "writing"
}
function failedOnItsOwn(value) { return !!value && typeof value.attempts === "number" && value.attempts >= 1 }
// "25 minutes", "2 hours", "1 hour 5 minutes": how long Claude has not answered.
function waited(ms) {
  var minutes = Math.max(1, Math.floor(ms / 60000))
  function count(n, unit) { return n + " " + unit + (n === 1 ? "" : "s") }
  if (minutes < 60) return count(minutes, "minute")
  var hours = Math.floor(minutes / 60), rest = minutes % 60
  return rest ? count(hours, "hour") + " " + count(rest, "minute") : count(hours, "hour")
}

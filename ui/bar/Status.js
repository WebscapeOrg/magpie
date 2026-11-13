.pragma library

var MAX_TEXT_LENGTH = 4096
var MAX_AGE_MS = 45000
var MAX_FUTURE_MS = 5000
var MAX_UNREAD = 1000000

function snapshot(text, nowMs) {
  if (typeof text !== "string" || text.length > MAX_TEXT_LENGTH) return null
  if (typeof nowMs !== "number" || !isFinite(nowMs)) return null

  var value
  try { value = JSON.parse(text) } catch (error) { return null }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  if (typeof value.ready !== "boolean" || typeof value.windowOpen !== "boolean"
      || typeof value.showBarIcon !== "boolean") return null
  if (typeof value.unreadTotal !== "number" || !isFinite(value.unreadTotal)
      || Math.floor(value.unreadTotal) !== value.unreadTotal
      || value.unreadTotal < 0 || value.unreadTotal > MAX_UNREAD) return null
  if (typeof value.updated !== "number" || !isFinite(value.updated)
      || Math.floor(value.updated) !== value.updated || value.updated < 0) return null
  if (value.updated > nowMs + MAX_FUTURE_MS || nowMs - value.updated > MAX_AGE_MS) return null

  return {
    ready: value.ready,
    windowOpen: value.windowOpen,
    showBarIcon: value.showBarIcon,
    unreadTotal: value.unreadTotal,
    updated: value.updated
  }
}

function displayCount(unreadTotal) {
  if (typeof unreadTotal !== "number" || !isFinite(unreadTotal) || unreadTotal <= 0) return ""
  if (unreadTotal > 999) return "999+"
  return String(unreadTotal)
}

function tooltip(status, launchFailed) {
  if (launchFailed) return "Magpie Mail could not open. Click to try again."
  if (!status || !status.ready) return "Open Magpie Mail"
  if (status.unreadTotal === 0) return "Open Magpie Mail · No unread mail"
  var suffix = status.unreadTotal === 1 ? "1 unread message"
    : String(status.unreadTotal) + " unread messages"
  return "Open Magpie Mail · " + suffix
}

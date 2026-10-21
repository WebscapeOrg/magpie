.pragma library

.import "../message/Html.js" as Html

function messageTime(item) {
  var value = item ? item.date : null
  if (value && typeof value.getTime === "function") return value.getTime()
  var numeric = Number(value)
  if (isFinite(numeric) && numeric > 0) return numeric
  var parsed = Date.parse(String(value || ""))
  if (isFinite(parsed) && parsed > 0) return parsed
  return Number(item && item.internalDate) || 0
}

function latestMessages(accounts, limit) {
  var values = Array.isArray(accounts) ? accounts : []
  var out = []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    var account = values[valueIndex] || {}
    var messages = Array.isArray(account.messages) ? account.messages : []
    for (var messageIndex = 0; messageIndex < messages.length; messageIndex++) {
      var item = messages[messageIndex] || {}
      if (item.unread !== true) continue
      var copy = ({})
      for (var key in item) copy[key] = item[key]
      copy.accountId = String(account.id || "")
      copy.sourceLabel = String(account.label || "Mailbox") + " · "
        + String(account.inbox || "Inbox")
      copy.receivedLabel = String(item.fullTime || "")
      out.push(copy)
    }
  }
  out.sort(function(left, right) {
    return messageTime(right) - messageTime(left)
  })
  return out.slice(0, Math.max(0, Math.floor(Number(limit) || 0)))
}

// Performance: key the preview month by day so repeated clock ticks reuse its calendar range.
function previewRange(nowMs) {
  var now = new Date(Number(nowMs) || Date.now())
  var today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  return [today.getTime(),
    new Date(now.getFullYear(), now.getMonth(), now.getDate() + 31).getTime()]
}

function upcomingEvents(events, nowMs, limit) {
  var values = Array.isArray(events) ? events : []
  var now = Number(nowMs) || Date.now()
  var out = []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    var item = values[valueIndex] || {}
    if (!item.start || Number(item.start.ms) < now) continue
    var copy = ({})
    for (var key in item) copy[key] = item[key]
    copy.sourceLabel = String(item.sourceName || item.sourceId || "Calendar")
    var location = String(item.location || "").trim()
    copy.callUrl = Html.externallyOpenableHttpUrl(item.meetLink)
      || Html.externallyOpenableHttpUrl(/^https?:\/\/\S+$/i.test(location) ? location : "")
    out.push(copy)
  }
  out.sort(function(left, right) { return Number(left.start.ms) - Number(right.start.ms) })
  return out.slice(0, Math.max(0, Math.floor(Number(limit) || 0)))
}

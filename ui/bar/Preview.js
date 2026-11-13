.pragma library


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
  var output = []
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
      output.push(copy)
    }
  }
  output.sort(function(left, right) {
    return messageTime(right) - messageTime(left)
  })
  return output.slice(0, Math.max(0, Math.floor(Number(limit) || 0)))
}

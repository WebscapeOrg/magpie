.pragma library

// Invariant: replacement bars must never receive the credential-bearing Service QObject.
var active = null

function text(value) {
  return typeof value === "string" ? value.slice(0, 4096) : ""
}

function identifier(value) {
  return typeof value === "string" && value.length <= 4096 ? value : ""
}

function settings(values, defaults) {
  var output = {}
  var source = values || {}
  for (var key in defaults) {
    var value = source[key]
    if (typeof value !== typeof defaults[key]) continue
    if (typeof value === "string" && value.length <= 4096) output[key] = value
    else if (typeof value === "number" && isFinite(value)) output[key] = value
    else if (typeof value === "boolean") output[key] = value
  }
  return output
}

function snapshot(value) {
  var source = value || {}
  var messages = Array.isArray(source.barMessages) ? source.barMessages : []
  var events = Array.isArray(source.barEvents) ? source.barEvents : []
  var mail = []
  var calendar = []
  for (var messageIndex = 0; messageIndex < Math.min(messages.length, 3); messageIndex++) {
    var message = messages[messageIndex] || {}
    mail.push({
      id: identifier(message.id), accountId: identifier(message.accountId),
      subject: text(message.subject), unread: message.unread === true,
      subjectDirection: message.subjectDirection === "rtl" || message.subjectDirection === "ltr"
        ? message.subjectDirection : "",
      from: { display: text(message.from && message.from.display) },
      sourceLabel: text(message.sourceLabel), receivedLabel: text(message.receivedLabel)
    })
  }
  for (var eventIndex = 0; eventIndex < Math.min(events.length, 2); eventIndex++) {
    var event = events[eventIndex] || {}
    var start = event.start && event.start.ms
    if (typeof start !== "number" || !isFinite(start)) continue
    calendar.push({
      uid: identifier(event.uid), start: { ms: start },
      summary: text(event.summary), sourceLabel: text(event.sourceLabel),
      callUrl: identifier(event.callUrl)
    })
  }
  return {
    ready: source.ready === true, windowOpen: source.windowOpen === true,
    showBarIcon: source.showBarIcon !== false,
    unreadTotal: typeof source.unreadTotal === "number" && isFinite(source.unreadTotal)
      ? Math.max(0, Math.floor(source.unreadTotal)) : 0,
    barTooltip: text(source.barTooltip), contentDirection: text(source.contentDirection),
    barMessages: mail, barEvents: calendar
  }
}

function publish(readSnapshot, applySettings, refresh, refreshCalendarPreview) {
  var api = Object.freeze({
    snapshot: function() { return active === api ? snapshot(readSnapshot()) : null },
    applySettings: function(values) { if (active === api) applySettings(values) },
    refresh: function() { if (active === api) refresh() },
    refreshCalendarPreview: function() { if (active === api) refreshCalendarPreview() }
  })
  active = api
  return api
}

function current() { return active }

// Invariant: a retiring service must not clear a replacement registered during hot reload.
function clear(api) { if (active === api) active = null }

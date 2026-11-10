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

// The plugin's entry in shell.json, on the bar or in plugins[], without its id. It fills Magpie's own
// settings file on a first run and is not read after that.
function shellEntrySettings(config, pluginId) {
  var layout = config && config.bar && config.bar.layout
  var entries = []
  var sections = ["left", "center", "right"]
  for (var section = 0; section < sections.length; section++) {
    var lane = layout && layout[sections[section]]
    if (Array.isArray(lane)) entries = entries.concat(lane)
  }
  if (config && Array.isArray(config.plugins)) entries = entries.concat(config.plugins)
  var entry = entries.filter(function(candidate) { return candidate && candidate.id === pluginId })[0]
  if (!entry) return null
  var saved = {}
  var found = false
  for (var key in entry) {
    if (key === "id") continue
    saved[key] = entry[key]
    found = true
  }
  return found ? saved : null
}

function snapshot(value) {
  var source = value || {}
  var messages = Array.isArray(source.barMessages) ? source.barMessages : []
  var mail = []
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
  return {
    ready: source.ready === true, windowOpen: source.windowOpen === true,
    showBarIcon: source.showBarIcon !== false,
    unreadTotal: typeof source.unreadTotal === "number" && isFinite(source.unreadTotal)
      ? Math.max(0, Math.floor(source.unreadTotal)) : 0,
    barTooltip: text(source.barTooltip), contentDirection: text(source.contentDirection),
    barMessages: mail
  }
}

function publish(readSnapshot, applySettings, refresh) {
  var api = Object.freeze({
    snapshot: function() { return active === api ? snapshot(readSnapshot()) : null },
    applySettings: function(values) { if (active === api) applySettings(values) },
    refresh: function() { if (active === api) refresh() }
  })
  active = api
  return api
}

function current() { return active }

// Invariant: a retiring service must not clear a replacement registered during hot reload.
function clear(api) { if (active === api) active = null }

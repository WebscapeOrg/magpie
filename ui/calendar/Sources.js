.pragma library

.import "Palette.js" as Palette

var VERSION = 1
var KINDS = ["caldav", "google", "microsoft", "icloud", "hey"]
var COLOR_KEYS = Palette.keys()

function defaultColorKey(identity) { return Palette.defaultKey(identity) }

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function emptyList() {
  return { version: VERSION, sources: [] }
}

function normalizeKind(value) {
  var kind = trimmed(value).toLowerCase()
  return KINDS.indexOf(kind) >= 0 ? kind : "caldav"
}

function sourceId(raw, list) {
  var value = raw || {}
  var kind = normalizeKind(value.kind)
  if (kind === "google") return "google:" + trimmed(value.accountId)
  if (kind === "microsoft") return "microsoft:" + trimmed(value.accountId)
  var address = comparableUrl(value.url)
  var username = trimmed(value.username)
  var saved = list && Array.isArray(list.sources) ? list.sources : []
  for (var index = 0; index < saved.length; index++) {
    var source = saved[index]
    if (source && source.kind === kind && comparableUrl(source.url) === address
        && trimmed(source.username) === username && trimmed(source.id) !== "")
      return source.id
  }
  return kind + ":" + JSON.stringify([address, username])
}

function makeSource(raw) {
  var value = raw || {}
  var kind = normalizeKind(value.kind)
  var id = trimmed(value.id)
  var colorKey = Palette.normalizeKey(value.colorKey)
  if (colorKey === "") colorKey = Palette.defaultKey(id)
  return {
    id: id, kind: kind, name: trimmed(value.name),
    url: trimmed(value.url), username: trimmed(value.username),
    accountId: trimmed(value.accountId), enabled: value.enabled !== false,
    calendarId: trimmed(value.calendarId),
    readOnly: value.readOnly === true, discovered: value.discovered === true,
    colorKey: colorKey,
    accessRole: trimmed(value.accessRole), timeZone: trimmed(value.timeZone),
    canCreateMeet: value.canCreateMeet === true,
    defaultReminders: Array.isArray(value.defaultReminders) ? value.defaultReminders.slice() : [],
    remindersEnabled: value.remindersEnabled === undefined ? value.enabled !== false : value.remindersEnabled === true,
    reminderMinutes: isFinite(Number(value.reminderMinutes)) && value.reminderMinutes !== undefined
      ? Math.max(-1, Math.min(40320, Math.floor(Number(value.reminderMinutes)))) : -1,
    preferred: value.preferred === true
  }
}

function copyList(list) {
  var value = list || emptyList()
  return {
    version: VERSION,
    sources: Array.isArray(value.sources) ? value.sources.slice() : []
  }
}

function add(list, raw) {
  var next = copyList(list)
  var source = makeSource(raw)
  if (source.id === "") return next
  var found = -1
  for (var index = 0; index < next.sources.length; index++) {
    if (next.sources[index] && next.sources[index].id === source.id) { found = index; break }
  }
  if (found >= 0) next.sources[found] = source
  else next.sources.push(source)
  return next
}

function remove(list, id) {
  var next = copyList(list)
  var wanted = trimmed(id)
  for (var index = 0; index < next.sources.length; index++) {
    if (next.sources[index] && next.sources[index].id === wanted) {
      next.sources.splice(index, 1)
      break
    }
  }
  return next
}

function setEnabled(list, id, enabled) {
  var next = copyList(list)
  var wanted = trimmed(id)
  for (var index = 0; index < next.sources.length; index++) {
    if (!next.sources[index] || next.sources[index].id !== wanted) continue
    var changed = makeSource(next.sources[index])
    changed.enabled = enabled !== false
    next.sources[index] = changed
    break
  }
  return next
}

function setColor(list, id, colorKey) {
  var normalized = Palette.normalizeKey(colorKey)
  if (normalized === "") return copyList(list)
  var next = copyList(list)
  var wanted = trimmed(id)
  for (var index = 0; index < next.sources.length; index++) {
    if (!next.sources[index] || next.sources[index].id !== wanted) continue
    var changed = makeSource(next.sources[index])
    changed.colorKey = normalized
    next.sources[index] = changed
    break
  }
  return next
}

function validate(raw) {
  var source = makeSource(raw)
  if (source.kind === "google") {
    return source.accountId !== ""
      ? { ok: true, source: source }
      : { ok: false, error: "Choose a signed-in Google account" }
  }
  if (source.kind === "icloud") {
    if (source.accountId === "") return { ok: false, error: "Choose a signed-in iCloud account" }
    if (source.name === "") return { ok: false, error: "That iCloud calendar has no name" }
    if (!/^https:\/\//i.test(source.url)) return { ok: false, error: "That iCloud calendar has no address" }
    return { ok: true, source: source }
  }
  if (source.kind === "hey")
    return { ok: false, error: "The HEY CLI does not expose calendar events" }
  if (source.name === "") return { ok: false, error: "Add a calendar name" }
  if (!/^https:\/\//i.test(source.url))
    return { ok: false, error: "Use an HTTPS CalDAV calendar address" }
  if (source.username === "") return { ok: false, error: "Add the CalDAV username" }
  var identity = source.id || sourceId(source)
  var identityBytes = 1025
  try { identityBytes = encodeURIComponent(identity).replace(/%[0-9A-F]{2}/g, "_").length } catch (encodingError) {}
  if (identityBytes > 1024)
    return { ok: false, error: "The calendar address and username are too long" }
  return { ok: true, source: source }
}

function serialize(list) {
  return JSON.stringify(copyList(list))
}

function load(text) {
  var parsed = null
  try { parsed = JSON.parse(String(text || "")) } catch (parseError) {}
  var input = parsed && Array.isArray(parsed.sources) ? parsed.sources : []
  var list = emptyList()
  for (var inputIndex = 0; inputIndex < input.length; inputIndex++) list = add(list, input[inputIndex])
  return list
}

function keyringAttributes(sourceId) {
  var id = trimmed(sourceId)
  if (id === "") return []
  return ["service", "omamail", "kind", "calendar-password", "source", id]
}

function withGoogleAccounts(list, accountSummaries) {
  var next = copyList(list)
  var accounts = Array.isArray(accountSummaries) ? accountSummaries : []
  for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
    var account = accounts[accountIndex] || {}
    if (account.provider !== "gmail" || account.signedIn !== true) continue
    var accountId = trimmed(account.id || account.email)
    if (accountId === "") continue
    var saved = null
    for (var sourceIndex = 0; sourceIndex < next.sources.length; sourceIndex++) {
      if (next.sources[sourceIndex] && next.sources[sourceIndex].id === "google:" + accountId) {
        saved = next.sources[sourceIndex]
        break
      }
    }
    // Invariant: discovered primary-calendar metadata replaces legacy defaults so permissions and reminders survive.
    var hasDiscovery = next.sources.some(function(source) {
      return source && source.kind === "google" && source.accountId === accountId && source.discovered
    })
    if (hasDiscovery) continue
    next = add(next, {
      id: "google:" + accountId,
      kind: "google",
      // Invariant: calendar errors retain the full mailbox address to distinguish accounts.
      name: trimmed(account.email || account.label || "Google Calendar"),
      accountId: accountId,
      enabled: saved ? saved.enabled !== false : true,
      // Invariant: historical Google backends display calendars without offering unsupported writes.
      readOnly: false,
      colorKey: saved ? saved.colorKey : Palette.defaultKey("google:" + accountId),
      remindersEnabled: saved ? saved.remindersEnabled : true,
      reminderMinutes: saved ? saved.reminderMinutes : -1,
      preferred: saved ? saved.preferred : false
    })
  }
  return next
}

// Invariant: Microsoft calendar sources retain the owning Outlook or Microsoft 365 account.
function withMicrosoftAccounts(list, accountSummaries) {
  var next = copyList(list)
  var accounts = Array.isArray(accountSummaries) ? accountSummaries : []
  for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
    var account = accounts[accountIndex] || {}
    if (account.provider !== "outlook" || account.signedIn !== true) continue
    var accountId = trimmed(account.id || account.email)
    if (accountId === "") continue
    var saved = null
    var discovered = false
    for (var sourceIndex = 0; sourceIndex < next.sources.length; sourceIndex++) {
      var source = next.sources[sourceIndex] || {}
      if (source.id === "microsoft:" + accountId) saved = source
      else if (source.kind === "microsoft" && source.discovered === true
          && trimmed(source.accountId) === accountId) discovered = true
    }
    // Invariant: discovery preserves stable primary-calendar identity while adding secondary calendars.
    if (!saved && discovered) continue
    next = add(next, {
      id: "microsoft:" + accountId,
      kind: "microsoft",
      name: saved && saved.discovered === true && trimmed(saved.name) !== ""
        ? trimmed(saved.name) : trimmed(account.email || account.label || "Microsoft Calendar"),
      accountId: accountId,
      enabled: saved ? saved.enabled !== false : true,
      calendarId: saved ? trimmed(saved.calendarId) : "",
      readOnly: saved && saved.discovered === true ? saved.readOnly === true : false,
      discovered: saved ? saved.discovered === true : false,
      colorKey: saved ? saved.colorKey : Palette.defaultKey("microsoft:" + accountId),
      remindersEnabled: saved ? saved.remindersEnabled : true,
      reminderMinutes: saved ? saved.reminderMinutes : -1,
      preferred: saved ? saved.preferred : false
    })
  }
  return next
}

function comesWithAccount(source) {
  return !!source && (source.kind === "google" || source.kind === "microsoft"
    || source.kind === "icloud")
}

function accountSummary(accountId, accountSummaries) {
  var wanted = trimmed(accountId)
  var accounts = Array.isArray(accountSummaries) ? accountSummaries : []
  for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
    if (accounts[accountIndex] && trimmed(accounts[accountIndex].id || accounts[accountIndex].email) === wanted)
      return accounts[accountIndex]
  }
  return null
}

function orphaned(source, accountSummaries) {
  if (!comesWithAccount(source) || trimmed(source.accountId) === "") return false
  return accountSummary(source.accountId, accountSummaries) === null
}

function errorLabel(source, accountSummaries) {
  if (!source) return "Calendar"
  var name = trimmed(source.name) || trimmed(source.id) || "Calendar"
  if (source.discovered !== true || !comesWithAccount(source)) return name
  var accountId = trimmed(source.accountId)
  if (accountId === "") return name
  var account = accountSummary(accountId, accountSummaries)
  var mailbox = account ? trimmed(account.email || account.label) : ""
  return name + " · " + (mailbox === "" ? accountId : mailbox)
}

function comparableUrl(value) {
  var text = trimmed(value)
  var parts = /^(https?:\/\/[^/?#]+)([^?#]*)(.*)$/i.exec(text)
  if (!parts) return text
  return parts[1].toLowerCase() + parts[2].replace(/\/+$/, "") + parts[3]
}

function sameUrl(left, right) {
  return comparableUrl(left) === comparableUrl(right)
}

// Invariant: discovery replaces only the target account's sources and stays bounded.
function applyDiscovery(list, result) {
  var value = result || {}
  var provider = trimmed(value.provider).toLowerCase()
  var accountId = trimmed(value.accountId)
  var kind = provider === "microsoft" ? "microsoft"
    : (provider === "icloud" ? "icloud" : (provider === "google" ? "google" : ""))
  if (kind === "" || accountId === "" || !Array.isArray(value.calendars))
    return copyList(list)
  var current = list && Array.isArray(list.sources) ? list.sources : []
  var discovered = []
  for (var index = 0; index < value.calendars.length; index++) {
    var remote = value.calendars[index] || {}
    var id = trimmed(remote.sourceId)
    if (id === "") continue
    var saved = null
    for (var candidateIndex = 0; candidateIndex < current.length; candidateIndex++) {
      var candidate = current[candidateIndex] || {}
      if (trimmed(candidate.id) === id
          || (kind === "icloud" && trimmed(remote.url) !== ""
            && sameUrl(candidate.url, remote.url))) {
        saved = candidate
        break
      }
    }
    var initial = kind === "google" ? remote.selected !== false && remote.hidden !== true : true
    discovered.push(makeSource({
      id: id, kind: kind, name: remote.name,
      accountId: accountId, calendarId: remote.calendarId,
      url: remote.url, username: remote.username,
      enabled: saved ? saved.enabled !== false : initial,
      readOnly: remote.readOnly === true, discovered: true,
      colorKey: saved ? saved.colorKey : Palette.defaultKey(id),
      accessRole: remote.accessRole, timeZone: remote.timeZone,
      canCreateMeet: remote.canCreateMeet, defaultReminders: remote.defaultReminders,
      remindersEnabled: saved ? saved.remindersEnabled : initial,
      reminderMinutes: saved ? saved.reminderMinutes : -1,
      preferred: saved ? saved.preferred : remote.isDefault === true
    }))
  }
  var next = emptyList()
  for (var sourceIndex = 0; sourceIndex < current.length; sourceIndex++) {
    var source = current[sourceIndex] || {}
    var owned = source.kind === kind && trimmed(source.accountId) === accountId
    var adopted = kind === "icloud" && source.kind === "caldav"
      && discovered.some(function(item) { return sameUrl(item.url, source.url) })
    if (!owned && !adopted) next = add(next, source)
  }
  for (var discoveredIndex = 0; discoveredIndex < discovered.length; discoveredIndex++) next = add(next, discovered[discoveredIndex])
  return next
}

function forAccount(list, accountId) {
  var source = list || emptyList()
  var wanted = trimmed(accountId)
  if (wanted === "") return copyList(source)
  var next = emptyList()
  var values = Array.isArray(source.sources) ? source.sources : []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    if (!values[valueIndex]) continue
    if (!comesWithAccount(values[valueIndex]) || trimmed(values[valueIndex].accountId) === wanted)
      next = add(next, values[valueIndex])
  }
  return next
}

function providerLabel(kind) {
  var value = trimmed(kind).toLowerCase()
  if (value === "google" || value === "gmail") return "Google"
  if (value === "microsoft" || value === "outlook") return "Microsoft"
  if (value === "icloud") return "iCloud"
  if (value === "hey") return "HEY"
  return "CalDAV"
}

function groupByAccount(list, accountSummaries) {
  var values = list && Array.isArray(list.sources) ? list.sources : []
  var accounts = Array.isArray(accountSummaries) ? accountSummaries : []
  var groups = []
  var assigned = ({})

  function calendarMatches(source, account) {
    var accountId = trimmed(account.id || account.email).toLowerCase()
    var email = trimmed(account.email).toLowerCase()
    var owner = trimmed(source.accountId).toLowerCase()
    var username = trimmed(source.username).toLowerCase()
    if (owner !== "" && (owner === accountId || owner === email)) return true
    return source.kind === "caldav" && email !== "" && username === email
  }

  for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
    var account = accounts[accountIndex] || {}
    var calendars = []
    for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
      var source = values[valueIndex] || {}
      if (assigned[source.id] || !calendarMatches(source, account)) continue
      calendars.push(source)
      assigned[source.id] = true
    }
    if (calendars.length === 0) continue
    groups.push({
      id: "account:" + trimmed(account.id || account.email),
      providerLabel: providerLabel(calendars[0].kind || account.provider),
      accountLabel: account.provider === "gmail"
        ? trimmed(account.email || account.label || "Google account")
        : trimmed(account.label || account.email || "Account"),
      calendars: calendars
    })
  }

  for (var remainingIndex = 0; remainingIndex < values.length; remainingIndex++) {
    var remaining = values[remainingIndex] || {}
    if (assigned[remaining.id]) continue
    var ownerKey = trimmed(remaining.accountId || remaining.username)
    if (ownerKey === "") ownerKey = providerLabel(remaining.kind)
    var groupId = "source:" + remaining.kind + ":" + ownerKey.toLowerCase()
    var group = null
    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      if (groups[groupIndex].id === groupId) { group = groups[groupIndex]; break }
    }
    if (!group) {
      group = { id: groupId, providerLabel: providerLabel(remaining.kind),
        accountLabel: ownerKey, calendars: [] }
      groups.push(group)
    }
    group.calendars.push(remaining)
  }
  return groups
}

function writable(source) {
  return !!source && source.readOnly !== true
}

// Invariant: shared calendar views support multiple providers, but deep integration is Google-only.
function nativeCalendarFeatures(source) {
  return !!source && source.kind === "google"
}

function writableGroups(groups) {
  var values = Array.isArray(groups) ? groups : []
  var output = []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    var group = values[valueIndex] || {}
    var calendars = (Array.isArray(group.calendars) ? group.calendars : [])
      .filter(function(source) { return writable(source) })
    if (calendars.length === 0) continue
    output.push({ id: group.id, providerLabel: group.providerLabel,
      accountLabel: group.accountLabel, calendars: calendars })
  }
  return output
}

function calendarEditorUrl(list) {
  var values = list && Array.isArray(list.sources) ? list.sources : []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    var source = values[valueIndex] || {}
    if (source.enabled === false) continue
    if (source.kind === "google")
      return "https://calendar.google.com/calendar/u/0/r/eventedit"
    if (source.kind === "icloud") return "https://www.icloud.com/calendar/"
    if (source.kind === "caldav") {
      var match = /^(https:\/\/[^/]+)/i.exec(String(source.url || ""))
      if (match) return match[1] + "/apps/calendar/"
    }
  }
  return ""
}

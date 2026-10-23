.pragma library

.import "Palette.js" as Palette

var VERSION = 1
var COLOR_KEYS = Palette.keys()


function defaultColorKey(identity) { return Palette.defaultKey(identity) }

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function emptyList() {
  return { version: VERSION, sources: [] }
}

function normalizeKind(value) {
  return trimmed(value).toLowerCase()
}

function sourceId(raw) {
  return "google:" + trimmed(raw && raw.accountId)
}

function makeSource(raw) {
  var value = raw || {}
  var kind = normalizeKind(value.kind)
  if (kind !== "google") return value
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
  if (!comesWithAccount(source) || source.id === "") return next
  var found = -1
  for (var index = 0; index < next.sources.length; index++) {
    if (comesWithAccount(next.sources[index]) && next.sources[index].id === source.id) { found = index; break }
  }
  if (found >= 0) next.sources[found] = source
  else next.sources.push(source)
  return next
}

function remove(list, id) {
  var next = copyList(list)
  var wanted = trimmed(id)
  for (var index = 0; index < next.sources.length; index++) {
    if (comesWithAccount(next.sources[index]) && next.sources[index].id === wanted) {
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
    if (!comesWithAccount(next.sources[index]) || next.sources[index].id !== wanted) continue
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
    if (!comesWithAccount(next.sources[index]) || next.sources[index].id !== wanted) continue
    var changed = makeSource(next.sources[index])
    changed.colorKey = normalized
    next.sources[index] = changed
    break
  }
  return next
}

function validate(raw) {
  var source = makeSource(raw)
  if (source.kind !== "google") return { ok: false, error: "Only Google calendars are supported" }
  return source.accountId !== ""
    ? { ok: true, source: source }
    : { ok: false, error: "Choose a signed-in Google account" }
}

function serialize(list) {
  return JSON.stringify(copyList(list))
}

function load(text) {
  var parsed = null
  try { parsed = JSON.parse(String(text || "")) } catch (parseError) {}
  var input = parsed && Array.isArray(parsed.sources) ? parsed.sources : []
  var list = emptyList()
  for (var inputIndex = 0; inputIndex < input.length; inputIndex++) {
    var source = input[inputIndex]
    if (source && source.kind === "google") list = add(list, source)
    else list.sources.push(source)
  }
  return list
}



function withGoogleAccounts(list, accountSummaries) {
  var next = copyList(list)
  var accounts = Array.isArray(accountSummaries) ? accountSummaries : []
  for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
    var account = accounts[accountIndex] || {}
    if (account.provider && account.provider !== "gmail" || account.signedIn !== true) continue
    var accountId = trimmed(account.id || account.email)
    if (accountId === "") continue
    var saved = null
    for (var sourceIndex = 0; sourceIndex < next.sources.length; sourceIndex++) {
      if (comesWithAccount(next.sources[sourceIndex]) && next.sources[sourceIndex].id === "google:" + accountId) {
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
  return activeSources(next)
}

function comesWithAccount(source) {
  return !!source && source.kind === "google"
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





// Invariant: discovery replaces only the target account's sources and stays bounded.
function applyDiscovery(list, result) {
  var value = result || {}
  var provider = trimmed(value.provider).toLowerCase()
  var accountId = trimmed(value.accountId)
  var kind = provider === "google" ? "google" : ""
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
      if (candidate.kind === "google" && trimmed(candidate.id) === id) {
        saved = candidate
        break
      }
    }
    var initial = remote.selected !== false && remote.hidden !== true
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
    if (!owned) next.sources.push(source)
  }
  for (var discoveredIndex = 0; discoveredIndex < discovered.length; discoveredIndex++) next = add(next, discovered[discoveredIndex])
  return next
}

function forAccount(list, accountId) {
  var source = activeSources(list)
  var wanted = trimmed(accountId)
  if (wanted === "") return copyList(source)
  var next = emptyList()
  var values = Array.isArray(source.sources) ? source.sources : []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    if (!values[valueIndex]) continue
    if (trimmed(values[valueIndex].accountId) === wanted)
      next = add(next, values[valueIndex])
  }
  return next
}

function providerLabel() { return "Google" }

function groupByAccount(list, accountSummaries) {
  var values = activeSources(list).sources
  var accounts = Array.isArray(accountSummaries) ? accountSummaries : []
  var groups = []
  var assigned = ({})

  function calendarMatches(source, account) {
    var accountId = trimmed(account.id || account.email).toLowerCase()
    var email = trimmed(account.email).toLowerCase()
    var owner = trimmed(source.accountId).toLowerCase()
    return owner !== "" && (owner === accountId || owner === email)
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
      accountLabel: trimmed(account.email || account.label || "Google account"),
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
  return comesWithAccount(source) && source.readOnly !== true
}

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
  return activeSources(list).sources.some(function(source) { return source.enabled !== false })
    ? "https://calendar.google.com/calendar/u/0/r/eventedit" : ""
}

function activeSources(list) {
  var next = copyList(list)
  next.sources = next.sources.filter(function(source) { return comesWithAccount(source) })
  return next
}

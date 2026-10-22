.pragma library

// Invariant: Settings and persisted aliases use one parser so reopening the form cannot silently drop accepted identities.
var EMAIL_PATTERN = /^[^\s@]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

// Invariant: Commas inside quoted display names or angle brackets belong to one alias; splitting them loses names on save.
function splitEntries(text) {
  var result = []
  var current = ""
  var quoted = false
  var angled = false
  for (var characterIndex = 0; characterIndex < text.length; characterIndex++) {
    var character = text.charAt(characterIndex)
    if (quoted) {
      if (character === "\\" && characterIndex + 1 < text.length) {
        current += character + text.charAt(characterIndex + 1)
        characterIndex++
        continue
      }
      if (character === "\"") quoted = false
      current += character
      continue
    }
    if (character === "\"") {
      quoted = true
      current += character
      continue
    }
    if (character === "<") angled = true
    else if (character === ">") angled = false
    if (!angled && (character === "," || character === "\n" || character === "\r")) {
      result.push(current)
      current = ""
      continue
    }
    current += character
  }
  result.push(current)
  return result
}

function unquoted(value) {
  var text = trimmed(value)
  if (text.length < 2 || text.charAt(0) !== "\"" || text.charAt(text.length - 1) !== "\"")
    return text
  return text.substring(1, text.length - 1).replace(/\\([\\"])/g, "$1")
}

// Invariant: A default marker is recognized only at an edge; the same text inside a display name remains literal.
function withoutDefaultMarker(text) {
  var value = trimmed(text)
  var match = value.match(/^(.*?)\s*(?:\(default\)|\[default\])$/i)
  if (match) return { text: trimmed(match[1]), isDefault: true }
  if (/\*+$/.test(value)) return { text: value.replace(/\*+$/, "").trim(), isDefault: true }
  if (/^\*+/.test(value)) return { text: value.replace(/^\*+/, "").trim(), isDefault: true }
  return { text: value, isDefault: false }
}

function fromText(entry) {
  var marked = withoutDefaultMarker(entry)
  var text = marked.text
  var angle = text.match(/^(.*?)\s*<([^\s@<>]+@[^<>]+)>$/)
  if (angle) {
    return {
      email: trimmed(angle[2]).toLowerCase(),
      displayName: unquoted(angle[1]),
      isDefault: marked.isDefault
    }
  }
  return { email: text.toLowerCase(), displayName: "", isDefault: marked.isDefault }
}

function fromObject(item) {
  return {
    email: trimmed(item.email || item.sendAsEmail).toLowerCase(),
    displayName: trimmed(item.displayName || item.name),
    isDefault: item.isDefault === true || item.default === true || item.defaultFrom === true
  }
}

function parse(value) {
  if (!value) return []
  var raw = []
  if (Array.isArray(value)) raw = value
  else if (typeof value === "string") raw = splitEntries(value)
  else return []

  var result = []
  var seen = {}
  var haveDefault = false
  for (var aliasIndex = 0; aliasIndex < raw.length; aliasIndex++) {
    var item = raw[aliasIndex]
    var parsed = typeof item === "string" ? fromText(item)
      : (item && typeof item === "object" ? fromObject(item) : null)
    if (!parsed) continue
    if (!parsed.email || !EMAIL_PATTERN.test(parsed.email)) continue
    if (seen[parsed.email]) continue
    seen[parsed.email] = true
    // Invariant: At most one alias is the default; the first marked entry wins.
    var isDefault = parsed.isDefault && !haveDefault
    if (isDefault) haveDefault = true
    result.push({
      email: parsed.email,
      displayName: parsed.displayName,
      isPrimary: false,
      isDefault: isDefault
    })
  }
  return result
}

// Invariant: Formatting must round-trip quoted separators and escapes through the same parser.
function quotedName(name) {
  var text = trimmed(name)
  if (text === "") return ""
  if (!/[",]/.test(text)) return text
  return "\"" + text.replace(/([\\"])/g, "\\$1") + "\""
}

function format(aliases) {
  var list = parse(aliases)
  var entries = []
  for (var aliasIndex = 0; aliasIndex < list.length; aliasIndex++) {
    var item = list[aliasIndex]
    var text = item.displayName !== ""
      ? quotedName(item.displayName) + " <" + item.email + ">"
      : item.email
    if (item.isDefault) text += " (default)"
    entries.push(text)
  }
  return entries.join(", ")
}

// Invariant: The mailbox address leads the sender list and is primary; an explicit alias default changes only the initial selection.
function sendAsList(address, aliases) {
  var primary = trimmed(address)
  var list = []
  var seen = {}
  var rows = parse(aliases)
  var claimed = false
  for (var defaultIndex = 0; defaultIndex < rows.length; defaultIndex++) {
    if (rows[defaultIndex].isDefault) {
      claimed = true
      break
    }
  }
  if (primary !== "") {
    seen[primary.toLowerCase()] = true
    list.push({
      email: primary,
      displayName: "",
      isPrimary: true,
      isDefault: !claimed
    })
  }
  for (var aliasIndex = 0; aliasIndex < rows.length; aliasIndex++) {
    var row = rows[aliasIndex]
    if (seen[row.email]) continue
    seen[row.email] = true
    list.push({
      email: row.email,
      displayName: row.displayName,
      isPrimary: false,
      isDefault: row.isDefault
    })
  }
  return list
}

// Invariant: Applying the mailbox sender name preserves alias-specific names and does not mutate provider records.
function withSenderName(rows, name) {
  var list = Array.isArray(rows) ? rows : []
  var wanted = trimmed(name)
  if (wanted === "") return list
  var result = []
  for (var aliasIndex = 0; aliasIndex < list.length; aliasIndex++) {
    var row = list[aliasIndex]
    if (row && row.isPrimary === true) {
      var named = {}
      for (var key in row) named[key] = row[key]
      named.displayName = wanted
      result.push(named)
    } else {
      result.push(row)
    }
  }
  return result
}

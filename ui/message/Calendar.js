.pragma library

.import "Message.js" as Mail

// Docs: Calendar invitations are MIME parts; RSVP uses an RFC 5546 reply addressed to the organiser.

var MAX_ICS_BYTES = 512 * 1024
var MAX_COMPONENT_DEPTH = 8

// Invariant: unfold content lines before parsing properties so folded escapes remain intact.
function unfoldLines(text) {
  var joined = String(text || "").replace(/\r\n[ \t]|\n[ \t]|\r[ \t]/g, "")
  var lines = joined.split(/\r\n|\n|\r/)
  var out = []
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    if (lines[lineIndex] !== "") out.push(lines[lineIndex])
  }
  return out
}

function unescapeText(value) {
  var input = String(value === undefined || value === null ? "" : value)
  var out = ""
  for (var index = 0; index < input.length; index++) {
    var character = input.charAt(index)
    if (character !== "\\") {
      out += character
      continue
    }
    var next = input.charAt(index + 1)
    if (next === "n" || next === "N") out += "\n"
    else if (next === "\\" || next === ";" || next === "," || next === ":") out += next
    else if (next === "") out += character
    else out += next
    index++
  }
  return out
}

function escapeText(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r\n|\n|\r/g, "\\n")
}

// Invariant: a quoted parameter can contain the colon that otherwise separates the property value.

function parseProperty(line) {
  var text = String(line || "")
  var quoted = false
  var cut = -1
  for (var index = 0; index < text.length; index++) {
    var character = text.charAt(index)
    if (character === "\"") quoted = !quoted
    else if (character === ":" && !quoted) { cut = index; break }
  }
  if (cut < 0) return null

  var head = text.substring(0, cut)
  var value = text.substring(cut + 1)

  var pieces = splitOutsideQuotes(head, ";")
  var name = String(pieces.length > 0 ? pieces[0] : "").toUpperCase().trim()
  if (name === "") return null

  var params = {}
  for (var pieceIndex = 1; pieceIndex < pieces.length; pieceIndex++) {
    var equals = pieces[pieceIndex].indexOf("=")
    if (equals < 0) continue
    var key = pieces[pieceIndex].substring(0, equals).toUpperCase().trim()
    var raw = pieces[pieceIndex].substring(equals + 1).trim()
    if (key !== "") params[key] = stripQuotes(raw)
  }

  return { name: name, params: params, value: value, raw: text }
}

function splitOutsideQuotes(text, separator) {
  var input = String(text || "")
  var out = []
  var current = ""
  var quoted = false
  for (var index = 0; index < input.length; index++) {
    var character = input.charAt(index)
    if (character === "\"") {
      quoted = !quoted
      current += character
      continue
    }
    if (character === separator && !quoted) {
      out.push(current)
      current = ""
      continue
    }
    current += character
  }
  out.push(current)
  return out
}

function stripQuotes(value) {
  var text = String(value || "").trim()
  if (text.length >= 2 && text.charAt(0) === "\"" && text.charAt(text.length - 1) === "\"")
    return text.substring(1, text.length - 1)
  return text
}

// Invariant: replies preserve the organiser's original time and timezone source lines.

function parse(text) {
  var source = String(text || "")
  if (source.length > MAX_ICS_BYTES) return null
  var lines = unfoldLines(source)
  var root = null
  var stack = []

  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    var property = parseProperty(lines[lineIndex])
    if (!property) continue
    var open = stack.length > 0 ? stack[stack.length - 1] : null

    if (property.name === "BEGIN") {
      if (stack.length >= MAX_COMPONENT_DEPTH) return null
      var child = {
        name: String(property.value || "").toUpperCase().trim(),
        properties: [],
        children: [],
        lines: []
      }
      if (open) {
        open.children.push(child)
      } else if (root === null) {
        root = child
      } else {
        continue
      }
      stack.push(child)
      continue
    }

    if (property.name === "END") {
      if (stack.length === 0) continue
      if (open.name !== String(property.value || "").toUpperCase().trim()) return null
      var closing = stack.pop()
      var parent = stack.length > 0 ? stack[stack.length - 1] : null
      // Invariant: retain complete nested VTIMEZONE source in replies, including its transition rules.
      if (parent) {
        parent.lines = parent.lines
          .concat(["BEGIN:" + closing.name], closing.lines, ["END:" + closing.name])
      }
      if (closing !== root && stack.length === 0) break
      continue
    }

    if (!open) continue
    open.properties.push(property)
    open.lines.push(lines[lineIndex])
  }

  return root
}

// Invariant: CalDAV PUT replaces the resource; edit only the selected VEVENT and preserve unmodelled properties and nested components.
function rewriteEvent(text, uid, replacementLines, propertyNames) {
  var lines = unfoldLines(text)
  var wantedUid = String(uid || "")
  var matches = []
  var start = -1
  var depth = 0
  var foundUid = ""
  for (var scanIndex = 0; scanIndex < lines.length; scanIndex++) {
    var parsed = parseProperty(lines[scanIndex])
    if (!parsed) continue
    if (start < 0 && parsed.name === "BEGIN"
        && String(parsed.value || "").toUpperCase() === "VEVENT") {
      start = scanIndex
      depth = 1
      foundUid = ""
      continue
    }
    if (start < 0) continue
    if (parsed.name === "BEGIN") { depth++; continue }
    if (parsed.name === "END") {
      if (depth === 1 && String(parsed.value || "").toUpperCase() === "VEVENT") {
        if (foundUid === wantedUid) matches.push({ start: start, end: scanIndex })
        start = -1
        depth = 0
        foundUid = ""
      } else {
        depth--
      }
      continue
    }
    if (depth === 1 && parsed.name === "UID") foundUid = unescapeText(parsed.value).trim()
  }
  if (matches.length !== 1) return ""

  var replace = {}
  var names = Array.isArray(propertyNames) ? propertyNames : []
  for (var nameIndex = 0; nameIndex < names.length; nameIndex++) replace[String(names[nameIndex]).toUpperCase()] = true
  var target = matches[0]
  var out = lines.slice(0, target.start + 1)
  depth = 1
  for (var lineIndex = target.start + 1; lineIndex < target.end; lineIndex++) {
    var property = parseProperty(lines[lineIndex])
    if (property && property.name === "BEGIN") depth++
    if (!(property && depth === 1 && replace[property.name] === true))
      out.push(lines[lineIndex])
    if (property && property.name === "END") depth--
  }
  var additions = Array.isArray(replacementLines) ? replacementLines : []
  for (var addition = 0; addition < additions.length; addition++) out.push(additions[addition])
  out.push(lines[target.end])
  return out.concat(lines.slice(target.end + 1)).join("\r\n") + "\r\n"
}

function childNamed(component, name) {
  var children = component && Array.isArray(component.children) ? component.children : []
  var wanted = String(name || "").toUpperCase()
  for (var childIndex = 0; childIndex < children.length; childIndex++) {
    if (children[childIndex].name === wanted) return children[childIndex]
  }
  return null
}

function childrenNamed(component, name) {
  var children = component && Array.isArray(component.children) ? component.children : []
  var wanted = String(name || "").toUpperCase()
  var out = []
  for (var childIndex = 0; childIndex < children.length; childIndex++) {
    if (children[childIndex].name === wanted) out.push(children[childIndex])
  }
  return out
}

function property(component, name) {
  var list = component && Array.isArray(component.properties) ? component.properties : []
  var wanted = String(name || "").toUpperCase()
  for (var listIndex = 0; listIndex < list.length; listIndex++) {
    if (list[listIndex].name === wanted) return list[listIndex]
  }
  return null
}

function properties(component, name) {
  var list = component && Array.isArray(component.properties) ? component.properties : []
  var wanted = String(name || "").toUpperCase()
  var out = []
  for (var listIndex = 0; listIndex < list.length; listIndex++) {
    if (list[listIndex].name === wanted) out.push(list[listIndex])
  }
  return out
}

function textOf(component, name) {
  var found = property(component, name)
  return found ? unescapeText(found.value).trim() : ""
}

function twoDigits(value) {
  var number = Math.floor(Number(value) || 0)
  return (number < 10 ? "0" : "") + number
}

function parseDateValue(value) {
  var text = String(value || "").trim()
  var match = text.match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/)
  if (!match) return null
  var fields = {
    year: Number(match[1]),
    month: Number(match[2]),
    day: Number(match[3]),
    hour: Number(match[4] || 0),
    minute: Number(match[5] || 0),
    second: Number(match[6] || 0),
    utc: match[7] === "Z",
    dateOnly: match[4] === undefined
  }
  if (fields.month < 1 || fields.month > 12 || fields.day < 1 || fields.day > daysInMonth(fields.year, fields.month)) return null
  if (fields.hour > 23 || fields.minute > 59 || fields.second > 60) return null
  return fields
}

function parseOffsetMinutes(value) {
  var match = String(value || "").trim().match(/^([+-])(\d{2})(\d{2})(\d{2})?$/)
  if (!match) return null
  var hours = Number(match[2])
  var minutes = Number(match[3])
  var seconds = Number(match[4] || 0)
  if (hours > 23 || minutes > 59 || seconds > 59) return null
  var total = hours * 60 + minutes + seconds / 60
  return match[1] === "-" ? -total : total
}

// Docs: naiveKey compares wall-clock readings without applying a timezone offset.
function naiveKey(fields) {
  return Date.UTC(fields.year, fields.month - 1, fields.day,
    fields.hour, fields.minute, fields.second)
}

function daysInMonth(year, month) {
  if (month === 2) return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28
  return [4, 6, 9, 11].indexOf(month) >= 0 ? 30 : 31
}

// Docs: ordinal zero selects the first matching weekday for a timezone rule.
function nthWeekdayOfMonth(year, month, weekday, ordinal) {
  var total = daysInMonth(year, month)
  if (ordinal < 0) {
    for (var back = total; back >= 1; back--) {
      if (new Date(Date.UTC(year, month - 1, back)).getUTCDay() === weekday) {
        var skipped = -ordinal - 1
        var day = back - skipped * 7
        return day >= 1 ? day : 0
      }
    }
    return 0
  }
  var wanted = ordinal < 1 ? 1 : ordinal
  var seen = 0
  for (var forward = 1; forward <= total; forward++) {
    if (new Date(Date.UTC(year, month - 1, forward)).getUTCDay() !== weekday) continue
    seen++
    if (seen === wanted) return forward
  }
  return 0
}

var WEEKDAY_CODES = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

function weekdayIndex(code) {
  return WEEKDAY_CODES.indexOf(String(code || "").toUpperCase())
}

function parseRuleParts(value) {
  var parts = {}
  var pieces = String(value || "").split(";")
  for (var pieceIndex = 0; pieceIndex < pieces.length; pieceIndex++) {
    var equals = pieces[pieceIndex].indexOf("=")
    if (equals < 0) continue
    parts[pieces[pieceIndex].substring(0, equals).toUpperCase().trim()] =
      pieces[pieceIndex].substring(equals + 1).trim()
  }
  return parts
}

// Performance: parsed timezone plans are reused across recurrence lookups. Invariant: STANDARD precedes DAYLIGHT for Exchange fallback.
function zonePlan(timezone) {
  if (timezone.transitionPlan) return timezone.transitionPlan
  var rules = []
  var kinds = ["STANDARD", "DAYLIGHT"]
  for (var kindIndex = 0; kindIndex < kinds.length; kindIndex++) {
    var found = childrenNamed(timezone, kinds[kindIndex])
    for (var foundIndex = 0; foundIndex < found.length; foundIndex++) {
      var offset = parseOffsetMinutes(textOf(found[foundIndex], "TZOFFSETTO"))
      if (offset === null) continue
      rules.push(zoneRule(found[foundIndex], offset))
    }
  }
  // Invariant: ended timezone rules retain their final transition; a lone Exchange pair keeps its fallback.
  var history = rules.length > 2
  for (var ruleIndex = 0; ruleIndex < rules.length && !history; ruleIndex++) {
    if (rules[ruleIndex].until || rules[ruleIndex].listed) history = true
  }
  timezone.transitionPlan = { rules: rules, history: history, byYear: {} }
  return timezone.transitionPlan
}

// Invariant: RDATE can carry a later transition than DTSTART, so retain every dated transition by year.
function zoneRule(component, offset) {
  var rule = {
    offset: offset,
    from: parseOffsetMinutes(textOf(component, "TZOFFSETFROM")),
    start: parseDateValue(textOf(component, "DTSTART")),
    parts: null, until: null, dates: {}, dateYears: [], listed: false, lastYear: null
  }
  if (!rule.start) return rule
  var recurrence = property(component, "RRULE")
  if (recurrence) {
    rule.parts = parseRuleParts(recurrence.value)
    rule.until = rule.parts.UNTIL ? parseDateValue(rule.parts.UNTIL) : null
    rule.lastYear = rule.until ? rule.until.year : null
    return rule
  }
  var dates = [rule.start]
  var extra = properties(component, "RDATE")
  rule.listed = extra.length > 0
  for (var extraIndex = 0; extraIndex < extra.length; extraIndex++) {
    var values = String(extra[extraIndex].value || "").split(",")
    for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
      var value = parseDateValue(values[valueIndex])
      if (value) dates.push(value)
    }
  }
  for (var dateIndex = 0; dateIndex < dates.length; dateIndex++) {
    var year = dates[dateIndex].year
    if (!rule.dates[year]) {
      rule.dates[year] = []
      rule.dateYears.push(year)
    }
    rule.dates[year].push(naiveKey(dates[dateIndex]))
    if (rule.lastYear === null || year > rule.lastYear) rule.lastYear = year
  }
  rule.dateYears.sort(function(left, right) { return left - right })
  return rule
}

// Docs: timezone recurrence supports yearly BYMONTH with BYDAY or BYMONTHDAY; fixed histories use dated transitions.
function transitionsIn(rule, year) {
  if (!rule.start) return []
  if (!rule.parts) return rule.dates[year] || []
  var at = recurringTransition(rule, year)
  return at === null ? [] : [at]
}

function recurringTransition(rule, year) {
  var start = rule.start
  var parts = rule.parts
  var until = rule.until
  if (String(parts.FREQ || "").toUpperCase() !== "YEARLY") return null
  if (until && year > until.year + 1) return null
  var month = Math.floor(Number(parts.BYMONTH) || start.month)
  if (month < 1 || month > 12) return null

  var day = 0
  if (parts.BYDAY) {
    var match = String(parts.BYDAY).split(",")[0].match(/^([+-]?\d+)?([A-Za-z]{2})$/)
    if (!match) return null
    var index = weekdayIndex(match[2])
    if (index < 0) return null
    day = nthWeekdayOfMonth(year, month, index, Number(match[1] || 0))
  } else if (parts.BYMONTHDAY) {
    day = Math.floor(Number(String(parts.BYMONTHDAY).split(",")[0]) || 0)
    if (day < 0) day = daysInMonth(year, month) + day + 1
  } else {
    day = start.day
  }
  if (day < 1 || day > daysInMonth(year, month)) return null

  var at = Date.UTC(year, month - 1, day, start.hour, start.minute, start.second)
  // Invariant: compare UTC UNTIL against the transition using its previous offset; date-only UNTIL includes the entire day.
  if (until) {
    var reading = until.utc && rule.from !== null ? at - rule.from * 60000 : at
    var limit = naiveKey(until) + (until.dateOnly ? 86400000 - 1 : 0)
    if (reading > limit) return null
  }
  return at
}

function priorTransitionYears(rule, year, includeHistory) {
  var years = [year - 1]
  if (includeHistory && !rule.parts) {
    var previous = previousListedYear(rule.dateYears, year)
    return previous === null ? [] : [previous]
  }
  var last = includeHistory ? rule.lastYear : null
  if (rule.parts && last !== null && last < year - 1) years.push(last - 1, last, last + 1)
  return years
}

// Performance: binary-search occupied years so sparse histories retain their latest past transition without rescanning all dates.
function previousListedYear(years, year) {
  var low = 0
  var high = years.length
  while (low < high) {
    var middle = Math.floor((low + high) / 2)
    if (years[middle] < year) low = middle + 1
    else high = middle
  }
  return low > 0 ? years[low - 1] : null
}

function latestTransitionIn(rule, years, latest) {
  var result = latest
  for (var yearIndex = 0; yearIndex < years.length; yearIndex++) {
    var transitions = transitionsIn(rule, years[yearIndex])
    for (var transitionIndex = 0; transitionIndex < transitions.length; transitionIndex++) {
      var at = transitions[transitionIndex]
      if (result === null || at >= result.at) result = { at: at, offset: rule.offset }
    }
  }
  return result
}

// Invariant: retain the latest past transition and the current year; UTC UNTIL can place the final transition in an adjacent year.
function transitionsAround(plan, year) {
  if (plan.byYear[year]) return plan.byYear[year]
  var latest = null
  var within = []
  for (var ruleIndex = 0; ruleIndex < plan.rules.length; ruleIndex++) {
    var rule = plan.rules[ruleIndex]
    var years = priorTransitionYears(rule, year, plan.history)
    latest = latestTransitionIn(rule, years, latest)
    var found = transitionsIn(rule, year)
    for (var foundIndex = 0; foundIndex < found.length; foundIndex++) within.push({ at: found[foundIndex], offset: rule.offset })
  }
  plan.byYear[year] = latest ? [latest].concat(within) : within
  return plan.byYear[year]
}

// Invariant: inline VTIMEZONE rules determine the offset; an ambiguous repeated hour selects the later transition.
function zoneOffsetMinutes(timezone, fields) {
  if (!timezone) return null
  var plan = zonePlan(timezone)
  var rules = plan.rules
  if (rules.length === 0) return null
  if (rules.length === 1) return rules[0].offset

  var wanted = naiveKey(fields)
  var best = null
  var candidates = transitionsAround(plan, fields.year)
  for (var candidateIndex = 0; candidateIndex < candidates.length; candidateIndex++) {
    if (candidates[candidateIndex].at > wanted) continue
    if (best === null || candidates[candidateIndex].at >= best.at) best = candidates[candidateIndex]
  }
  if (best) return best.offset

  // Invariant: before the first transition, use the offset that transition moved away from.
  var earliest = null
  for (var ruleIndex = 0; ruleIndex < rules.length; ruleIndex++) {
    var openings = transitionsIn(rules[ruleIndex], fields.year - 1)
    for (var openingIndex = 0; openingIndex < openings.length; openingIndex++) {
      if (earliest === null || openings[openingIndex] < earliest.at) {
        earliest = { at: openings[openingIndex], offset: rules[ruleIndex].from }
      }
    }
  }
  return earliest && earliest.offset !== null ? earliest.offset : rules[0].offset
}

function timezoneFor(calendar, tzid) {
  var wanted = String(tzid || "").trim()
  if (wanted === "") return null
  var zones = childrenNamed(calendar, "VTIMEZONE")
  for (var zoneIndex = 0; zoneIndex < zones.length; zoneIndex++) {
    if (textOf(zones[zoneIndex], "TZID") === wanted) return zones[zoneIndex]
  }
  return null
}

var timezoneDocumentCache = {}
var timezoneDocumentKeys = []

function timezoneDocument(blocks) {
  var values = Array.isArray(blocks) ? blocks : []
  if (values.length === 0) return null
  var key = values.join("\r\n")
  if (timezoneDocumentCache[key]) return timezoneDocumentCache[key]
  var document = parse(["BEGIN:VCALENDAR"].concat(values, ["END:VCALENDAR"]).join("\r\n"))
  if (!document) return null
  timezoneDocumentCache[key] = document
  timezoneDocumentKeys.push(key)
  if (timezoneDocumentKeys.length > 16) {
    var oldest = timezoneDocumentKeys.shift()
    delete timezoneDocumentCache[oldest]
  }
  return document
}

function dateFieldsFromLine(line) {
  var found = parseProperty(line)
  return found ? parseDateValue(found.value) : null
}

// Invariant: recurrence and invitation times use the same inline timezone rules and unresolved UTC placeholder.
function timeInZone(fields, tzid, blocks) {
  var offset = zoneOffsetMinutes(timezoneFor(timezoneDocument(blocks), tzid), fields)
  if (offset !== null)
    return { ms: naiveKey(fields) - offset * 60000, resolved: true }
  return { ms: naiveKey(fields), resolved: false }
}

// Docs: resolved=false preserves the stated wall clock and exposes the unknown timezone to the view.
function resolveTime(found, calendar) {
  if (!found) return null
  var fields = parseDateValue(found.value)
  if (!fields) return null
  var tzid = String(found.params && found.params.TZID ? found.params.TZID : "").trim()

  if (fields.dateOnly) {
    return {
      ms: new Date(fields.year, fields.month - 1, fields.day).getTime(),
      allDay: true, tzid: "", resolved: true
    }
  }
  if (fields.utc) {
    return { ms: naiveKey(fields), allDay: false, tzid: "", resolved: true }
  }
  if (tzid !== "") {
    if (/^(UTC|GMT|Z|Etc\/UTC|Etc\/GMT)$/i.test(tzid))
      return { ms: naiveKey(fields), allDay: false, tzid: "", resolved: true }
    var offset = zoneOffsetMinutes(timezoneFor(calendar, tzid), fields)
    if (offset !== null) {
      return { ms: naiveKey(fields) - offset * 60000, allDay: false, tzid: tzid, resolved: true }
    }
    // Invariant: QML has no IANA timezone database API; an unresolved UTC placeholder must not inherit the machine's local zone.
    return {
      ms: naiveKey(fields),
      allDay: false, tzid: tzid, resolved: false
    }
  }
  // Invariant: floating iCalendar times use the reader's local clock.
  return {
    ms: new Date(fields.year, fields.month - 1, fields.day,
      fields.hour, fields.minute, fields.second).getTime(),
    allDay: false, tzid: "", resolved: true
  }
}

// Docs: parseDuration returns milliseconds, or zero for unsupported input.
function parseDuration(value) {
  var text = String(value || "").trim().toUpperCase()
  var match = text.match(/^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/)
  if (!match) return 0
  var total = Number(match[2] || 0) * 604800000
    + Number(match[3] || 0) * 86400000
    + Number(match[4] || 0) * 3600000
    + Number(match[5] || 0) * 60000
    + Number(match[6] || 0) * 1000
  return match[1] === "-" ? -total : total
}

var WEEKDAY_NAMES = {
  SU: "Sun", MO: "Mon", TU: "Tue", WE: "Wed", TH: "Thu", FR: "Fri", SA: "Sat"
}

var FREQUENCY_NAMES = {
  DAILY: ["Daily", "days"],
  WEEKLY: ["Weekly", "weeks"],
  MONTHLY: ["Monthly", "months"],
  YEARLY: ["Yearly", "years"]
}

// Invariant: unsupported recurrence descriptions use "Repeats" rather than inventing a schedule.
function describeRecurrence(value) {
  var text = String(value || "").trim()
  if (text === "") return ""
  var parts = parseRuleParts(text)
  var frequency = String(parts.FREQ || "").toUpperCase()
  var names = FREQUENCY_NAMES[frequency]
  if (!names) return "Repeats"

  var interval = Math.floor(Number(parts.INTERVAL) || 1)
  var sentence = interval > 1 ? "Every " + interval + " " + names[1] : names[0]

  if (parts.BYDAY && (frequency === "WEEKLY" || frequency === "MONTHLY")) {
    var codes = String(parts.BYDAY).split(",")
    var days = []
    for (var codeIndex = 0; codeIndex < codes.length; codeIndex++) {
      var match = codes[codeIndex].trim().match(/^([+-]?\d+)?([A-Za-z]{2})$/)
      if (!match) continue
      var name = WEEKDAY_NAMES[match[2].toUpperCase()]
      if (name) days.push(name)
    }
    if (days.length > 0) sentence += " on " + days.join(", ")
  }

  if (parts.COUNT) {
    var count = Math.floor(Number(parts.COUNT) || 0)
    if (count > 0) sentence += ", " + count + " times"
  } else if (parts.UNTIL) {
    var end = parseDateValue(parts.UNTIL)
    if (end) {
      sentence += ", until " + Mail.MONTHS[end.month - 1] + " " + end.day + ", " + end.year
    }
  }
  return sentence
}

function calendarAddress(found) {
  if (!found) return null
  var params = found.params || {}
  var email = String(found.value || "").replace(/^mailto:/i, "").trim()
  var name = unescapeText(params.CN || "").trim()
  return {
    name: name !== "" ? name : email,
    email: email,
    partstat: String(params.PARTSTAT || "").toUpperCase(),
    role: String(params.ROLE || "").toUpperCase(),
    optional: String(params.ROLE || "").toUpperCase() === "OPT-PARTICIPANT",
    resource: String(params.CUTYPE || "").toUpperCase() === "RESOURCE"
  }
}

function sameAddress(left, right) {
  return String(left || "").trim().toLowerCase() === String(right || "").trim().toLowerCase()
}

// Invariant: a forwarded invitation can be answered by an account absent from its original attendee list.
function attendeeFor(invite, address) {
  var list = invite && Array.isArray(invite.attendees) ? invite.attendees : []
  for (var listIndex = 0; listIndex < list.length; listIndex++) {
    if (sameAddress(list[listIndex].email, address)) return list[listIndex]
  }
  return null
}

function responseOf(invite, address) {
  var attendee = attendeeFor(invite, address)
  if (!attendee) return ""
  if (attendee.partstat === "ACCEPTED") return "accepted"
  if (attendee.partstat === "DECLINED") return "declined"
  if (attendee.partstat === "TENTATIVE") return "tentative"
  return ""
}

var MEET_URL = /https:\/\/meet\.google\.com\/[a-z0-9-]+/i
var CONFERENCE_URL = /https:\/\/(?:[a-z0-9-]+\.)*(?:zoom\.us|teams\.microsoft\.com|teams\.live\.com|meet\.google\.com|whereby\.com|webex\.com|chime\.aws)\/[^\s<>"]+/i

// Invariant: prefer the declared conference URL, then supported links in location and description.
function conferenceLink(event) {
  var declared = textOf(event, "X-GOOGLE-CONFERENCE")
  if (MEET_URL.test(declared)) return declared.match(MEET_URL)[0]

  var fields = [textOf(event, "LOCATION"), textOf(event, "DESCRIPTION")]
  for (var meetFieldIndex = 0; meetFieldIndex < fields.length; meetFieldIndex++) {
    var meet = fields[meetFieldIndex].match(MEET_URL)
    if (meet) return meet[0]
  }
  for (var conferenceFieldIndex = 0; conferenceFieldIndex < fields.length; conferenceFieldIndex++) {
    var other = fields[conferenceFieldIndex].match(CONFERENCE_URL)
    if (other) return other[0]
  }
  return ""
}

var METHODS = ["REQUEST", "REPLY", "CANCEL", "PUBLISH", "COUNTER", "REFRESH", "ADD", "DECLINECOUNTER"]

function normalizedMethod(value) {
  var text = String(value || "").toUpperCase().trim()
  return METHODS.indexOf(text) >= 0 ? text : ""
}

// Invariant: prefer inline calendar bytes over a fetchable attachment, including Gmail's two-part invitation shape.
function calendarPart(payload) {
  var carried = null
  var promised = null

  function walk(part, depth) {
    if (!part || depth > 12) return
    var mimeType = String(part.mimeType || "").split(";")[0].trim().toLowerCase()
    var filename = String(part.filename || "")
    var isCalendar = mimeType === "text/calendar" || mimeType === "application/ics"
      || (mimeType === "application/octet-stream" && /\.ics$/i.test(filename))
    var data = part.body && part.body.data ? String(part.body.data) : ""
    var attachmentId = part.body && part.body.attachmentId
      ? String(part.body.attachmentId) : ""
    // Performance: check encoded-size bounds before decoding a calendar on the drawing thread.
    var size = Math.max(Math.floor(Number(part.body && part.body.size) || 0),
      Math.floor(data.length * 3 / 4))
    if (isCalendar && size <= MAX_ICS_BYTES) {
      if (data !== "") {
        if (carried === null) carried = part
      } else if (attachmentId !== "" && promised === null) promised = part
    }
    var children = Array.isArray(part.parts) ? part.parts : []
    for (var childIndex = 0; childIndex < children.length; childIndex++) walk(children[childIndex], depth + 1)
  }

  walk(payload, 0)
  return carried !== null ? carried : promised
}

// Invariant: the calendar's METHOD overrides the MIME method parameter.
function partMethod(part) {
  if (!part) return ""
  var declared = Mail.contentTypeParam(String(part.mimeType || ""), "method")
  if (declared === "") {
    var headers = part && Array.isArray(part.headers) ? part.headers : []
    for (var headerIndex = 0; headerIndex < headers.length; headerIndex++) {
      if (String(headers[headerIndex].name || "").toLowerCase() !== "content-type") continue
      declared = Mail.contentTypeParam(headers[headerIndex].value, "method")
      if (declared !== "") break
    }
  }
  return normalizedMethod(declared)
}

function invitationFrom(text, fallbackMethod) {
  var calendar = parse(text)
  if (!calendar || calendar.name !== "VCALENDAR") return null
  var event = childNamed(calendar, "VEVENT")
  if (!event) return null

  return eventFromComponent(calendar, event, fallbackMethod)
}

// Invariant: calendar feeds and message invitations share event conversion so timezone and all-day semantics agree.
function eventsFrom(text, fallbackMethod) {
  var calendar = parse(text)
  if (!calendar || calendar.name !== "VCALENDAR") return []
  var components = childrenNamed(calendar, "VEVENT")
  var events = []
  for (var componentIndex = 0; componentIndex < components.length; componentIndex++) {
    var event = eventFromComponent(calendar, components[componentIndex], fallbackMethod)
    if (event) events.push(event)
  }
  return events
}

function eventFromComponent(calendar, event, fallbackMethod) {

  var uid = textOf(event, "UID")
  if (uid === "") return null

  var start = resolveTime(property(event, "DTSTART"), calendar)
  var end = resolveTime(property(event, "DTEND"), calendar)
  if (!end && start) {
    var span = parseDuration(textOf(event, "DURATION"))
    if (span > 0) end = { ms: start.ms + span, allDay: start.allDay, tzid: start.tzid, resolved: start.resolved }
  }

  var attendees = []
  var lines = properties(event, "ATTENDEE")
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    var attendee = calendarAddress(lines[lineIndex])
    if (attendee && attendee.email !== "") attendees.push(attendee)
  }

  var recurrence = property(event, "RRULE")
  var recurrenceId = resolveTime(property(event, "RECURRENCE-ID"), calendar)
  var excluded = []
  var exclusionLines = properties(event, "EXDATE")
  for (var exclusionIndex = 0; exclusionIndex < exclusionLines.length; exclusionIndex++) {
    var values = String(exclusionLines[exclusionIndex].value || "").split(",")
    for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
      var excludedAt = resolveTime({
        name: "EXDATE", params: exclusionLines[exclusionIndex].params,
        value: values[valueIndex], raw: exclusionLines[exclusionIndex].raw
      }, calendar)
      if (excludedAt) excluded.push(excludedAt.ms)
    }
  }

  return {
    method: normalizedMethod(textOf(calendar, "METHOD")) || normalizedMethod(fallbackMethod),
    uid: uid,
    sequence: Math.max(0, Math.floor(Number(textOf(event, "SEQUENCE")) || 0)),
    summary: textOf(event, "SUMMARY"),
    description: textOf(event, "DESCRIPTION"),
    location: textOf(event, "LOCATION"),
    status: String(textOf(event, "STATUS")).toUpperCase(),
    organizer: calendarAddress(property(event, "ORGANIZER")),
    attendees: attendees,
    start: start,
    end: end,
    recurrence: recurrence ? describeRecurrence(recurrence.value) : "",
    recurrenceRule: recurrence ? String(recurrence.value || "") : "",
    recurrenceIdMs: recurrenceId ? recurrenceId.ms : 0,
    excludedMs: excluded,
    meetLink: conferenceLink(event),
    // Invariant: reply time properties remain verbatim because the organiser matches its original calendar representation.
    source: {
      dtstart: rawLine(event, "DTSTART"),
      dtend: rawLine(event, "DTEND"),
      duration: rawLine(event, "DURATION"),
      recurrenceId: rawLine(event, "RECURRENCE-ID"),
      timezones: timezoneBlocks(calendar)
    }
  }
}

function rawLine(component, name) {
  var found = property(component, name)
  return found ? String(found.raw || "") : ""
}

function timezoneBlocks(calendar) {
  var zones = childrenNamed(calendar, "VTIMEZONE")
  var out = []
  for (var zoneIndex = 0; zoneIndex < zones.length; zoneIndex++) {
    out.push(["BEGIN:VTIMEZONE"].concat(zones[zoneIndex].lines, ["END:VTIMEZONE"]).join("\r\n"))
  }
  return out
}

function fromPayload(payload) {
  return fromPart(calendarPart(payload))
}

function fromPart(part) {
  if (!part) return null
  var text = Mail.decodePart(part)
  if (String(text || "").indexOf("BEGIN:VCALENDAR") < 0) return null
  return invitationFrom(text, partMethod(part))
}

function pendingPart(payload) {
  var part = calendarPart(payload)
  if (!part) return null
  return part.body && part.body.data ? null : part
}

// Invariant: fetched calendar bytes retain the MIME part's declared charset.
function fromAttachment(part, data) {
  if (!part) return null
  return fromPart({
    mimeType: part.mimeType,
    filename: part.filename,
    headers: part.headers,
    body: { data: String(data || "") }
  })
}

function clockOf(milliseconds, utc) {
  var at = new Date(milliseconds)
  return twoDigits(utc ? at.getUTCHours() : at.getHours()) + ":"
    + twoDigits(utc ? at.getUTCMinutes() : at.getMinutes())
}

function dayOf(milliseconds, utc) {
  var at = new Date(milliseconds)
  var day = utc ? at.getUTCDay() : at.getDay()
  var month = utc ? at.getUTCMonth() : at.getMonth()
  var date = utc ? at.getUTCDate() : at.getDate()
  var year = utc ? at.getUTCFullYear() : at.getFullYear()
  return Mail.WEEKDAYS[day] + ", " + Mail.MONTHS[month] + " " + date + ", " + year
}

function sameDay(first, second, utc) {
  var left = new Date(first)
  var right = new Date(second)
  return (utc ? left.getUTCFullYear() : left.getFullYear())
      === (utc ? right.getUTCFullYear() : right.getFullYear())
    && (utc ? left.getUTCMonth() : left.getMonth())
      === (utc ? right.getUTCMonth() : right.getMonth())
    && (utc ? left.getUTCDate() : left.getDate())
      === (utc ? right.getUTCDate() : right.getDate())
}

function formatWhen(invite) {
  var start = invite && invite.start ? invite.start : null
  if (!start) return ""
  var end = invite && invite.end ? invite.end : null
  var unresolved = !start.resolved && start.tzid !== ""

  if (start.allDay) {
    // Invariant: all-day DTEND is exclusive, so display the preceding day.
    if (end && end.ms - start.ms > 86400000) {
      return dayOf(start.ms) + " – " + dayOf(end.ms - 86400000)
    }
    return dayOf(start.ms) + " · all day"
  }

  var text = dayOf(start.ms, unresolved) + " · " + clockOf(start.ms, unresolved)
  if (end && end.ms > start.ms) {
    text += sameDay(start.ms, end.ms, unresolved)
      ? " – " + clockOf(end.ms, unresolved)
      : " – " + dayOf(end.ms, unresolved) + " " + clockOf(end.ms, unresolved)
  }
  if (unresolved) text += " (" + start.tzid + ")"
  return text
}

// Invariant: an absent duration stays empty rather than claiming a zero-minute event.
function formatDuration(invite) {
  var start = invite && invite.start ? invite.start : null
  var end = invite && invite.end ? invite.end : null
  if (!start || !end) return ""
  var minutes = Math.round((end.ms - start.ms) / 60000)
  if (minutes <= 0) return ""
  if (start.allDay) {
    var days = Math.round(minutes / 1440)
    return days <= 1 ? "" : days + " days"
  }
  if (minutes < 60) return minutes + " min"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  var text = hours + (hours === 1 ? " hour" : " hours")
  return rest === 0 ? text : text + " " + rest + " min"
}

function attendeeSummary(invite) {
  var list = invite && Array.isArray(invite.attendees) ? invite.attendees : []
  if (list.length === 0) return ""
  var yes = 0
  var no = 0
  var maybe = 0
  var awaiting = 0
  for (var listIndex = 0; listIndex < list.length; listIndex++) {
    if (list[listIndex].partstat === "ACCEPTED") yes++
    else if (list[listIndex].partstat === "DECLINED") no++
    else if (list[listIndex].partstat === "TENTATIVE") maybe++
    else awaiting++
  }
  var pieces = []
  if (yes > 0) pieces.push(yes + " yes")
  if (maybe > 0) pieces.push(maybe + " maybe")
  if (no > 0) pieces.push(no + " no")
  if (awaiting > 0) pieces.push(awaiting + " awaiting")
  var count = list.length + (list.length === 1 ? " guest" : " guests")
  return count + (pieces.length > 0 ? " · " + pieces.join(", ") : "")
}

function headline(invite) {
  if (!invite) return ""
  if (invite.method === "CANCEL" || String(invite.status || "") === "CANCELLED")
    return "Cancelled event"
  if (invite.method === "REPLY") return "Reply to an invitation"
  if (invite.method === "COUNTER") return "Proposed new time"
  if (invite.method === "REQUEST")
    return invite.sequence > 0 ? "Updated invitation" : "Invitation"
  return "Event"
}

function partstatLabel(partstat) {
  var value = String(partstat || "").toUpperCase()
  if (value === "ACCEPTED") return "Yes"
  if (value === "DECLINED") return "No"
  if (value === "TENTATIVE") return "Maybe"
  if (value === "DELEGATED") return "Delegated"
  return "Awaiting"
}

var PARTSTATS = {
  accepted: "ACCEPTED",
  declined: "DECLINED",
  tentative: "TENTATIVE"
}

var REPLY_WORDS = {
  accepted: "Accepted",
  declined: "Declined",
  tentative: "Tentative"
}

// Invariant: an account with no loaded address must not stringify into an ATTENDEE value.
function addressOf(me) {
  if (!me) return ""
  if (typeof me === "string") return me.trim()
  return String(me.email || "").trim()
}

function displayNameOf(me) {
  if (!me || typeof me === "string") return ""
  return String(me.name || "").trim()
}

function normalizedResponse(value) {
  var text = String(value || "").toLowerCase().trim()
  return PARTSTATS[text] ? text : ""
}

function foldIcsLine(line) {
  var text = String(line || "")
  var result = ""
  var octets = 0
  for (var characterIndex = 0; characterIndex < text.length; characterIndex++) {
    var code = text.charCodeAt(characterIndex)
    var character = text.charAt(characterIndex)
    var size = code < 0x80 ? 1 : (code < 0x800 ? 2 : 3)
    if (code >= 0xd800 && code <= 0xdbff && characterIndex + 1 < text.length) {
      var low = text.charCodeAt(characterIndex + 1)
      if (low >= 0xdc00 && low <= 0xdfff) {
        character += text.charAt(++characterIndex)
        size = 4
      }
    }
    if (octets + size > 75) {
      result += "\r\n "
      octets = 1
    }
    result += character
    octets += size
  }
  return result
}

function icsTimestamp(milliseconds) {
  var at = new Date(Number(milliseconds) || 0)
  return String(at.getUTCFullYear())
    + twoDigits(at.getUTCMonth() + 1) + twoDigits(at.getUTCDate()) + "T"
    + twoDigits(at.getUTCHours()) + twoDigits(at.getUTCMinutes())
    + twoDigits(at.getUTCSeconds()) + "Z"
}

// Invariant: an RSVP preserves UID and SEQUENCE and speaks for exactly one attendee.
function buildReply(invite, me, response, nowMilliseconds) {
  var answer = normalizedResponse(response)
  if (!invite || answer === "") return ""
  var address = addressOf(me)
  if (address === "") return ""
  var name = displayNameOf(me)

  var lines = ["BEGIN:VCALENDAR", "PRODID:-//Omamail//Omamail//EN", "VERSION:2.0", "METHOD:REPLY"]

  var zones = invite.source && Array.isArray(invite.source.timezones) ? invite.source.timezones : []
  for (var zoneIndex = 0; zoneIndex < zones.length; zoneIndex++) lines = lines.concat(zones[zoneIndex].split("\r\n"))

  lines.push("BEGIN:VEVENT")
  lines.push("UID:" + escapeText(invite.uid))
  lines.push("SEQUENCE:" + Math.max(0, Math.floor(Number(invite.sequence) || 0)))
  lines.push("DTSTAMP:" + icsTimestamp(nowMilliseconds === undefined ? Date.now() : nowMilliseconds))
  if (invite.organizer && invite.organizer.email !== "")
    lines.push("ORGANIZER:mailto:" + invite.organizer.email)
  lines.push("ATTENDEE;PARTSTAT=" + PARTSTATS[answer]
    + (name !== "" ? ";CN=" + quoteParam(name) : "")
    + ":mailto:" + address)
  if (invite.summary !== "") lines.push("SUMMARY:" + escapeText(invite.summary))

  var source = invite.source || {}
  if (source.recurrenceId) lines.push(source.recurrenceId)
  if (source.dtstart) lines.push(source.dtstart)
  if (source.dtend) lines.push(source.dtend)
  else if (source.duration) lines.push(source.duration)

  lines.push("REQUEST-STATUS:2.0;Success")
  lines.push("END:VEVENT")
  lines.push("END:VCALENDAR")

  var folded = []
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    if (String(lines[lineIndex] || "").trim() !== "") folded.push(foldIcsLine(lines[lineIndex]))
  }
  return folded.join("\r\n") + "\r\n"
}

// Invariant: quoted calendar parameters cannot contain an embedded quote; discard it rather than introduce another parameter.
function quoteParam(value) {
  return "\"" + String(value || "").replace(/["\r\n]/g, "") + "\""
}

// Invariant: an RSVP addresses only the organiser.
function replyRecipient(invite) {
  return invite && invite.organizer ? String(invite.organizer.email || "") : ""
}

function replySubject(invite, response) {
  var answer = normalizedResponse(response)
  if (answer === "") return ""
  var summary = String(invite && invite.summary ? invite.summary : "").trim()
  return REPLY_WORDS[answer] + ": " + (summary !== "" ? summary : "(no subject)")
}

function replyBody(invite, me, response) {
  var answer = normalizedResponse(response)
  if (answer === "") return ""
  var who = displayNameOf(me)
  if (who === "") who = addressOf(me)
  var word = answer === "accepted" ? "accepted" : (answer === "declined" ? "declined" : "tentatively accepted")
  return who + " has " + word + " this invitation."
}

function replyFields(invite, me, response, nowMilliseconds) {
  var answer = normalizedResponse(response)
  if (!invite || answer === "") return null
  var to = replyRecipient(invite)
  if (to === "") return null
  var calendar = buildReply(invite, me, answer, nowMilliseconds)
  if (calendar === "") return null
  return {
    to: to,
    subject: replySubject(invite, answer),
    body: replyBody(invite, me, answer),
    calendar: { method: "REPLY", text: calendar }
  }
}

// Invariant: cache the local RSVP response because the organiser's original attachment does not change after sending.
function withResponse(invite, address, response) {
  var answer = normalizedResponse(response)
  if (!invite || answer === "") return invite
  var wanted = String(address || "").trim()
  if (wanted === "") return invite

  var list = Array.isArray(invite.attendees) ? invite.attendees : []
  var updated = []
  var found = false
  for (var listIndex = 0; listIndex < list.length; listIndex++) {
    if (!sameAddress(list[listIndex].email, wanted)) {
      updated.push(list[listIndex])
      continue
    }
    found = true
    updated.push({
      name: list[listIndex].name, email: list[listIndex].email,
      partstat: PARTSTATS[answer], role: list[listIndex].role,
      optional: list[listIndex].optional, resource: list[listIndex].resource
    })
  }
  if (!found) {
    updated.push({
      name: wanted, email: wanted, partstat: PARTSTATS[answer],
      role: "REQ-PARTICIPANT", optional: false, resource: false
    })
  }

  // Invariant: replace the invitation object so QML observes the updated attendee state.
  var copy = {}
  for (var key in invite) copy[key] = invite[key]
  copy.attendees = updated
  return copy
}

// Invariant: cancelled events, replies, and the organiser's own event cannot be answered.
function canRespond(invite, address) {
  if (!invite || invite.method !== "REQUEST") return false
  if (String(invite.status || "") === "CANCELLED") return false
  if (replyRecipient(invite) === "") return false
  return !sameAddress(replyRecipient(invite), address)
}

.pragma library

.import "../message/Calendar.js" as Ics

function two(value) {
  var number = Math.floor(Number(value) || 0)
  return (number < 10 ? "0" : "") + number
}

function utcStamp(ms) {
  var date = new Date(Number(ms) || 0)
  return date.getUTCFullYear() + two(date.getUTCMonth() + 1) + two(date.getUTCDate())
    + "T" + two(date.getUTCHours()) + two(date.getUTCMinutes())
    + two(date.getUTCSeconds()) + "Z"
}

function caldavReport(startMs, endMs) {
  return '<?xml version="1.0" encoding="utf-8"?>'
    + '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
    + '<d:prop><d:getetag/><c:calendar-data/></d:prop>'
    + '<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">'
    + '<c:time-range start="' + utcStamp(startMs) + '" end="' + utcStamp(endMs) + '"/>'
    + '</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>'
}

function decodeXml(value) {
  return String(value || "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, function(_whole, digits) {
      return String.fromCharCode(Number(digits))
    })
    .replace(/&#x([0-9a-f]+);/gi, function(_whole, digits) {
      return String.fromCharCode(parseInt(digits, 16))
    })
    .replace(/&amp;/g, "&")
}

// Invariant: CalDAV XML text may use entities or CDATA; entity decoding inside CDATA would corrupt event text.
function decodeXmlText(value) {
  var text = String(value || "")
  var out = ""
  var index = 0
  while (true) {
    // Invariant: XML CDATA delimiters are case-sensitive.
    var start = text.indexOf("<![CDATA[", index)
    if (start < 0) break
    var end = text.indexOf("]]>", start + 9)
    if (end < 0) break
    out += decodeXml(text.substring(index, start)) + text.substring(start + 9, end)
    index = end + 3
  }
  return out + decodeXml(text.substring(index))
}

function tagText(block, localName) {
  var name = String(localName || "").replace(/[^A-Za-z0-9_-]/g, "")
  if (name === "") return ""
  var pattern = new RegExp("<(?:[A-Za-z0-9_-]+:)?" + name
    + "(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[A-Za-z0-9_-]+:)?" + name + ">", "i")
  var match = pattern.exec(String(block || ""))
  return match ? decodeXmlText(match[1]) : ""
}

function caldavResponses(xml) {
  var input = String(xml || "")
  var pattern = /<(?:[A-Za-z0-9_-]+:)?response(?:\s[^>]*)?>([\s\S]*?)<\/(?:[A-Za-z0-9_-]+:)?response>/gi
  var out = []
  var match
  while ((match = pattern.exec(input)) !== null) {
    var data = tagText(match[1], "calendar-data")
    if (data !== "") out.push({ href: tagText(match[1], "href"), data: data })
  }
  return out
}

function recurrenceParts(value) {
  var out = {}
  var pieces = String(value || "").split(";")
  for (var pieceIndex = 0; pieceIndex < pieces.length; pieceIndex++) {
    var equals = pieces[pieceIndex].indexOf("=")
    if (equals < 0) continue
    out[pieces[pieceIndex].substring(0, equals).toUpperCase().trim()] =
      pieces[pieceIndex].substring(equals + 1).trim()
  }
  return out
}

var RECURRENCE_DAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

function datePart(date, localName, utcName, utc) {
  return utc ? date[utcName]() : date[localName]()
}

function calendarDayNumber(date, utc) {
  return Math.floor(Date.UTC(
    datePart(date, "getFullYear", "getUTCFullYear", utc),
    datePart(date, "getMonth", "getUTCMonth", utc),
    datePart(date, "getDate", "getUTCDate", utc)) / 86400000)
}

function weekNumber(date, utc) {
  var day = calendarDayNumber(date, utc)
  var weekday = datePart(date, "getDay", "getUTCDay", utc)
  return Math.floor((day - ((weekday + 6) % 7)) / 7)
}

function nthWeekday(date, utc) {
  return Math.floor((datePart(date, "getDate", "getUTCDate", utc) - 1) / 7) + 1
}

function lastWeekday(date, utc) {
  var year = datePart(date, "getFullYear", "getUTCFullYear", utc)
  var month = datePart(date, "getMonth", "getUTCMonth", utc)
  var last = utc ? new Date(Date.UTC(year, month + 1, 0)).getUTCDate()
    : new Date(year, month + 1, 0).getDate()
  return -Math.floor((last - datePart(date, "getDate", "getUTCDate", utc)) / 7) - 1
}

function matchesByDay(date, raw, utc) {
  var values = String(raw || "").split(",")
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    var match = values[valueIndex].trim().toUpperCase().match(/^([+-]?\d+)?([A-Z]{2})$/)
    if (!match || RECURRENCE_DAYS[datePart(date, "getDay", "getUTCDay", utc)] !== match[2])
      continue
    if (!match[1]) return true
    var ordinal = Number(match[1])
    if (ordinal > 0 && nthWeekday(date, utc) === ordinal) return true
    if (ordinal < 0 && lastWeekday(date, utc) === ordinal) return true
  }
  return false
}

function matchesNumberList(value, raw) {
  var values = String(raw || "").split(",")
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    if (Number(values[valueIndex]) === Number(value)) return true
  }
  return false
}

function recurrenceUntil(value) {
  var text = String(value || "").trim()
  var match = text.match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/)
  if (!match) return 0
  if (match[7]) return Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]),
    Number(match[4] || 0), Number(match[5] || 0), Number(match[6] || 0))
  return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]),
    Number(match[4] || 0), Number(match[5] || 0), Number(match[6] || 0)).getTime()
}

function recurrenceStarts(event, rangeStart, rangeEnd) {
  if (!event || !event.start || !event.recurrenceRule) return []
  var parts = recurrenceParts(event.recurrenceRule)
  var frequency = String(parts.FREQ || "").toUpperCase()
  if (["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].indexOf(frequency) < 0) return []
  var interval = Math.max(1, Math.floor(Number(parts.INTERVAL) || 1))
  var countLimit = Math.max(0, Math.floor(Number(parts.COUNT) || 0))
  var until = recurrenceUntil(parts.UNTIL)
  var tzid = String(event.start.tzid || "")
  var source = event.source || {}
  var wallFields = tzid !== "" ? Ics.dateFieldsFromLine(source.dtstart) : null
  var zoned = !!wallFields && !wallFields.dateOnly
  var base = zoned
    ? new Date(Date.UTC(wallFields.year, wallFields.month - 1, wallFields.day,
        wallFields.hour, wallFields.minute, wallFields.second))
    : new Date(Number(event.start.ms))
  var cursor = new Date(base.getTime())
  var utc = zoned
    || !!(event.source && /Z\s*$/i.test(String(event.source.dtstart || "")))
  var out = []
  var count = 0
  var rangeLimit = Number(rangeEnd) || base.getTime()
  var limit = zoned ? rangeLimit + 86400000
    : Math.min(rangeLimit, until > 0 ? until + 1 : rangeLimit)

  // Performance: recurrence deltas allow skipping old days unless COUNT requires counting from the base.
  var from = Number(rangeStart) || 0
  if (countLimit === 0 && from > 0) {
    var skipped = Math.floor((from - 2 * 86400000 - base.getTime()) / 86400000)
    if (skipped > 0) {
      if (utc) cursor.setUTCDate(cursor.getUTCDate() + skipped)
      else cursor.setDate(cursor.getDate() + skipped)
    }
  }

  for (var scanned = 0; scanned < 10000 && cursor.getTime() < limit; scanned++) {
    var cursorYear = datePart(cursor, "getFullYear", "getUTCFullYear", utc)
    var baseYear = datePart(base, "getFullYear", "getUTCFullYear", utc)
    var cursorMonth = datePart(cursor, "getMonth", "getUTCMonth", utc)
    var baseMonth = datePart(base, "getMonth", "getUTCMonth", utc)
    var cursorDate = datePart(cursor, "getDate", "getUTCDate", utc)
    var baseDate = datePart(base, "getDate", "getUTCDate", utc)
    var dayDelta = calendarDayNumber(cursor, utc) - calendarDayNumber(base, utc)
    var monthDelta = (cursorYear - baseYear) * 12 + cursorMonth - baseMonth
    var yearDelta = cursorYear - baseYear
    var matches = false
    if (frequency === "DAILY") {
      matches = dayDelta >= 0 && dayDelta % interval === 0
    } else if (frequency === "WEEKLY") {
      var weekdayMatch = parts.BYDAY
        ? matchesByDay(cursor, parts.BYDAY, utc)
        : datePart(cursor, "getDay", "getUTCDay", utc)
          === datePart(base, "getDay", "getUTCDay", utc)
      matches = weekdayMatch && (weekNumber(cursor, utc) - weekNumber(base, utc)) % interval === 0
    } else if (frequency === "MONTHLY") {
      var monthDayMatch = parts.BYMONTHDAY
        ? matchesNumberList(cursorDate, parts.BYMONTHDAY)
        : (parts.BYDAY ? matchesByDay(cursor, parts.BYDAY, utc)
          : cursorDate === baseDate)
      matches = monthDelta >= 0 && monthDelta % interval === 0 && monthDayMatch
    } else if (frequency === "YEARLY") {
      var monthMatch = parts.BYMONTH
        ? matchesNumberList(cursorMonth + 1, parts.BYMONTH)
        : cursorMonth === baseMonth
      var yearDayMatch = parts.BYMONTHDAY
        ? matchesNumberList(cursorDate, parts.BYMONTHDAY)
        : (parts.BYDAY ? matchesByDay(cursor, parts.BYDAY, utc)
          : cursorDate === baseDate)
      matches = yearDelta >= 0 && yearDelta % interval === 0 && monthMatch && yearDayMatch
    }
    var occurrenceMs = cursor.getTime()
    if (zoned) {
      occurrenceMs = Ics.timeInZone({
        year: cursor.getUTCFullYear(), month: cursor.getUTCMonth() + 1,
        day: cursor.getUTCDate(), hour: cursor.getUTCHours(),
        minute: cursor.getUTCMinutes(), second: cursor.getUTCSeconds()
      }, tzid, source.timezones).ms
    }
    if (matches && occurrenceMs >= Number(event.start.ms)) {
      count++
      if (countLimit > 0 && count > countLimit) break
      if (!until || occurrenceMs <= until) out.push(occurrenceMs)
    }
    if (until && occurrenceMs > until) break
    if (utc) cursor.setUTCDate(cursor.getUTCDate() + 1)
    else cursor.setDate(cursor.getDate() + 1)
  }
  return out
}

function eventInRange(event, startMs, endMs) {
  if (!event || !event.start) return false
  var start = Number(event.start.ms)
  var end = event.end ? Number(event.end.ms) : start + 1
  return start < Number(endMs) && end > Number(startMs)
}

function occurrenceOf(event, startMs) {
  var copy = {}
  for (var key in event) copy[key] = event[key]
  var delta = Number(startMs) - Number(event.start.ms)
  copy.start = { ms: Number(startMs), allDay: event.start.allDay,
    tzid: event.start.tzid, resolved: event.start.resolved }
  copy.end = event.end ? { ms: Number(event.end.ms) + delta, allDay: event.end.allDay,
    tzid: event.end.tzid, resolved: event.end.resolved } : null
  copy.recurrenceIdMs = Number(startMs)
  return copy
}

function expandRecurringEvents(events, startMs, endMs) {
  var values = Array.isArray(events) ? events : []
  var masters = []
  var overrides = {}
  var standalone = []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    var item = values[valueIndex]
    if (!item) continue
    if (item.recurrenceIdMs) {
      overrides[String(item.uid) + "\n" + Number(item.recurrenceIdMs)] = item
    } else if (item.recurrenceRule) masters.push(item)
    else standalone.push(item)
  }
  var out = []
  var usedOverrides = {}
  for (var standaloneIndex = 0; standaloneIndex < standalone.length; standaloneIndex++) {
    if (standalone[standaloneIndex].status !== "CANCELLED" && eventInRange(standalone[standaloneIndex], startMs, endMs))
      out.push(standalone[standaloneIndex])
  }
  for (var masterIndex = 0; masterIndex < masters.length; masterIndex++) {
    var master = masters[masterIndex]
    if (master.status === "CANCELLED") continue
    var excluded = {}
    var exclusions = Array.isArray(master.excludedMs) ? master.excludedMs : []
    for (var exclusionIndex = 0; exclusionIndex < exclusions.length; exclusionIndex++) excluded[Number(exclusions[exclusionIndex])] = true
    var starts = recurrenceStarts(master, startMs, endMs)
    for (var startIndex = 0; startIndex < starts.length; startIndex++) {
      var key = String(master.uid) + "\n" + Number(starts[startIndex])
      var replacement = overrides[key]
      if (replacement) {
        usedOverrides[key] = true
        if (replacement.status !== "CANCELLED" && eventInRange(replacement, startMs, endMs))
          out.push(replacement)
      } else if (!excluded[Number(starts[startIndex])]) {
        var occurrence = occurrenceOf(master, starts[startIndex])
        if (eventInRange(occurrence, startMs, endMs)) out.push(occurrence)
      }
    }
  }
  for (var overrideKey in overrides) {
    var detached = overrides[overrideKey]
    if (!usedOverrides[overrideKey] && detached.status !== "CANCELLED"
        && eventInRange(detached, startMs, endMs)) out.push(detached)
  }
  out.sort(compareEvents)
  return out
}

function eventsFromCaldav(xml, sourceId, rangeStart, rangeEnd) {
  var responses = caldavResponses(xml)
  var out = []
  for (var responseIndex = 0; responseIndex < responses.length; responseIndex++) {
    var events = Ics.eventsFrom(responses[responseIndex].data)
    for (var eventIndex = 0; eventIndex < events.length; eventIndex++) {
      events[eventIndex].sourceId = String(sourceId || "")
      events[eventIndex].href = responses[responseIndex].href
      // Invariant: CalDAV replaces the entire resource; preserve fields the editor cannot model.
      events[eventIndex].calendarData = responses[responseIndex].data
      out.push(events[eventIndex])
    }
  }
  if (Number(rangeStart) && Number(rangeEnd))
    return expandRecurringEvents(out, Number(rangeStart), Number(rangeEnd))
  out = out.filter(function(event) { return event.status !== "CANCELLED" })
  out.sort(compareEvents)
  return out
}

function googleMoment(value, dateOnly) {
  var text = String(value || "")
  if (text === "") return null
  var ms = dateOnly
    ? new Date(Number(text.substring(0, 4)), Number(text.substring(5, 7)) - 1,
        Number(text.substring(8, 10))).getTime()
    : Date.parse(text)
  if (!isFinite(ms)) return null
  return { ms: ms, allDay: dateOnly, tzid: "", resolved: true }
}

function eventsFromGoogle(payload, sourceId) {
  var items = payload && Array.isArray(payload.items) ? payload.items : []
  var out = []
  for (var itemIndex = 0; itemIndex < items.length; itemIndex++) {
    var item = items[itemIndex] || {}
    if (String(item.status || "").toLowerCase() === "cancelled") continue
    var start = googleMoment(item.start && (item.start.dateTime || item.start.date),
      !!(item.start && item.start.date && !item.start.dateTime))
    if (!start) continue
    var end = googleMoment(item.end && (item.end.dateTime || item.end.date),
      !!(item.end && item.end.date && !item.end.dateTime))
    out.push({
      method: "", uid: String(item.iCalUID || item.id || ""),
      // Invariant: Google writes require the item ID, which can differ from iCalUID for recurring occurrences.
      googleId: String(item.id || ""),
      etag: String(item.etag || ""),
      recurringEventId: String(item.recurringEventId || ""),
      originalStartTime: item.originalStartTime || null,
      timeZone: String(item.start && item.start.timeZone || payload.timeZone || ""),
      reminders: item.reminders || { useDefault: true },
      conferenceData: item.conferenceData || null,
      eventType: String(item.eventType || "default"),
      guestsCanModify: item.guestsCanModify === true,
      transparency: String(item.transparency || "opaque"),
      visibility: String(item.visibility || "default"),
      sequence: Math.max(0, Math.floor(Number(item.sequence) || 0)),
      summary: String(item.summary || "Untitled event"),
      description: String(item.description || ""), location: String(item.location || ""),
      status: String(item.status || "").toUpperCase(), organizer: item.organizer || null,
      attendees: Array.isArray(item.attendees) ? item.attendees : [],
      recurrenceLines: Array.isArray(item.recurrence) ? item.recurrence.slice() : [],
      start: start, end: end, recurrence: Array.isArray(item.recurrence)
        ? item.recurrence.join("; ") : "", meetLink: String(item.hangoutLink || ""),
      sourceId: String(sourceId || ""), href: String(item.htmlLink || ""), source: null
    })
  }
  out.sort(compareEvents)
  return out
}

function eventKey(event) {
  if (!event) return ""
  return String(event.sourceId || "") + "\n" + String(event.googleId || event.graphId
    || String(event.uid || "") + "\n" + String(event.recurrenceIdMs || event.start && event.start.ms || ""))
}

var GRAPH_ROOT = "https://graph.microsoft.com/v1.0"

// Invariant: Graph timestamps omit an offset and name their timezone separately.
function graphMoment(value, allDay) {
  var text = String(value && value.dateTime || "")
  if (text === "") return null
  var ms
  if (allDay) {
    ms = new Date(Number(text.substring(0, 4)), Number(text.substring(5, 7)) - 1,
      Number(text.substring(8, 10))).getTime()
  } else {
    ms = Date.parse(text.replace(/(\.\d+)?$/, "") + "Z")
  }
  if (!isFinite(ms)) return null
  return { ms: ms, allDay: !!allDay, tzid: "", resolved: true }
}

function graphPerson(value) {
  var address = value && value.emailAddress ? value.emailAddress : {}
  return { email: String(address.address || ""), displayName: String(address.name || "") }
}

function eventsFromGraph(payload, sourceId) {
  var items = payload && Array.isArray(payload.value) ? payload.value : []
  var out = []
  for (var itemIndex = 0; itemIndex < items.length; itemIndex++) {
    var item = items[itemIndex] || {}
    if (item.isCancelled === true) continue
    var allDay = item.isAllDay === true
    var start = graphMoment(item.start, allDay)
    if (!start) continue
    var attendees = Array.isArray(item.attendees) ? item.attendees : []
    var people = []
    for (var attendeeIndex = 0; attendeeIndex < attendees.length; attendeeIndex++) people.push(graphPerson(attendees[attendeeIndex]))
    out.push({
      method: "", uid: String(item.iCalUId || item.id || ""),
      // Invariant: Graph writes require its item ID; occurrence identities differ from their series master.
      graphId: String(item.id || ""),
      sequence: 0,
      summary: String(item.subject || "Untitled event"),
      description: String(item.bodyPreview || ""),
      location: String(item.location && item.location.displayName || ""),
      status: "CONFIRMED", organizer: item.organizer ? graphPerson(item.organizer) : null,
      attendees: people,
      start: start, end: graphMoment(item.end, allDay),
      recurrence: "", meetLink: String(item.onlineMeeting && item.onlineMeeting.joinUrl || ""),
      sourceId: String(sourceId || ""), href: String(item.webLink || ""), source: null
    })
  }
  out.sort(compareEvents)
  return out
}

// Invariant: Graph timed writes use UTC timestamps; all-day writes use local date boundaries.
function graphStamp(ms) {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "")
}

function graphEventBody(fields, allDay) {
  var body = {
    subject: fields.title,
    body: { contentType: "text", content: String(fields.description || "") },
    location: { displayName: String(fields.location || "") },
    isAllDay: allDay === true
  }
  if (allDay === true) {
    body.start = { dateTime: isoDate(new Date(fields.start)) + "T00:00:00", timeZone: "UTC" }
    body.end = { dateTime: isoDate(new Date(fields.end)) + "T00:00:00", timeZone: "UTC" }
  } else {
    body.start = { dateTime: graphStamp(fields.start), timeZone: "UTC" }
    body.end = { dateTime: graphStamp(fields.end), timeZone: "UTC" }
  }
  return body
}

// Invariant: provider-facing messages must not expose native backend diagnostics.
function nativeRequestError(kind) {
  if (kind === "microsoft")
    return "Microsoft calendar request failed. Check Graph permissions in Settings, then sign in again"
  if (kind === "google")
    return "Google could not complete this calendar request. Refresh the event and try again"
  if (kind === "caldav")
    return "CalDAV calendar request failed. Check its server address and password in Settings"
  // Invariant: iCloud calendar access uses the mailbox app-specific password.
  if (kind === "icloud")
    return "iCloud calendar request failed. Check the mailbox's app-specific password in Settings"
  return "The calendar request failed"
}

function icsText(value) {
  return String(value || "").replace(/\\/g, "\\\\").replace(/\r\n?|\n/g, "\\n")
    .replace(/,/g, "\\,").replace(/;/g, "\\;")
}

function icsUtc(ms) {
  return new Date(Number(ms)).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z")
}

// Invariant: date-only ICS stamps use local calendar dates, including daylight-saving transitions.
function icsDate(ms) {
  var date = new Date(Number(ms))
  return date.getFullYear() + two(date.getMonth() + 1) + two(date.getDate())
}

function recurrenceRule(raw) {
  var value = raw || {}
  if (value.enabled !== true) return { ok: true, rule: "" }
  var frequency = String(value.frequency || "").toUpperCase()
  if (["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].indexOf(frequency) < 0)
    return { ok: false, error: "Choose how often the event repeats" }
  var interval = Math.floor(Number(value.interval))
  if (!isFinite(interval) || interval < 1)
    return { ok: false, error: "Repeat interval must be at least 1" }
  var countText = String(value.count === undefined ? "" : value.count).trim()
  var count = countText === "" ? 0 : Math.floor(Number(countText))
  if (countText !== "" && (!isFinite(count) || count < 1))
    return { ok: false, error: "Occurrence count must be at least 1" }
  var rule = "FREQ=" + frequency + ";INTERVAL=" + interval
  if (count > 0) rule += ";COUNT=" + count
  return { ok: true, rule: rule }
}

function recurrenceIntervalUnit(frequency, interval) {
  var units = { DAILY: "day", WEEKLY: "week", MONTHLY: "month", YEARLY: "year" }
  var unit = units[String(frequency || "").toUpperCase()] || "interval"
  return Number(interval) === 1 ? unit : unit + "s"
}

function editorDateRange(firstDate, firstTime, lastDate, lastTime, allDay) {
  function parse(dateText, timeText) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(dateText) || !/^([01]\d|2[0-3]):[0-5]\d$/.test(timeText)) return null
    var value = new Date(dateText + "T" + timeText + ":00")
    if (!isFinite(value.getTime()) || isoDate(value) !== dateText
        || two(value.getHours()) + ":" + two(value.getMinutes()) !== timeText) return null
    return value
  }
  var start = parse(String(firstDate), allDay ? "00:00" : String(firstTime))
  var end = parse(String(lastDate), allDay ? "00:00" : String(lastTime))
  if (!start || !end) return {ok:false,error:allDay ? "Enter valid dates (YYYY-MM-DD)" : "Enter valid dates (YYYY-MM-DD) and times (HH:mm)"}
  if (allDay) end.setDate(end.getDate() + 1)
  if (end.getTime() <= start.getTime()) return {ok:false,error:allDay
    ? "Last day must be on or after the first day" : "End date and time must be after the start"}
  return {ok:true,error:"",startMs:start.getTime(),endMs:end.getTime()}
}

function validateEventFields(fields) {
  var value = fields || {}
  var title = String(value.title || "").trim()
  var start = Number(value.startMs)
  var end = Number(value.endMs)
  if (title === "") return { ok: false, error: "Add an event title" }
  if (!isFinite(start) || !isFinite(end)) return { ok: false, error: "Add valid start and end times" }
  if (end <= start) return { ok: false, error: "End time must be after start time" }
  return { ok: true, title: title, start: start, end: end,
    description: String(value.description || ""), location: String(value.location || "") }
}

function veventLines(uid, sequence, stampMs, fields, rule, allDay) {
  var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Omamail//Calendar//EN",
    "BEGIN:VEVENT", "UID:" + uid, "DTSTAMP:" + icsUtc(stampMs)]
  if (sequence > 0) lines.push("SEQUENCE:" + sequence)
  // Invariant: all-day events use dates with an exclusive end, never midnight timestamps.
  if (allDay === true)
    lines.push("DTSTART;VALUE=DATE:" + icsDate(fields.start),
      "DTEND;VALUE=DATE:" + icsDate(fields.end))
  else
    lines.push("DTSTART:" + icsUtc(fields.start), "DTEND:" + icsUtc(fields.end))
  lines.push("SUMMARY:" + icsText(fields.title))
  if (fields.description !== "") lines.push("DESCRIPTION:" + icsText(fields.description))
  if (fields.location !== "") lines.push("LOCATION:" + icsText(fields.location))
  if (rule !== "") lines.push("RRULE:" + rule)
  lines.push("END:VEVENT", "END:VCALENDAR", "")
  return lines
}

function editableEventLines(sequence, stampMs, fields, allDay) {
  var lines = ["DTSTAMP:" + icsUtc(stampMs), "SEQUENCE:" + sequence]
  if (allDay === true)
    lines.push("DTSTART;VALUE=DATE:" + icsDate(fields.start),
      "DTEND;VALUE=DATE:" + icsDate(fields.end))
  else
    lines.push("DTSTART:" + icsUtc(fields.start), "DTEND:" + icsUtc(fields.end))
  lines.push("SUMMARY:" + icsText(fields.title))
  if (fields.description !== "") lines.push("DESCRIPTION:" + icsText(fields.description))
  if (fields.location !== "") lines.push("LOCATION:" + icsText(fields.location))
  return lines
}

function googleEventBody(fields, allDay) {
  var body = {
    summary: fields.title, description: fields.description, location: fields.location
  }
  // Invariant: Google all-day endpoints use date fields and an exclusive end.
  if (allDay === true) {
    body.start = { date: isoDate(new Date(fields.start)) }
    body.end = { date: isoDate(new Date(fields.end)) }
  } else {
    body.start = { dateTime: new Date(fields.start).toISOString() }
    body.end = { dateTime: new Date(fields.end).toISOString() }
  }
  return body
}

function googleEventPatch(fields, allDay, existingAllDay) {
  var body = googleEventBody(fields, allDay)
  if (existingAllDay === allDay) return body
  // Invariant: Google PATCH retains omitted nested fields; clear the alternate date/dateTime representation.
  if (allDay) {
    body.start.dateTime = null
    body.end.dateTime = null
    body.start.timeZone = null
    body.end.timeZone = null
  } else {
    body.start.date = null
    body.end.date = null
  }
  return body
}

function googleOptions(body, fields, source, existing) {
  var next = JSON.parse(JSON.stringify(body))
  if (existing && fields.changeRecurrence === true) {
    if (existing.recurringEventId) return { ok: false, error: "Open the entire series to change repetition" }
    var recurrence = recurrenceRule(fields.recurrence)
    if (!recurrence.ok) return recurrence
    var lines = (existing.recurrenceLines || []).filter(function(line) { return String(line).indexOf("RRULE:") !== 0 })
    if (recurrence.rule !== "") lines.unshift("RRULE:" + recurrence.rule)
    next.recurrence = lines
  }
  var zone = String(fields.timeZone || existing && existing.timeZone || source && source.timeZone || "")
  if (zone !== "" && next.start && next.start.dateTime) {
    next.start.timeZone = zone
    next.end.timeZone = zone
  }
  if (fields.guestEmails !== undefined) {
    var emails = String(fields.guestEmails).split(/[,;\n]/).map(function(email) { return email.trim() }).filter(function(email) { return email !== "" })
    if (emails.length > 200 || emails.some(function(email) { return !/^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(email) }))
      return { ok: false, error: "Enter valid guest email addresses separated by commas" }
    var seen = {}, previous = existing && Array.isArray(existing.attendees) ? existing.attendees : []
    next.attendees = []
    for (var emailIndex = 0; emailIndex < emails.length; emailIndex++) {
      var email = emails[emailIndex].toLowerCase()
      if (seen[email]) continue
      seen[email] = true
      var matched = previous.filter(function(attendee) { return String(attendee.email || "").toLowerCase() === email })
      next.attendees.push(matched.length ? matched[0] : { email: emails[emailIndex] })
    }
  }
  if (fields.transparency === "opaque" || fields.transparency === "transparent") next.transparency = fields.transparency
  if (["default", "public", "private"].indexOf(fields.visibility) >= 0) next.visibility = fields.visibility
  if (fields.reminderMode === "default") next.reminders = { useDefault: true }
  else if (fields.reminderMode === "none") next.reminders = { useDefault: false, overrides: [] }
  else if (fields.reminderMode === "custom") {
    var minutes = Number(fields.reminderMinutes)
    if (!isFinite(minutes) || minutes < 0 || minutes > 40320 || Math.floor(minutes) !== minutes)
      return { ok: false, error: "Reminder minutes must be a whole number from 0 to 40320" }
    next.reminders = { useDefault: false, overrides: [{ method: "popup", minutes: minutes }] }
  }
  if (fields.createMeet === true) {
    if (!source || source.canCreateMeet !== true)
      return { ok: false, error: "This calendar cannot create Google Meet meetings" }
    if (!(existing && existing.conferenceData)) {
      next.conferenceData = { createRequest: {
        requestId: String(fields.conferenceRequestId || ""),
        conferenceSolutionKey: { type: "hangoutsMeet" }
      } }
      if (next.conferenceData.createRequest.requestId === "")
        return { ok: false, error: "The meeting request has no identity" }
    }
  }
  return { ok: true, body: next }
}

function transferRefusal(source, destination, event) {
  if (!source || !destination || source.kind !== "google" || destination.kind !== "google")
    return "Calendar transfers are not available for this provider"
  if (source.accountId !== destination.accountId) return "Choose a calendar in the same account"
  if (source.readOnly) return "The original calendar is read-only"
  if (destination.readOnly) return "The destination calendar is read-only"
  if (!event || event.eventType !== "default" || !event.organizer || event.organizer.self !== true)
    return "Only ordinary events you organize can change calendars"
  if (event.recurringEventId) return "Open the entire series before changing its calendar"
  return ""
}

function rescheduleFields(event, startMs, endMs) {
  return { title: String(event.summary || ""), description: String(event.description || ""),
    location: String(event.location || ""), startMs: Number(startMs), endMs: Number(endMs),
    allDay: !!(event.start && event.start.allDay), timeZone: String(event.timeZone || ""), sendUpdates: "none" }
}

function gestureRange(event, dayOffset, minuteOffset, edge) {
  if (!event || !event.start || !event.end) return null
  var start = Number(event.start.ms), end = Number(event.end.ms)
  var minutes = Math.round(Number(minuteOffset) / 15) * 15
  if (edge === "start") start = Math.min(end - 900000, Math.round((start + Number(minuteOffset) * 60000) / 900000) * 900000)
  else if (edge === "end") end = Math.max(start + 900000, Math.round((end + Number(minuteOffset) * 60000) / 900000) * 900000)
  else {
    var date = new Date(start)
    date.setDate(date.getDate() + Number(dayOffset))
    if (!event.start.allDay) date.setMinutes(date.getMinutes() + minutes)
    var duration = end - start
    start = date.getTime()
    if (event.start.allDay) {
      // Invariant: all-day duration counts local dates, including 23/25-hour daylight-saving days.
      var endDate = new Date(end)
      endDate.setDate(endDate.getDate() + Number(dayOffset))
      end = endDate.getTime()
    } else end = start + duration
  }
  return isFinite(start) && isFinite(end) && end > start ? { start: start, end: end } : null
}

// Algorithm: interval partitioning gives each connected overlap group a shared lane count.
function timedLayout(events, day) {
  var rows = (events || []).filter(function(event) { return event && event.start && !displayInAllDayLane(event) }).map(function(event) {
    return { event: event, start: Math.max(Number(event.start.ms), day.startMs),
      end: Math.min(Number(event.end && event.end.ms || event.start.ms + 900000), day.endMs), column: 0, columns: 1 }
  }).filter(function(row) { return row.end > row.start })
  rows.sort(function(left, right) { return left.start - right.start || right.end - left.end || eventKey(left.event).localeCompare(eventKey(right.event)) })
  var group = [], ends = [], groupEnd = 0
  function finish() {
    for (var groupIndex = 0; groupIndex < group.length; groupIndex++) group[groupIndex].columns = ends.length
    group = []; ends = []; groupEnd = 0
  }
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    var row = rows[rowIndex]
    if (group.length && row.start >= groupEnd) finish()
    var lane = 0
    while (lane < ends.length && ends[lane] > row.start) lane++
    ends[lane] = row.end
    row.column = lane
    group.push(row)
    groupEnd = Math.max(groupEnd, row.end)
  }
  finish()
  return rows
}

function attendeeRows(event) {
  return (event && Array.isArray(event.attendees) ? event.attendees : []).map(function(attendee) {
    var status = String(attendee.responseStatus || attendee.partstat || attendee.status && attendee.status.response || "needsAction").toLowerCase()
    var label = status === "accepted" ? "Accepted" : status === "declined" ? "Declined"
      : status === "tentative" || status === "tentativelyaccepted" ? "Maybe" : "Awaiting reply"
    var email = String(attendee.email || attendee.emailAddress && attendee.emailAddress.address || "")
    var name = String(attendee.displayName || attendee.name || attendee.emailAddress && attendee.emailAddress.name || email || "Guest")
    return { name: name, email: email, label: label,
      symbol: label === "Accepted" ? "✓" : label === "Declined" ? "×" : "?",
      optional: attendee.optional === true, self: attendee.self === true }
  })
}

function agendaEvents(events, nowMs) {
  return (events || []).filter(function(event) {
    if (!event || !event.start) return false
    var end = event.end ? Number(event.end.ms) : Number(event.start.ms)
    return end > Number(nowMs)
  }).sort(compareEvents)
}

function calendarChoiceRows(groups, editingSource, event) {
  var rows = []
  for (var groupIndex = 0; groupIndex < (groups || []).length; groupIndex++) {
    var group = groups[groupIndex]
    var first = true
    for (var calendarIndex = 0; calendarIndex < (group.calendars || []).length; calendarIndex++) {
      var source = group.calendars[calendarIndex]
      if (event && (!editingSource || String(source.id) !== String(editingSource.id))
          && transferRefusal(editingSource, source, event) !== "") continue
      rows.push({ source: source, firstInGroup: first,
        groupLabel: String(group.providerLabel || "") + " · " + String(group.accountLabel || "") })
      first = false
    }
  }
  return rows
}

function repeatChoice(event) {
  var rules = (event && event.recurrenceLines || []).filter(function(line) { return String(line).indexOf("RRULE:") === 0 })
  if (!rules.length) return "none"
  if (rules.length !== 1 || !/^RRULE:FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(;(INTERVAL|COUNT)=\d+)*$/.test(rules[0])) return "custom"
  return /FREQ=([A-Z]+)/.exec(rules[0])[1]
}

function createEvent(fields, nowMs) {
  var checked = validateEventFields(fields)
  if (!checked.ok) return checked
  var recurrence = recurrenceRule((fields || {}).recurrence)
  if (!recurrence.ok) return recurrence
  var uid = "omamail-" + Math.floor(Number(nowMs) || Date.now())
  var result = {
    ok: true, uid: uid,
    ics: veventLines(uid, 0, Number(nowMs) || Date.now(), checked, recurrence.rule, fields.allDay === true).join("\r\n"),
    google: googleEventBody(checked, fields.allDay === true),
    graph: graphEventBody(checked, fields.allDay === true),
    // Invariant: Graph recurrence is structured data; a display string must not be written back as an ICS rule.
    recurring: recurrence.rule !== ""
  }
  if (recurrence.rule !== "") result.google.recurrence = ["RRULE:" + recurrence.rule]
  return result
}

function deleteRequest(event, source, canReadSeries) {
  var value = event || {}
  var google = !!source && source.kind === "google"
  var notifies = google && !!value.organizer && value.organizer.self === true
    && (value.attendees || []).some(function(attendee) { return attendee.self !== true })
  var occurrence = String(value.recurringEventId || "") !== ""
  var series = (Array.isArray(value.recurrenceLines) && value.recurrenceLines.length > 0)
    || (Array.isArray(value.recurrence) && value.recurrence.length > 0)
  var choices = []
  var message = "This event will be permanently deleted."
  if (occurrence) {
    var offerSeries = google && canReadSeries === true
    message = offerSeries ? "Delete this occurrence, or every occurrence in the series."
      : "This occurrence will be deleted. The rest of the series stays."
    if (offerSeries) choices.push({ value: "series", label: "Delete series" })
    if (notifies) {
      choices.push({ value: "none", label: "Delete occurrence without email" })
      choices.push({ value: "all", label: "Delete occurrence and notify guests" })
    } else choices.push({ value: "all", label: "Delete occurrence" })
  } else if (notifies) {
    message = (series ? "Every occurrence of this series will be deleted. " : "")
      + "Guests get a cancellation email unless you delete without one."
    choices.push({ value: "none", label: "Delete without email" })
    choices.push({ value: "all", label: "Delete and notify guests" })
  } else {
    if (series) message = "Every occurrence of this series will be deleted."
    choices.push({ value: "all", label: "Delete" })
  }
  return { kind: "event", name: String(value.summary || "Untitled event"), message: message, choices: choices }
}

function writeRefusal(source, event, operation) {
  if (!source) return "Choose a calendar"
  if (source.readOnly === true) return "This calendar is read-only"
  if (operation === "reschedule" && source.kind !== "google")
    return "Open the event editor to change its time"
  if (source.kind === "google" && event && event.eventType === "fromGmail" && operation !== "delete")
    return "Google does not allow changing the time or details of events created from Gmail"
  if (source.kind === "google" && event && event.organizer && event.organizer.self === false
      && event.guestsCanModify !== true && operation !== "delete")
    return "Only the organizer can change this event"
  if (source.kind !== "caldav" && source.kind !== "icloud") return ""
  // Invariant: malformed RECURRENCE-ID still denotes an occurrence; it must never authorize rewriting the series.
  var rawRecurrenceId = event && event.source
    ? String(event.source.recurrenceId || "") : ""
  if (String(event && event.recurrenceRule || "") !== ""
      || Number(event && event.recurrenceIdMs) > 0 || rawRecurrenceId !== "")
    return "Recurring CalDAV events can only be changed in a full calendar client"
  return ""
}

// Invariant: CalDAV updates retain UID and unrelated components in the original resource.
function updateEvent(fields, existing, nowMs) {
  var event = existing || {}
  var uid = String(event.uid || "")
  if (uid === "") return { ok: false, error: "The event has no identity to update" }
  var checked = validateEventFields(fields)
  if (!checked.ok) return checked
  var sequence = Math.max(0, Math.floor(Number(event.sequence) || 0)) + 1
   var allDay = fields.allDay === undefined ? !!(event.start && event.start.allDay) : fields.allDay === true
  var stampMs = Number(nowMs) || Date.now()
  var original = String(event.calendarData || "")
  var rewritten = original === "" ? "" : Ics.rewriteEvent(original, uid,
    editableEventLines(sequence, stampMs, checked, allDay),
    ["DTSTAMP", "SEQUENCE", "DTSTART", "DTEND", "DURATION", "SUMMARY",
      "DESCRIPTION", "LOCATION"])
  return {
    ok: true, uid: uid,
    ics: rewritten !== "" ? rewritten
      : veventLines(uid, sequence, stampMs, checked, "", allDay).join("\r\n"),
    google: googleEventPatch(checked, allDay, !!(event.start && event.start.allDay)),
    graph: graphEventBody(checked, allDay)
  }
}

function httpsAuthority(url) {
  var text = String(url || "")
  if (text === "" || /\s/.test(text)) return null
  var match = /^(https):\/\/([^\/?#]+)/i.exec(text)
  if (!match) return null
  var authority = match[2]
  var at = authority.lastIndexOf("@")
  if (at >= 0) authority = authority.substring(at + 1)
  var host = ""
  var port = ""
  if (authority.charAt(0) === "[") {
    var close = authority.indexOf("]")
    if (close < 0) return null
    host = authority.substring(0, close + 1).toLowerCase()
    var rest = authority.substring(close + 1)
    if (rest !== "" && rest.charAt(0) !== ":") return null
    port = rest === "" ? "" : rest.substring(1)
  } else {
    var colon = authority.lastIndexOf(":")
    if (colon >= 0) {
      host = authority.substring(0, colon).toLowerCase()
      port = authority.substring(colon + 1)
    } else {
      host = authority.toLowerCase()
    }
  }
  if (host === "" || host === "[]") return null
  if (port !== "" && !/^[0-9]{1,5}$/.test(port)) return null
  if (port !== "" && (Number(port) < 1 || Number(port) > 65535)) return null
  return { host: host, port: port === "" ? "443" : String(Number(port)) }
}

function urlAuthority(url) {
  var parts = httpsAuthority(url)
  if (!parts) return ""
  return parts.port === "443"
    ? "https://" + parts.host
    : "https://" + parts.host + ":" + parts.port
}

function urlOrigin(url) {
  var parts = httpsAuthority(url)
  return parts ? "https://" + parts.host + ":" + parts.port : ""
}

// Invariant: an event href must stay on the configured HTTPS origin before credentials are used.
function caldavEventUrl(sourceUrl, event) {
  var base = String(sourceUrl || "")
  var origin = urlOrigin(base)
  if (origin === "") return ""
  var href = String(event && event.href || "")
  if (/\s/.test(href)) return ""
  var resolved = ""
  if (/^https:\/\//i.test(href) || href.substring(0, 2) === "//") {
    var candidate = href.substring(0, 2) === "//" ? "https:" + href : href
    resolved = candidate.replace(/^(https:\/\/)[^\/?#]*@/i, "$1")
  } else if (href.charAt(0) === "/") {
    resolved = urlAuthority(base) + href
  } else if (href !== "") {
    var collection = base.charAt(base.length - 1) === "/" ? base : base + "/"
    resolved = collection + href
  } else {
    var uid = String(event && event.uid || "")
    if (uid === "") return ""
    var root = base.charAt(base.length - 1) === "/" ? base : base + "/"
    resolved = root + encodeURIComponent(uid) + ".ics"
  }
  return urlOrigin(resolved) === origin ? resolved : ""
}

// Performance: preserve event-list identity when a refresh would render the same values.
function sameEvents(left, right) {
  if (left === right) return true
  if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) return false
  return JSON.stringify(left) === JSON.stringify(right)
}

function compareEvents(left, right) {
  var leftMs = left && left.start ? left.start.ms : 0
  var rightMs = right && right.start ? right.start.ms : 0
  if (leftMs !== rightMs) return leftMs - rightMs
  return String(left && left.summary || "").localeCompare(String(right && right.summary || ""))
}

function isoDate(date) {
  return date.getFullYear() + "-" + two(date.getMonth() + 1) + "-" + two(date.getDate())
}

function monthDays(year, monthIndex, weekStart) {
  var first = new Date(Number(year), Number(monthIndex), 1)
  var startDay = Math.floor(Number(weekStart))
  if (!isFinite(startDay) || startDay < 0 || startDay > 6) startDay = 1
  var offset = (first.getDay() - startDay + 7) % 7
  var cursor = new Date(first.getFullYear(), first.getMonth(), 1 - offset)
  var out = []
  for (var dayIndex = 0; dayIndex < 42; dayIndex++) {
    var day = new Date(cursor.getFullYear(), cursor.getMonth(), cursor.getDate() + dayIndex)
    out.push({
      isoDate: isoDate(day), day: day.getDate(), month: day.getMonth(), year: day.getFullYear(),
      startMs: day.getTime(), endMs: new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1).getTime(),
      inMonth: day.getMonth() === first.getMonth()
    })
  }
  return out
}

function monthGridDays(year, monthIndex, weekStart) {
  var days = monthDays(year, monthIndex, weekStart)
  return days.slice(0, days.slice(35).some(function(day) { return day.inMonth }) ? 42 : 35)
}

function monthEventLimit(availableHeight, rowHeight, spacing, overflowHeight, eventCount) {
  var capacity = Math.max(0, Math.floor((availableHeight + spacing) / (rowHeight + spacing)))
  if (eventCount <= capacity) return capacity
  return Math.max(0, Math.floor((availableHeight - overflowHeight) / (rowHeight + spacing)))
}

function spansMultipleDays(event) {
  if (!event || !event.start || !event.end) return false
  var start = Number(event.start.ms), end = Number(event.end.ms)
  return isFinite(start) && isFinite(end) && end > start
    && isoDate(new Date(start)) !== isoDate(new Date(end - 1))
}

// Invariant: month segments use exclusive ends, so midnight does not occupy the following day.
function monthSpanLayout(events, days) {
  return spanLayout((events || []).filter(spansMultipleDays), days)
}

function spanLayout(events, days) {
  var segments = [], laneCounts = []
  var values = (events || []).filter(function(event) {
    return event && event.start && event.end && Number(event.end.ms) > Number(event.start.ms)
  }).slice().sort(function(leftEvent, rightEvent) {
    return Number(leftEvent.start.ms) - Number(rightEvent.start.ms)
      || Number(rightEvent.end.ms) - Number(leftEvent.end.ms) || compareEvents(leftEvent, rightEvent)
  })
  for (var week = 0; week < Math.ceil(days.length / 7); week++) {
    var first = week * 7, last = Math.min(first + 6, days.length - 1), laneEnds = []
    for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
      var event = values[valueIndex], start = Number(event.start.ms), end = Number(event.end.ms)
      if (start >= days[last].endMs || end <= days[first].startMs) continue
      var left = 0, right = last - first
      while (left < last - first && start >= days[first + left].endMs) left++
      while (right > left && end <= days[first + right].startMs) right--
      var lane = 0
      while (lane < laneEnds.length && laneEnds[lane] >= left) lane++
      laneEnds[lane] = right
      segments.push({event:event, week:week, startColumn:left, endColumn:right, lane:lane,
        continuesBefore:start < days[first].startMs, continuesAfter:end > days[last].endMs})
    }
    laneCounts.push(laneEnds.length)
  }
  return {segments:segments, laneCounts:laneCounts}
}

function weekDays(anchorMs, weekStart) {
  var anchor = new Date(Number(anchorMs) || Date.now())
  var startDay = Math.floor(Number(weekStart))
  if (!isFinite(startDay) || startDay < 0 || startDay > 6) startDay = 1
  var offset = (anchor.getDay() - startDay + 7) % 7
  var start = new Date(anchor.getFullYear(), anchor.getMonth(), anchor.getDate() - offset)
  var out = []
  for (var dayIndex = 0; dayIndex < 7; dayIndex++) {
    var day = new Date(start.getFullYear(), start.getMonth(), start.getDate() + dayIndex)
    out.push({
      isoDate: isoDate(day), day: day.getDate(), month: day.getMonth(), year: day.getFullYear(),
      startMs: day.getTime(), endMs: new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1).getTime(),
      inMonth: true
    })
  }
  return out
}

function weekTitle(days) {
  var values = Array.isArray(days) ? days : []
  if (values.length < 7) return ""
  var months = ["January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"]
  var first = values[0]
  var last = values[6]
  if (first.year === last.year && first.month === last.month)
    return first.day + "–" + last.day + " " + months[first.month] + " " + first.year
  if (first.year === last.year)
    return first.day + " " + months[first.month] + "–" + last.day + " "
      + months[last.month] + " " + first.year
  return first.day + " " + months[first.month] + " " + first.year + "–"
    + last.day + " " + months[last.month] + " " + last.year
}

// Invariant: grid minutes follow local clock labels, not elapsed time across daylight-saving transitions.
function dayMinutes(timeMs, day) {
  var value = Number(timeMs)
  if (value <= Number(day.startMs)) return 0
  if (value >= Number(day.endMs)) return 1440
  var local = new Date(value)
  return local.getHours() * 60 + local.getMinutes()
    + local.getSeconds() / 60 + local.getMilliseconds() / 60000
}

function eventTop(event, day, firstHour, hourHeight) {
  if (!event || !event.start || event.start.allDay) return 0
  var start = Math.max(Number(event.start.ms), Number(day.startMs))
  var minutes = dayMinutes(start, day) - Number(firstHour) * 60
  return Math.max(0, minutes / 60 * Number(hourHeight))
}

function eventHeight(event, day, hourHeight) {
  if (!event || !event.start || event.start.allDay) return 0
  var start = Math.max(Number(event.start.ms), Number(day.startMs))
  var end = event.end ? Math.min(Number(event.end.ms), Number(day.endMs)) : start + 1800000
  return Math.max(2,
    (dayMinutes(end, day) - dayMinutes(start, day)) / 60 * Number(hourHeight))
}

// Docs: return the day-column offset, or -1 when the current time is outside the visible grid.
function nowOffset(day, firstHour, lastHour, hourHeight, nowMs) {
  if (!day) return -1
  var now = Number(nowMs)
  if (!isFinite(now)) return -1
  if (now < Number(day.startMs) || now >= Number(day.endMs)) return -1
  var minutes = dayMinutes(now, day)
  var first = Number(firstHour) * 60
  var last = Number(lastHour) * 60
  if (minutes < first || minutes > last) return -1
  return (minutes - first) / 60 * Number(hourHeight)
}

// Invariant: Qt supplies the locale time pattern, including locale-specific literals.
function timeLabel(timeMs, localeFormat) {
  var time = new Date(Number(timeMs))
  if (!isFinite(time.getTime())) return ""
  return time.toLocaleTimeString(Qt.locale(), localeFormat)
}

function timeRangeLabel(startMs, endMs, localeFormat, separator) {
  return timeLabel(startMs, localeFormat) + (separator === undefined ? "–" : separator)
    + timeLabel(endMs, localeFormat)
}

function dateTimeLabel(timeMs, dateFormat, localeFormat, separator) {
  return Qt.formatDate(new Date(Number(timeMs)), dateFormat)
    + (separator === undefined ? " " : separator) + timeLabel(timeMs, localeFormat)
}

function weekNowOffset(days, firstHour, lastHour, hourHeight, nowMs) {
  var values = Array.isArray(days) ? days : []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    var offset = nowOffset(values[valueIndex], firstHour, lastHour, hourHeight, nowMs)
    if (offset >= 0) return offset
  }
  return -1
}

function eventsOnDay(events, day) {
  var values = Array.isArray(events) ? events : []
  var out = []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    var event = values[valueIndex] || {}
    if (!event.start) continue
    var end = event.end ? event.end.ms : event.start.ms + 1
    if (event.start.ms < day.endMs && end > day.startMs) out.push(event)
  }
  out.sort(compareEvents)
  return out
}

function indexDays(events, days) {
  var result = {}
  var ordered = (Array.isArray(events) ? events : []).slice().sort(compareEvents)
  var dates = Array.isArray(days) ? days : []
  for (var emptyDayIndex=0;emptyDayIndex<dates.length;emptyDayIndex++) result[dates[emptyDayIndex].startMs]=[]
  for (var orderedIndex=0;orderedIndex<ordered.length;orderedIndex++) {
    var event=ordered[orderedIndex]
    if (!event || !event.start) continue
    var end=event.end ? event.end.ms : event.start.ms+1
    var low=0, high=dates.length
    while (low<high) {
      var middle=Math.floor((low+high)/2)
      if (dates[middle].endMs<=event.start.ms) low=middle+1
      else high=middle
    }
    for (var overlapDayIndex=low;overlapDayIndex<dates.length && dates[overlapDayIndex].startMs<end;overlapDayIndex++) result[dates[overlapDayIndex].startMs].push(event)
  }
  return result
}

// Invariant: all-day-lane presentation must retain timed endpoints for details and writes.
function displayInAllDayLane(event) {
  if (!event || !event.start) return false
  if (event.start.allDay) return true
  if (!event.end) return false
  var start = new Date(Number(event.start.ms))
  var nextDay = new Date(start.getTime())
  nextDay.setDate(nextDay.getDate() + 1)
  return Number(event.end.ms) >= nextDay.getTime()
}

function allDayEventsOnDay(events, day) {
  var values = eventsOnDay(events, day)
  var out = []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    if (displayInAllDayLane(values[valueIndex])) out.push(values[valueIndex])
  }
  return out
}

function weekHourRange(events, days, defaultFirst, defaultLast) {
  var first = Math.max(0, Math.min(23, Math.floor(Number(defaultFirst) || 0)))
  var last = Math.max(first + 1, Math.min(24, Math.ceil(Number(defaultLast) || 24)))
  var values = Array.isArray(events) ? events : []
  var week = Array.isArray(days) ? days : []
  if (week.length === 0) return { first: first, last: last }
  var rangeStart = Number(week[0].startMs)
  var rangeEnd = Number(week[week.length - 1].endMs)
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    var event = values[valueIndex] || {}
    if (!event.start || displayInAllDayLane(event)) continue
    var startMs = Number(event.start.ms)
    var endMs = event.end ? Number(event.end.ms) : startMs + 1800000
    if (startMs >= rangeEnd || endMs <= rangeStart) continue
    for (var weekIndex = 0; weekIndex < week.length; weekIndex++) {
      var day = week[weekIndex]
      var segmentStart = Math.max(startMs, Number(day.startMs))
      var segmentEnd = Math.min(endMs, Number(day.endMs))
      if (segmentEnd <= segmentStart) continue
      var startMinutes = dayMinutes(segmentStart, day)
      var endMinutes = dayMinutes(segmentEnd, day)
      first = Math.min(first, Math.floor(startMinutes / 60))
      last = Math.max(last, Math.min(24, Math.ceil(endMinutes / 60)))
    }
  }
  return { first: first, last: last }
}

function slotStart(day, verticalPosition, firstHour, hourHeight, minuteStep) {
  var height = Math.max(1, Number(hourHeight) || 1)
  var step = Math.max(1, Math.floor(Number(minuteStep) || 30))
  var minutes = Number(firstHour) * 60 + Math.max(0, Number(verticalPosition)) / height * 60
  minutes = Math.floor(minutes / step) * step
  var localDay = new Date(Number(day.startMs))
  return new Date(localDay.getFullYear(), localDay.getMonth(), localDay.getDate(),
    Math.floor(minutes / 60), minutes % 60).getTime()
}

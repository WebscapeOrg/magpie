.pragma library

function two(value) {
  var number = Math.floor(Number(value) || 0)
  return (number < 10 ? "0" : "") + number
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
  var output = []
  for (var itemIndex = 0; itemIndex < items.length; itemIndex++) {
    var item = items[itemIndex] || {}
    if (String(item.status || "").toLowerCase() === "cancelled") continue
    var start = googleMoment(item.start && (item.start.dateTime || item.start.date),
      !!(item.start && item.start.date && !item.start.dateTime))
    if (!start) continue
    var end = googleMoment(item.end && (item.end.dateTime || item.end.date),
      !!(item.end && item.end.date && !item.end.dateTime))
    output.push({
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
  output.sort(compareEvents)
  return output
}

function eventKey(event) {
  if (!event) return ""
  return String(event.sourceId || "") + "\n" + String(event.googleId
    || String(event.uid || "") + "\n" + String(event.recurrenceIdMs || event.start && event.start.ms || ""))
}

// Invariant: provider-facing messages must not expose native backend diagnostics.
function nativeRequestError() {
  return "Google could not complete this calendar request. Refresh the event and try again"
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
    google: googleEventBody(checked, fields.allDay === true),
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
  if (source.kind !== "google") return "Only Google calendars are supported"
  if (source.readOnly === true) return "This calendar is read-only"
  if (event && event.eventType === "fromGmail" && operation !== "delete")
    return "Google does not allow changing the time or details of events created from Gmail"
  if (event && event.organizer && event.organizer.self === false
      && event.guestsCanModify !== true && operation !== "delete")
    return "Only the organizer can change this event"
  return ""
}

function updateEvent(fields, existing) {
  var event = existing || {}
  var uid = String(event.uid || "")
  if (uid === "") return { ok: false, error: "The event has no identity to update" }
  var checked = validateEventFields(fields)
  if (!checked.ok) return checked
  var allDay = fields.allDay === undefined ? !!(event.start && event.start.allDay) : fields.allDay === true
  return { ok: true, uid: uid,
    google: googleEventPatch(checked, allDay, !!(event.start && event.start.allDay)) }
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
  var output = []
  for (var dayIndex = 0; dayIndex < 42; dayIndex++) {
    var day = new Date(cursor.getFullYear(), cursor.getMonth(), cursor.getDate() + dayIndex)
    output.push({
      isoDate: isoDate(day), day: day.getDate(), month: day.getMonth(), year: day.getFullYear(),
      startMs: day.getTime(), endMs: new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1).getTime(),
      inMonth: day.getMonth() === first.getMonth()
    })
  }
  return output
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
  var output = []
  for (var dayIndex = 0; dayIndex < 7; dayIndex++) {
    var day = new Date(start.getFullYear(), start.getMonth(), start.getDate() + dayIndex)
    output.push({
      isoDate: isoDate(day), day: day.getDate(), month: day.getMonth(), year: day.getFullYear(),
      startMs: day.getTime(), endMs: new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1).getTime(),
      inMonth: true
    })
  }
  return output
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
  var output = []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    var event = values[valueIndex] || {}
    if (!event.start) continue
    var end = event.end ? event.end.ms : event.start.ms + 1
    if (event.start.ms < day.endMs && end > day.startMs) output.push(event)
  }
  output.sort(compareEvents)
  return output
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
  var output = []
  for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
    if (displayInAllDayLane(values[valueIndex])) output.push(values[valueIndex])
  }
  return output
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

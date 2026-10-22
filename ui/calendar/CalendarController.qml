import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Calendar.js" as Calendar
import "Sources.js" as Sources
import "../providers/MicrosoftOAuth.js" as Microsoft

Item {
  id: root

  required property var service
  required property string pluginDir
  property string cacheName: "calendar"
  property bool reminderMode: false
  function sourceIncluded(source) { return !!source && (reminderMode ? Sources.nativeCalendarFeatures(source) && source.remindersEnabled === true : source.enabled !== false) }
  property string accountId: ""
  property var sourceList: Sources.emptyList()
  property bool sourcesLoaded: false
  property var events: []
  property bool loading: false
  property string lastError: ""
  property var undoChange: null
  property double rangeStart: 0
  property double rangeEnd: 0
  property string refreshAccountId: ""
  // Invariant: shared-calendar cache scope can outlive an individual mailbox selection.
  property string refreshScope: ""
  property var queue: []
  property int refreshSerial: 0
  property int activeReads: 0
  readonly property var sharedCache: service && service.calendarCache && service.backend && Number(service.backend.apiVersion)>=8 ? service.calendarCache : null
  property var passwordSaveQueue: []
  property string passwordToSave: ""
  property bool savingPassword: false
  property string sourceWritePayload: ""
  property string sourceSecret: ""
  property var sourceBeingSaved: null
  property bool savingSource: false
  property bool discoveringCalendars: false
  property string discoveringAccountId: ""
  property string discoveryError: ""
  property int discoverySerial: 0
  property bool discoverySaving: false
  property int discoveryPendingCount: 0
  property var discoveryChoices: null
  property string discoveryChoiceAccount: ""
  property bool clockRunning: false
  property double nowMs: Date.now()
  property bool refreshAfterSourceWrite: false
  property bool creatingEvent: false
  property var eventSource: null
  property var eventDraft: null
  // Invariant: create, update and delete share one write slot, including credential lookup.
  property string writeOp: ""
  property var writeSource: null
  property var writeEvent: null
  property var writeDraft: null

  property bool eventWriting: false
  readonly property var availableSources: Sources.withMicrosoftAccounts(Sources.withGoogleAccounts(
    sourceList, service ? service.accountSummaries : []), service ? service.accountSummaries : [])
  readonly property bool unifiedCalendarView: !!service
    && service.unifiedCalendarView === true
  readonly property var contextSources: unifiedCalendarView
    ? availableSources : Sources.forAccount(availableSources, accountId)
  // Performance: unified calendar views share one cache scope across mailboxes.
  readonly property string calendarScope: unifiedCalendarView && accountId !== ""
    ? "__unified__" : accountId
  readonly property var sourceGroups: Sources.groupByAccount(
    contextSources, service ? service.accountSummaries : [])

  readonly property var writableSourceGroups: Sources.writableGroups(sourceGroups)

  Timer {
    interval: 60000
    repeat: true
    running: root.clockRunning
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  onCalendarScopeChanged: reloadVisibleRange()

  readonly property string enabledSourceKey: contextSources.sources.filter(function(source) {
    return root.sourceIncluded(source)
  }).map(function(source) { return String(source.id || "") }).join("\n")
  onEnabledSourceKeyChanged: reloadVisibleRange()

  // Invariant: refresh already waits for cache restoration; duplicating that guard loses source changes.
  function reloadVisibleRange() {
    if (!rangeStart || !rangeEnd) return
    setEvents(cachedEventsFor(calendarScope, rangeStart, rangeEnd))
    refresh(rangeStart, rangeEnd)
  }

  signal passwordSaved(bool ok, string error)
  signal calendarSaved(bool ok, string error)
  signal discoveryFinished(bool ok, string error, int count)
  signal eventCreated(bool ok, string error)
  // Docs: composeRequested opens the event editor with prefilled fields; it does not write the event.
  signal composeRequested(var prefill)
  // Invariant: a held composer must not be replaced by another event suggestion.
  property bool composerHeld: false
  signal composeEnded()
  signal eventUpdated(bool ok, string error)
  signal eventDeleted(bool ok, string error)

  readonly property string configPath: {
    return service && typeof service.configPath === "function"
      ? service.configPath("calendars.json") : ""
  }

  function openExternal(value) {
    return service && typeof service.openExternal === "function"
      ? service.openExternal(value) : false
  }

  function copyText(value) {
    return service && typeof service.copyText === "function"
      ? service.copyText(value) : false
  }

  function refresh(startMs, endMs) {
    var requestedStart = Number(startMs) || 0
    var requestedEnd = Number(endMs) || 0
    rangeStart = requestedStart
    rangeEnd = requestedEnd
    setEvents(cachedEventsFor(calendarScope, rangeStart, rangeEnd))
    refreshSerial++
    if (!eventCache.loaded && !(sharedCache && sharedCache.loaded)) {loading=false;return}
    activeReads = 0
    lastError = ""
    refreshAccountId = accountId
    refreshScope = calendarScope
    var effectiveSources = sourcesForAccount(refreshAccountId)
    queue = effectiveSources.sources.filter(function(source) {
      return root.sourceIncluded(source)
    })
    loading = true
    setEvents(cachedEventsFor(refreshScope, rangeStart, rangeEnd))
    processNext()
  }

  function sourcesForAccount(wantedAccountId) {
    var available = Sources.withMicrosoftAccounts(Sources.withGoogleAccounts(
      sourceList, service ? service.accountSummaries : []), service ? service.accountSummaries : [])
    return unifiedCalendarView ? available : Sources.forAccount(available, wantedAccountId)
  }

  function discoverableAccount(accountId) {
    var accounts = service && Array.isArray(service.accountSummaries)
      ? service.accountSummaries : []
    for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      var account = accounts[accountIndex] || {}
      if (String(account.id || "") !== String(accountId || "")) continue
      return account.signedIn === true
        && (account.calendarProvider === "microsoft" || account.calendarProvider === "icloud"
          || (account.calendarProvider === "google" && service.backendCanGoogleCalendars === true))
    }
    return false
  }

  function discoveredCount(accountId) {
    var values = availableSources && Array.isArray(availableSources.sources)
      ? availableSources.sources : []
    var count = 0
    for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
      var source = values[valueIndex] || {}
      if (String(source.accountId || "") === String(accountId || "")
          && source.discovered === true) count++
    }
    return count
  }

  function microsoftConsentHandler(accountId) {
    var host = accountId && service && typeof service.findAccount === "function" ? service.findAccount(accountId) : null
    if (host && host.providerId === "outlook" && host.auth
        && typeof host.auth.graphConsentHandler === "function") return host.auth.graphConsentHandler()
    return function() { return false }
  }

  function discoveryFailure(error) {
    // Invariant: backend error codes are numeric; the stable refusal reason is carried in message.
    var code = String(error && error.message || error || "")
    if (code === "auth_signed_out" || code === "calendar_auth_refused")
      return "Sign in to this mailbox again"
    if (code === "calendar_provider_unsupported")
      return "This mailbox does not support calendar discovery"
    if (code === "calendar_timeout") return "Calendar discovery timed out"
    return "Calendars could not be discovered"
  }

  function discoverAccountCalendars(accountId) {
    var wanted = String(accountId || "")
    if (discoveringCalendars || savingSource || !discoverableAccount(wanted)) return false
    if (!service || !service.backend || !service.backend.ready) {
      discoveryError = "Calendar backend is unavailable"
      discoveryFinished(false, discoveryError, 0)
      return false
    }
    if (service.backendCanDiscoverCalendars !== true) {
      discoveryError = "Update the backend to discover account calendars"
      discoveryFinished(false, discoveryError, 0)
      return false
    }
    var serial = ++discoverySerial
    discoveringCalendars = true
    discoveringAccountId = wanted
    discoveryError = ""
    var notifyConsent = microsoftConsentHandler(wanted)
    service.backend.call("calendar.discover", { accountId: wanted }, function(result, error) {
      if (serial !== root.discoverySerial || root.discoveringAccountId !== wanted) return
      root.discoveringCalendars = false
      root.discoveringAccountId = ""
      if (error || !result || String(result.accountId || "") !== wanted
          || !Array.isArray(result.calendars) || !root.discoverableAccount(wanted)) {
        root.discoveryError = notifyConsent(error) ? Microsoft.graphConsentMessage() : root.discoveryFailure(error)
        root.discoveryFinished(false, root.discoveryError, 0)
        return
      }
      var next = Sources.applyDiscovery(root.sourceList, result)
      if (result.provider === "google") {
        root.discoveryChoiceAccount = wanted
        root.discoveryChoices = next
        root.discoveryPendingCount = result.calendars.length
        return
      }
      root.discoveryPendingCount = result.calendars.length
      root.discoverySaving = true
      root.sourceBeingSaved = null
      root.sourceSecret = ""
      root.sourceWritePayload = Sources.serialize(next)
      root.refreshAfterSourceWrite = true
      root.savingSource = true
      root.writeSources()
    })
    return true
  }

  function chooseDiscovered(id, enabled) {
    if (!discoveryChoices) return
    var next = Sources.setEnabled(discoveryChoices, id, enabled)
    var existing = sourceList.sources.some(function(source) { return source.id === id && source.discovered })
    if (!existing) next.sources = next.sources.map(function(source) {
      if (source.id !== id) return source
      var value = Sources.makeSource(source)
      value.remindersEnabled = enabled === true
      return value
    })
    discoveryChoices = next
  }

  function confirmDiscovery() {
    if (!discoveryChoices || savingSource) return
    if (!discoverableAccount(discoveryChoiceAccount)) { discoveryChoices = null; return }
    var chosen = Sources.copyList(sourceList)
    chosen.sources = chosen.sources.filter(function(source) {
      return source.kind !== "google" || source.accountId !== root.discoveryChoiceAccount
    })
    discoveryChoices.sources.forEach(function(source) {
      if (source.kind === "google" && source.accountId === root.discoveryChoiceAccount) chosen = Sources.add(chosen, source)
    })
    sourceWritePayload = Sources.serialize(chosen)
    discoveryChoices = null
    discoverySaving = true
    sourceBeingSaved = null
    sourceSecret = ""
    refreshAfterSourceWrite = true
    savingSource = true
    writeSources()
  }

  // Invariant: unified-view cache scope includes all source accounts.
  function cachedEventsFor(scope, startMs, endMs) {
    var values = sourcesForAccount(accountId).sources.filter(function(source) {
      return root.sourceIncluded(source)
    })
    var ids = values.map(function(source) { return String(source.id || "") })
    if (sharedCache && sharedCache.loaded) {
      var cached = sharedCache.get("sources",startMs,endMs,ids)
      var missing=ids.filter(function(id){return !root.sharedCache.knows("sources",startMs,endMs,id)})
      return cached.concat(eventCache.get(scope,startMs,endMs,missing))
    }
    return eventCache.get(scope,startMs,endMs,ids)
  }

  function findSource(sourceId) {
    return sourceById(contextSources, sourceId)
  }

  function sourceById(list, sourceId) {
    var values = list.sources
    for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
      if (values[valueIndex] && values[valueIndex].id === String(sourceId)) return values[valueIndex]
    }
    return null
  }

  function createEvent(sourceId, fields) {
    if (creatingEvent || eventWriting) {
      eventCreated(false, "Another event change is still in progress")
      return false
    }
    var source = findSource(sourceId)
    var refusal = Calendar.writeRefusal(source, null)
    if (refusal !== "") { eventCreated(false, refusal); return false }
    var built = Calendar.createEvent(fields, Date.now())
    if (!built.ok) { eventCreated(false, built.error); return false }
    if (source.kind === "google") {
      var refusedOptions = googleOptionsRefusal(fields)
      if (refusedOptions !== "") { eventCreated(false, refusedOptions); return false }
    }
    if (source.kind === "google" && service.backendCanGoogleCalendars === true) {
      var options = Calendar.googleOptions(built.google, fields, source, null)
      if (!options.ok) { eventCreated(false, options.error); return false }
      built.google = options.body
      built.sendUpdates = fields.sendUpdates === "none" ? "none" : "all"
    }
    eventSource = source
    eventDraft = built
    creatingEvent = true
    if (source.kind === "microsoft" && built.recurring) {
      creatingEvent = false
      eventSource = null
      eventDraft = null
      eventCreated(false, "A repeating event on a Microsoft calendar is made in Outlook")
      return false
    }
    createNativeEvent()
    return true
  }

  function finishEvent(ok, error) {
    creatingEvent = false
    eventSource = null
    eventDraft = null
    eventCreated(ok, String(error || ""))
    if (ok && rangeStart && rangeEnd) refresh(rangeStart, rangeEnd)
  }

  // Invariant: guests, Meet and recurrence edits require the fixed API 6 feature gate.
  function googleOptionsRefusal(fields) {
    if (service.backendCanGoogleCalendars === true) return ""
    if (fields.createMeet === true || fields.changeRecurrence === true
        || String(fields.guestEmails || "").trim() !== "")
      return "Update the backend to add guests, Meet or repetition changes"
    return ""
  }

  // Invariant: direct drag writes need the same fixed API gate as editor writes.
  function rescheduleRefusal(event) {
    var refusal = Calendar.writeRefusal(findSource(event && event.sourceId), event, "reschedule")
    if (refusal === "" && service.backendCanGoogleCalendars !== true)
      refusal = "Update the backend to move events by dragging"
    return refusal
  }

  function updateEvent(sourceId, event, fields) {
    if (creatingEvent || eventWriting) {
      eventUpdated(false, "Another event change is still in progress")
      return false
    }
    var source = findSource(sourceId)
    if (source && source.kind === "google" && service.backendCanGoogleCalendars === true && !event.etag) {
      eventUpdated(false, "Refresh this event before editing it")
      return false
    }
    var refusal = Calendar.writeRefusal(source, event)
    if (refusal !== "") { eventUpdated(false, refusal); return false }
    var built = Calendar.updateEvent(fields, event, Date.now())
    if (!built.ok) { eventUpdated(false, built.error); return false }
    var destination = fields.destinationSourceId && fields.destinationSourceId !== sourceId
      ? findSource(fields.destinationSourceId) : null
    if (fields.destinationSourceId && fields.destinationSourceId !== sourceId) {
      var transferError = Calendar.transferRefusal(source, destination, event)
      if (transferError !== "") { eventUpdated(false, transferError); return false }
      if (service.backendCanGoogleCalendars !== true) {
        eventUpdated(false, "Update the backend to transfer events"); return false
      }
      built.destination = destination
    }
    if (source.kind === "google") {
      var refusedChange = googleOptionsRefusal(fields)
      if (refusedChange !== "") { eventUpdated(false, refusedChange); return false }
    }
    if (source.kind === "google" && service.backendCanGoogleCalendars === true) {
      var options = Calendar.googleOptions(built.google, fields, source, event)
      if (!options.ok) { eventUpdated(false, options.error); return false }
      built.google = options.body
      built.sendUpdates = fields.sendUpdates === "none" ? "none" : "all"
    }
    writeOp = "update"
    writeSource = source
    writeEvent = event
    writeDraft = built
    eventWriting = true
    startNativeWrite()
    return true
  }

  function deleteRequest(sourceId, event) {
    var request = Calendar.deleteRequest(event, findSource(String(sourceId || "")),
      service.backendCanGoogleCalendars === true)
    request.sourceId = String(sourceId || "")
    request.event = event
    return request
  }

  function confirmDelete(request) {
    if (!request || !request.event) return false
    if (request.choice === "series") return deleteSeries(request.sourceId, request.event)
    var event = {}
    for (var key in request.event) event[key] = request.event[key]
    event.deleteSendUpdates = request.choice === "none" ? "none" : "all"
    return deleteEvent(request.sourceId, event)
  }

  // Invariant: deleting a series requires its master identity, not an occurrence ID.
  function deleteSeries(sourceId, occurrence) {
    var owner = findSource(sourceId)
    if (!owner || !occurrence || !occurrence.recurringEventId) return false
    if (service.backendCanGoogleCalendars !== true) { lastError = "Update the backend to delete a series"; return false }
    nativeRequest(owner, "get", { eventId: occurrence.recurringEventId }, function(result, error) {
      if (error) { root.lastError = error; return }
      var parent
      try { parent = JSON.parse(result.body) } catch (parseError) { root.lastError = "Could not read the series"; return }
      var events = Calendar.eventsFromGoogle({ items: [parent] }, owner.id)
      if (events.length !== 1) { root.lastError = "Could not read the series"; return }
      events[0].deleteSendUpdates = occurrence.deleteSendUpdates === "none" ? "none" : "all"
      root.deleteEvent(owner.id, events[0])
    })
    return true
  }

  function deleteEvent(sourceId, event) {
    if (creatingEvent || eventWriting) {
      eventDeleted(false, "Another event change is still in progress")
      return false
    }
    var source = findSource(sourceId)
    var refusal = Calendar.writeRefusal(source, event, "delete")
    if (refusal !== "") { eventDeleted(false, refusal); return false }
    writeOp = "delete"
    writeSource = source
    writeEvent = event
    writeDraft = null
    eventWriting = true
    startNativeWrite()
    return true
  }

  function transferEvent(sourceId, destinationId, event, callback) {
    var source = findSource(sourceId), destination = findSource(destinationId)
    var refusal = Calendar.transferRefusal(source, destination, event)
    if (creatingEvent || eventWriting) refusal = "Another event change is still in progress"
    else if (service.backendCanGoogleCalendars !== true) refusal = "Update the backend to transfer events"
    else if (!event || !event.etag) refusal = "Refresh this event before moving it"
    if (refusal) { callback(null, refusal); return false }
    eventWriting = true
    nativeRequest(source, "move", {eventId:event.googleId, destination:destination.calendarId || "primary",
      ifMatch:event.etag, sendUpdates:"none"}, function(result, error) {
      root.eventWriting = false
      if (error) { callback(null, error); return }
      root.undoChange = null
      var resource = null
      try { resource = JSON.parse(result.body) } catch (parseError) {}
      var moved = resource ? Calendar.eventsFromGoogle({items:[resource]}, destination.id) : []
      callback(moved.length === 1 ? moved[0] : null,
        moved.length === 1 ? "" : "The calendar changed, but its updated details could not be read. Reopen the event before editing further.", true)
      if (root.rangeStart && root.rangeEnd) root.refresh(root.rangeStart, root.rangeEnd)
    })
    return true
  }

  function finishWrite(ok, error) {
    var operation = writeOp
    eventWriting = false
    writeOp = ""
    writeSource = null
    writeEvent = null
    writeDraft = null
    if (operation === "delete") eventDeleted(ok, String(error || ""))
    else eventUpdated(ok, String(error || ""))
    // Invariant: detail-view deletes must not signal completion of an unrelated event composer.
    if (!ok) {
      lastError = String(error || "Could not write the event")
    }
    if (ok && rangeStart && rangeEnd) refresh(rangeStart, rangeEnd)
  }

  // Invariant: historical Microsoft access supports only the primary calendar identity.
  function isDefaultMicrosoftCalendar(source) {
    return !!source && source.kind === "microsoft"
      && String(source.id || "") === "microsoft:" + String(source.accountId || "")
  }

  function nativeRequest(source, operation, fields, callback) {
    if (!service || !service.backend) { callback(null, "Calendar backend is unavailable"); return }
    if (source && source.kind === "google"
        && (source.calendarId || ["get", "lookup", "instances", "move"].indexOf(operation) >= 0
          || fields && (fields.ifMatch || fields.sendUpdates !== undefined))
        && service.backendCanGoogleCalendars !== true) {
      callback(null, "Update the backend to access Google calendars")
      return
    }
    if (source && service.backendCanDiscoverCalendars !== true) {
      if (source.kind === "microsoft" && String(source.calendarId || "") !== ""
          && isDefaultMicrosoftCalendar(source)) {
        var degraded = Sources.makeSource(source)
        degraded.calendarId = ""
        source = degraded
      } else if (source.kind === "icloud"
          || (source.kind === "microsoft" && String(source.calendarId || "") !== "")) {
        callback(null, "Update the backend to access this calendar")
        return
      }
    }
    var params = Object.assign({}, fields || {})
    params.source = source
    params.operation = operation
    var notifyConsent = microsoftConsentHandler(source && source.kind === "microsoft" ? source.accountId : "")
    service.backend.call(operation === "list" && Number(service.backend.apiVersion)>=8 ? "calendar.read" : "calendar.request", params, function(result, error) {
      var reason = ""
      if (error) {
        reason = notifyConsent(error) ? Microsoft.graphConsentMessage()
          : error.message === "calendar_conflict" ? "This event changed elsewhere. Refresh and try again."
          : Calendar.nativeRequestError(String(source && source.kind || ""))
      }
      callback(result, reason)
    })
  }

  function createNativeEvent() {
    var fields = {}
    if (eventSource.kind === "google" && service.backendCanGoogleCalendars === true)
      fields.sendUpdates = eventDraft.sendUpdates
    if (eventSource.kind === "caldav" || eventSource.kind === "icloud") {
      var base = String(eventSource.url || "")
      if (base.charAt(base.length - 1) !== "/") base += "/"
      fields.href = base + encodeURIComponent(eventDraft.uid) + ".ics"
      fields.body = eventDraft.ics
    } else fields.body = JSON.stringify(eventSource.kind === "google" ? eventDraft.google : eventDraft.graph)
    nativeRequest(eventSource, "create", fields, function(result, error) { root.finishEvent(!error, error) })
  }

  function startNativeWrite() {
    var fields = {}
    // Invariant: undo remains owned by the calendar scope where the write began.
    var scope = calendarScope
    if (writeSource.kind === "caldav" || writeSource.kind === "icloud") {
      fields.href = String(writeEvent.href || Calendar.caldavEventUrl(writeSource.url, writeEvent))
      if (!fields.href) { finishWrite(false, "The event's address is outside this calendar's server"); return }
      if (writeDraft) fields.body = writeDraft.ics
    } else {
      fields.eventId = String(writeSource.kind === "google" ? writeEvent.googleId : writeEvent.graphId)
      if (writeSource.kind === "google" && writeEvent.etag && service.backendCanGoogleCalendars === true)
        fields.ifMatch = writeEvent.etag
      if (writeSource.kind === "google" && writeDraft && service.backendCanGoogleCalendars === true)
        fields.sendUpdates = writeDraft.sendUpdates
      if (writeSource.kind === "google" && writeOp === "delete" && service.backendCanGoogleCalendars === true)
        fields.sendUpdates = writeEvent.deleteSendUpdates === "none" ? "none" : "all"
      if (writeDraft) fields.body = JSON.stringify(writeSource.kind === "google" ? writeDraft.google : writeDraft.graph)
    }
    nativeRequest(writeSource, writeOp, fields, function(result, error) {
      if (!error) root.undoChange = null
      if (!error) root.rememberUndo(result, fields.eventId, scope)
      if (error || !root.writeDraft || !root.writeDraft.destination) { root.finishWrite(!error, error); return }
      var move = { eventId: fields.eventId, destination: root.writeDraft.destination.calendarId || "primary",
        sendUpdates: root.writeDraft.sendUpdates }
      root.nativeRequest(root.writeSource, "move", move, function(moved, moveError) {
        root.finishWrite(!moveError, moveError ? "Changes were saved, but the calendar transfer failed. Refresh before trying again." : "")
        if (moveError && root.rangeStart && root.rangeEnd) root.refresh(root.rangeStart, root.rangeEnd)
      })
    })
  }

  function rememberUndo(result, eventId, scope) {
    if (writeOp !== "update" || writeSource.kind !== "google"
        || service.backendCanGoogleCalendars !== true || !writeEvent.start || !writeEvent.end
        || writeDraft.destination || scope !== calendarScope
        || (writeEvent.attendees || []).some(function(attendee) { return attendee.self !== true })
        || (writeDraft.google.attendees || []).some(function(attendee) { return attendee.self !== true })) return
    var saved = null
    try { saved = JSON.parse(result.body) } catch (parseError) {}
    if (!saved || !saved.etag) return
    var previous = writeEvent
    var inverse = Calendar.googleEventPatch({ title: previous.summary, description: previous.description,
      location: previous.location, start: previous.start.ms, end: previous.end.ms }, previous.start.allDay)
    if (writeDraft.google.conferenceData) inverse.conferenceData = previous.conferenceData || null
    if (writeDraft.google.recurrence !== undefined) inverse.recurrence = previous.recurrenceLines || []
    var preserved = ["reminders", "transparency", "visibility", "attendees"]
    for (var fieldIndex = 0; fieldIndex < preserved.length; fieldIndex++) {
      var field = preserved[fieldIndex]
      if (writeDraft.google[field] === undefined) continue
      if (previous[field] === undefined) return
      inverse[field] = previous[field]
    }
    if (!previous.start.allDay && previous.timeZone) {
      inverse.start.timeZone = previous.timeZone
      inverse.end.timeZone = previous.timeZone
    }
    undoChange = { source: writeSource, eventId: eventId, ifMatch: saved.etag,
      body: JSON.stringify(inverse), sendUpdates: "none", scope: scope }
  }

  function undoLastChange() {
    if (!undoChange || creatingEvent || eventWriting) return
    if (undoChange.scope !== calendarScope) { undoChange = null; return }
    if (service.backendCanGoogleCalendars !== true) { lastError = "Update the backend to undo calendar changes"; return }
    var change = undoChange
    undoChange = null
    eventWriting = true
    nativeRequest(change.source, "update", { eventId: change.eventId, ifMatch: change.ifMatch,
      body: change.body, sendUpdates: change.sendUpdates }, function(result, error) {
      root.eventWriting = false
      if (root.rangeStart && root.rangeEnd) root.refresh(root.rangeStart, root.rangeEnd)
      if (error) root.lastError = error
    })
  }

  function saveCalDavPassword(secret) {
    if (discoveringCalendars) return
    var password = String(secret || "")
    if (password === "") { passwordSaved(false, "Enter the calendar password"); return }
    var values = sourceList && Array.isArray(sourceList.sources) ? sourceList.sources : []
    var targets = []
    for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
      if (values[valueIndex] && values[valueIndex].kind === "caldav") targets.push(values[valueIndex])
    }
    if (targets.length === 0) { passwordSaved(false, "No CalDAV calendars are configured"); return }
    passwordToSave = password
    password = ""
    passwordSaveQueue = targets
    savingPassword = true
    storeNextPassword()
  }

  function addCalDavCalendar(raw, secret) {
    if (savingSource || discoveringCalendars) return
    var candidate = raw || {}
    candidate.kind = "caldav"
    candidate.id = Sources.sourceId(candidate, sourceList)
    candidate.enabled = true
    var checked = Sources.validate(candidate)
    if (!checked.ok) { calendarSaved(false, checked.error); return }
    if (String(secret || "") === "") {
      calendarSaved(false, "Add the calendar password")
      return
    }
    sourceBeingSaved = checked.source
    sourceSecret = String(secret)
    sourceWritePayload = Sources.serialize(Sources.add(sourceList, checked.source))
    savingSource = true
    writeSources()
  }

  function removeCalendar(sourceId) {
    if (savingSource || discoveringCalendars) return
    sourceBeingSaved = null
    sourceSecret = ""
    sourceWritePayload = Sources.serialize(Sources.remove(sourceList, sourceId))
    refreshAfterSourceWrite = true
    savingSource = true
    writeSources()
  }

  function setSourceEnabled(sourceId, enabled) {
    if (savingSource || discoveringCalendars) return
    var values = availableSources && Array.isArray(availableSources.sources)
      ? availableSources.sources : []
    var source = null
    for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
      if (values[valueIndex] && values[valueIndex].id === String(sourceId)) { source = values[valueIndex]; break }
    }
    if (!source) return
    var next = Sources.add(sourceList, source)
    next = Sources.setEnabled(next, source.id, enabled)
    sourceBeingSaved = null
    sourceSecret = ""
    sourceWritePayload = Sources.serialize(next)
    refreshAfterSourceWrite = true
    savingSource = true
    writeSources()
  }

  function colorKeyFor(sourceId) {
    var values = availableSources && Array.isArray(availableSources.sources)
      ? availableSources.sources : []
    for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
      if (values[valueIndex] && values[valueIndex].id === String(sourceId)) return values[valueIndex].colorKey
    }
    return Sources.defaultColorKey(sourceId)
  }

  function setDefaultCalendar(sourceId) {
    if (savingSource || discoveringCalendars) return
    var chosen = sourceById(availableSources, sourceId)
    if (!chosen || chosen.readOnly) return
    var next = Sources.add(sourceList, chosen)
    next.sources = next.sources.map(function(source) {
      var value = Sources.makeSource(source)
      if (value.accountId === chosen.accountId) value.preferred = value.id === chosen.id
      return value
    })
    sourceBeingSaved = null
    sourceSecret = ""
    sourceWritePayload = Sources.serialize(next)
    refreshAfterSourceWrite = false
    savingSource = true
    writeSources()
  }

  function setReminderPolicy(sourceId, enabled, minutes) {
    if (savingSource || discoveringCalendars) return
    var source = sourceById(availableSources, sourceId)
    if (!Sources.nativeCalendarFeatures(source)) return
    var value = Sources.makeSource(source)
    value.remindersEnabled = enabled === true
    value.reminderMinutes = Math.max(-1, Math.min(40320, Math.floor(Number(minutes))))
    if (!isFinite(value.reminderMinutes)) return
    sourceWritePayload = Sources.serialize(Sources.add(sourceList, value))
    sourceBeingSaved = null
    sourceSecret = ""
    refreshAfterSourceWrite = false
    savingSource = true
    writeSources()
  }

  function setSourceColor(sourceId, colorKey) {
    if (savingSource || discoveringCalendars) return
    var values = availableSources && Array.isArray(availableSources.sources)
      ? availableSources.sources : []
    var source = null
    for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
      if (values[valueIndex] && values[valueIndex].id === String(sourceId)) { source = values[valueIndex]; break }
    }
    if (!source) return
    var next = Sources.add(sourceList, source)
    next = Sources.setColor(next, source.id, colorKey)
    sourceBeingSaved = null
    sourceSecret = ""
    sourceWritePayload = Sources.serialize(next)
    refreshAfterSourceWrite = false
    savingSource = true
    writeSources()
  }

  function updateCalendarPassword(source, secret) {
    if (savingSource || discoveringCalendars) return
    if (!source || source.kind !== "caldav") {
      calendarSaved(false, "Choose a CalDAV calendar")
      return
    }
    if (String(secret || "") === "") {
      calendarSaved(false, "Add the calendar password")
      return
    }
    sourceBeingSaved = source
    sourceSecret = String(secret)
    savingSource = true
    storeSourcePassword(true)
  }

  function storeNextPassword() {
    if (passwordSaveQueue.length === 0) {
      passwordToSave = ""
      savingPassword = false
      passwordSaved(true, "")
      if (rangeStart && rangeEnd) refresh(rangeStart, rangeEnd)
      return
    }
    var pending = passwordSaveQueue.slice()
    var source = pending.shift()
    passwordSaveQueue = pending
    if (!service || typeof service.credentialPut !== "function") {
      passwordToSave = ""
      passwordSaveQueue = []
      savingPassword = false
      passwordSaved(false, "Credential storage is unavailable")
      return
    }
    service.credentialPut("calendar-password", String(source.id || ""), "",
      passwordToSave, function(ok, error) {
        if (!ok) {
          root.passwordToSave = ""
          root.passwordSaveQueue = []
          root.savingPassword = false
          root.passwordSaved(false, String(error || "Could not save the password"))
          return
        }
        root.storeNextPassword()
      })
  }

  function sourceWriteFailed(error) {
    savingSource = false
    sourceSecret = ""
    sourceBeingSaved = null
    refreshAfterSourceWrite = false
    calendarSaved(false, String(error || "Could not save the calendar"))
    if (discoverySaving) {
      discoverySaving = false
      discoveryPendingCount = 0
      discoveryError = "The discovered calendars could not be saved"
      discoveryFinished(false, discoveryError, 0)
    }
  }

  function writeSources() {
    if (!service || typeof service.writeConfig !== "function") {
      sourceWriteFailed("Settings storage is unavailable")
      return
    }
    service.writeConfig("calendars.json", sourceWritePayload, function(ok, error) {
      if (!ok) { root.sourceWriteFailed(error); return }
      root.sourceList = Sources.load(root.sourceWritePayload)
      if (!root.sourceBeingSaved) {
        root.savingSource = false
        root.calendarSaved(true, "")
        if (root.discoverySaving) {
          var count = root.discoveryPendingCount
          root.discoverySaving = false
          root.discoveryPendingCount = 0
          root.discoveryFinished(true, "", count)
        }
        if (root.refreshAfterSourceWrite && root.rangeStart && root.rangeEnd)
          root.refresh(root.rangeStart, root.rangeEnd)
        root.refreshAfterSourceWrite = false
        return
      }
      root.storeSourcePassword(true)
    })
  }

  function storeSourcePassword(refreshAfter) {
    if (!service || typeof service.credentialPut !== "function") {
      sourceWriteFailed("Credential storage is unavailable")
      return
    }
    var sourceId = sourceBeingSaved ? String(sourceBeingSaved.id || "") : ""
    var secret = sourceSecret
    service.credentialPut("calendar-password", sourceId, "", secret, function(ok, error) {
      root.sourceSecret = ""
      root.sourceBeingSaved = null
      root.savingSource = false
      if (!ok) {
        root.calendarSaved(false, String(error || "Could not save the password"))
        return
      }
      root.calendarSaved(true, "")
      if (refreshAfter && root.rangeStart && root.rangeEnd)
        root.refresh(root.rangeStart, root.rangeEnd)
    })
  }

  function replaceActiveSourceEvents(values, source) {
    if (refreshScope !== calendarScope) return
    var sourceId = source ? String(source.id || "") : ""
    var next = events.filter(function(event) {
      return String(event && event.sourceId || "") !== sourceId
    })
    var additions = Array.isArray(values) ? values : []
    for (var additionIndex = 0; additionIndex < additions.length; additionIndex++) {
      additions[additionIndex].sourceName = source
        ? String(source.name || source.id || "Calendar") : "Calendar"
      next.push(additions[additionIndex])
    }
    next.sort(Calendar.compareEvents)
    setEvents(next)
  }

  function setEvents(next) {
    if (!Calendar.sameEvents(events, next)) events = next
  }

  function processNext() {
    if (queue.length === 0) {
      if (activeReads > 0) return
      loading = false
      var enabled = sourcesForAccount(refreshAccountId).sources.filter(function(source) {
        return root.sourceIncluded(source)
      }).map(function(source) { return String(source.id || "") })
      var allowed = {}
      for (var enabledIndex=0;enabledIndex<enabled.length;enabledIndex++) allowed[enabled[enabledIndex]]=true
      if (refreshScope===calendarScope) setEvents(events.filter(function(event) {
        return allowed[String(event && event.sourceId || "")] === true
      }))
      if (!sharedCache && rangeStart && rangeEnd && refreshScope===calendarScope)
        eventCache.put(refreshScope,rangeStart,rangeEnd,events,enabled)
      return
    }
    while (activeReads<2 && queue.length>0) {
      var pending=queue.slice()
      var source=pending.shift()
      queue=pending
      activeReads++
      startNativeList(source,refreshSerial,rangeStart,rangeEnd)
    }
  }

  function startNativeList(source, serial, start, end) {
    var requestedAt=sharedCache ? sharedCache.reserve() : Date.now()
    var fields={start:new Date(start).toISOString(),end:new Date(end).toISOString()}
    if (source.kind === "caldav" || source.kind === "icloud") fields.body=Calendar.caldavReport(start,end)
    nativeRequest(source,"list",fields,function(result,error) {
      var values=result && Array.isArray(result.events) ? result.events : null
      if (!error && !values) {
        var body=String(result && result.body || "")
        if (source.kind === "caldav" || source.kind === "icloud") values=Calendar.eventsFromCaldav(body,source.id,start,end)
        else {
          var payload=null
          try {payload=JSON.parse(body)} catch(parseError) {}
          if (!payload) error="The calendar returned an unreadable response"
          else values=source.kind === "google" ? Calendar.eventsFromGoogle(payload,source.id) : Calendar.eventsFromGraph(payload,source.id)
        }
      }
      if (!error && root.sharedCache) root.sharedCache.put("sources",start,end,values || [],[String(source.id)],requestedAt)
      if (serial!==root.refreshSerial) return
      root.activeReads--
      if (error) {
        root.lastError=Sources.errorLabel(source,root.service ? root.service.accountSummaries : []) + ": " + error
      } else root.replaceActiveSourceEvents(values,source)
      root.processNext()
    })
  }

  function warmRange(start,end,stillVisible) {
    if (!sharedCache || !sharedCache.loaded || !service || !service.backend || Number(service.backend.apiVersion)<8) return
    var sources=sourcesForAccount(accountId).sources.filter(function(source){return root.sourceIncluded(source)})
    var serial=refreshSerial
    function next() {
      if (!root || serial!==root.refreshSerial || root.loading || sources.length===0
          || (typeof stillVisible === "function" && !stillVisible())) return
      var source=sources.shift()
      if (root.sharedCache.covers("sources",start,end,source.id)) {Qt.callLater(next);return}
      var requestedAt=root.sharedCache.reserve()
      var fields={start:new Date(start).toISOString(),end:new Date(end).toISOString()}
      if(source.kind === "caldav" || source.kind === "icloud") fields.body=Calendar.caldavReport(start,end)
      root.nativeRequest(source,"list",fields,function(result,error) {
        if (!error && result && Array.isArray(result.events) && root.sharedCache)
          root.sharedCache.put("sources",start,end,result.events,[String(source.id)],requestedAt)
        Qt.callLater(next)
      })
    }
    next()
  }

  FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    // Invariant: source-key changes trigger refresh; also refreshing on file load would duplicate requests.
    onLoaded: {
      root.sourceList = Sources.load(text())
      root.sourcesLoaded = true
    }
    onFileChanged: reload()
    // Invariant: repeated absent-file notifications must not restart refresh when backend registry reads touch the directory.
    onLoadFailed: {
      if (!root.sourceList || !Array.isArray(root.sourceList.sources)
          || root.sourceList.sources.length > 0)
        root.sourceList = Sources.emptyList()
      root.sourcesLoaded = true
    }
  }

  Connections {
    target: root.sharedCache
    ignoreUnknownSignals: true
    function onRestored() { if (root.rangeStart && root.rangeEnd && !root.loading) root.refresh(root.rangeStart,root.rangeEnd) }
  }
  CalendarCache {
    id: eventCache
    backend: root.service ? root.service.backend : null
    cacheName: root.cacheName
    onRestored: {
      if (root.rangeStart && root.rangeEnd && !root.loading)
        root.refresh(root.rangeStart, root.rangeEnd)
    }
  }

}

import QtQuick 2.15
import QtTest 1.3
import "../../calendar" as Omamail

Item {
  width: 400
  height: 300

  QtObject {
    id: mailService

    property var requests: []
    property var nextResult: ({ body: "{}", status: 200 })
    property var nextError: null
    property bool backendCanDiscoverCalendars: true
    property bool backendCanGoogleCalendars: true
    property var discoveryCallback: null
    property var credentialWrites: []
    property var configWrites: []
    property var configCallback: null
    property var backend: ({ ready: false, call: function(method, params, callback) {
      mailService.requests.push({ method: method, params: params })
      if (method === "calendar.discover") {
        mailService.discoveryCallback = callback
        return
      }
      callback(mailService.nextResult, mailService.nextError)
    } })
    property bool unifiedCalendarView: false
    property var accountSummaries: [
      { id: "work@example.com", email: "work@example.com",
        provider: "gmail", calendarProvider: "google", signedIn: true },
      { id: "one@gmail.com", email: "one@gmail.com",
        provider: "gmail", signedIn: true },
      { id: "two@gmail.com", email: "two@gmail.com",
        provider: "gmail", signedIn: true }
    ]

    function withGoogleAccessToken(_accountId, callback) {
      callback("", "not used by this test")
    }
    function credentialPut(kind, accountId, clientId, secret, callback) {
      credentialWrites.push({kind:kind,accountId:accountId,clientId:clientId,secret:secret})
      callback(true, "")
      return true
    }
    function writeConfig(name, payload, callback) {
      configWrites.push({name:name, payload:payload})
      configCallback = callback
    }
  }

  Omamail.CalendarController {
    id: controller
    service: mailService
    pluginDir: "/tmp/omamail-test"
    accountId: "work@example.com"
    sourceList: ({
      version: 1,
      sources: [{
        id: "google:team", kind: "google", name: "Team",
        accountId: "work@example.com", calendarId: "team", discovered: true,
        enabled: true, readOnly: false, colorKey: "accent"
      }]
    })
  }

  TestCase {
    name: "CalendarController"
    SignalSpy { id: discoverySpy; target: controller; signalName: "discoveryFinished" }

    property var originalSummaries: JSON.parse(JSON.stringify(mailService.accountSummaries))

    function test_google_text_cannot_inject_event_properties_data() {
      return [{ tag: "create", update: false }, { tag: "update", update: true }]
    }

    function test_google_text_cannot_inject_event_properties(data) {
      var fields = {
        title: "Plan\rATTENDEE:mailto:uninvited@example.test",
        location: "Room 1\r\nBEGIN:VEVENT",
        description: "Notes\nEND:VEVENT\rORGANIZER:mailto:other@example.test",
        startMs: Date.UTC(2026, 9, 22, 10), endMs: Date.UTC(2026, 9, 22, 11)
      }
      var event = { uid: "original", googleId: "original", etag: "original-etag", sourceId: "google:team", organizer: {self: true} }
      var accepted = data.update
        ? controller.updateEvent("google:team", event, fields)
        : controller.createEvent("google:team", fields)
      verify(accepted)
      compare(mailService.requests.length, 1)
      var body = JSON.parse(mailService.requests[0].params.body)
      verify(body.summary.indexOf("ATTENDEE:mailto:uninvited@example.test") >= 0)
      verify(body.location.indexOf("BEGIN:VEVENT") >= 0)
      verify(body.description.indexOf("ORGANIZER:mailto:other@example.test") >= 0)
      compare(body.attendees, undefined)
      compare(body.organizer, undefined)
    }

    function test_settings_can_target_another_accounts_calendar() {
      controller.accountId = "one@gmail.com"
      verify(controller.findSource("google:two@gmail.com") === null,
        "event writes remain scoped to the current mailbox")
      controller.setReminderPolicy("google:two@gmail.com", false, -1)
      compare(mailService.configWrites.length, 1)
      var saved = JSON.parse(mailService.configWrites[0].payload).sources.filter(function(source) {
        return source.id === "google:two@gmail.com"
      })[0]
      compare(saved.remindersEnabled, false)
      mailService.configCallback(true, "")
      controller.setDefaultCalendar("google:two@gmail.com")
      compare(mailService.configWrites.length, 2)
      saved = JSON.parse(mailService.configWrites[1].payload).sources.filter(function(source) {
        return source.id === "google:two@gmail.com"
      })[0]
      compare(saved.preferred, true)
      mailService.configCallback(true, "")
    }

    function test_legacy_sources_cannot_enter_reminder_polling_or_settings() {
      var kinds = ["microsoft", "icloud", "caldav", "hey"]
      for (var kindIndex = 0; kindIndex < kinds.length; kindIndex++) {
        var source = {id:"legacy",kind:kinds[kindIndex],enabled:true,remindersEnabled:true,reminderMinutes:10}
        controller.reminderMode = false
        compare(controller.sourceIncluded(source), false)
        controller.reminderMode = true
        compare(controller.sourceIncluded(source), false)
        controller.sourceList = {version:1,sources:[source]}
        var writes = mailService.configWrites.length
        controller.setReminderPolicy("legacy", true, 5)
        controller.setSourceEnabled("legacy", true)
        controller.setDefaultCalendar("legacy")
        controller.setSourceColor("legacy", "blue")
        compare(mailService.configWrites.length, writes)
      }
      compare(controller.sourceIncluded({kind:"google",enabled:false,remindersEnabled:true}), true)
      controller.reminderMode = false
    }

    function test_confirmed_delete_carries_the_chosen_consequence() {
      mailService.backendCanGoogleCalendars = true
      controller.accountId = "one@gmail.com"
      controller.sourceList = {version:1,sources:[
        {id:"google:one@gmail.com",kind:"google",accountId:"one@gmail.com",calendarId:"primary",enabled:true}]}
      var event = {sourceId:"google:one@gmail.com",googleId:"meeting",recurringEventId:"series",
        summary:"Review",eventType:"default",etag:"e1",organizer:{self:true},
        attendees:[{self:true},{email:"sam@example.test"}]}
      var request = controller.deleteRequest("google:one@gmail.com", event)
      compare(request.choices.length, 3)
      request.choice = "none"
      verify(controller.confirmDelete(request))
      compare(mailService.requests[mailService.requests.length - 1].params.operation, "delete")
      compare(mailService.requests[mailService.requests.length - 1].params.sendUpdates, "none")
      compare(event.deleteSendUpdates, undefined, "the event on screen is not changed")
      controller.eventWriting = false
      mailService.requests = []
      mailService.nextResult = {body:JSON.stringify({id:"series",etag:"s1",summary:"Review",
        recurrence:["RRULE:FREQ=WEEKLY"],start:{dateTime:"2026-10-01T10:00:00Z"},end:{dateTime:"2026-10-01T11:00:00Z"},
        organizer:{self:true}})}
      request.choice = "series"
      verify(controller.confirmDelete(request))
      compare(mailService.requests[0].params.operation, "get")
      compare(mailService.requests[0].params.eventId, "series")
      compare(mailService.requests[1].params.operation, "delete")
      compare(mailService.requests[1].params.eventId, "series")
      controller.eventWriting = false
    }

    function test_undo_does_not_follow_the_view_to_another_account() {
      mailService.backendCanGoogleCalendars = true
      controller.accountId = "one@gmail.com"
      var change = {source:{id:"google:one@gmail.com",kind:"google",accountId:"one@gmail.com",calendarId:"primary"},
        eventId:"meeting",ifMatch:"etag",body:"{}",sendUpdates:"none",scope:controller.calendarScope}
      controller.undoChange = change
      controller.accountId = "two@gmail.com"
      mailService.requests = []
      controller.undoLastChange()
      compare(mailService.requests.length, 0)
      compare(controller.undoChange, null)
    }

    function test_old_backend_refuses_google_options_instead_of_dropping_them() {
      mailService.backendCanGoogleCalendars = false
      controller.accountId = "one@gmail.com"
      controller.sourceList = {version:1,sources:[
        {id:"google:one@gmail.com",kind:"google",accountId:"one@gmail.com",calendarId:"primary",enabled:true,canCreateMeet:true}]}
      var start = new Date(2026, 9, 1, 10).getTime()
      var base = {title:"Planning",allDay:false,startMs:start,endMs:start + 3600000,location:"",description:"",
        recurrence:{enabled:false}}
      var asks = [{guestEmails:"guest@example.org"}, {createMeet:true}]
      for (var requestIndex = 0; requestIndex < asks.length; requestIndex++) {
        var fields = JSON.parse(JSON.stringify(base))
        for (var key in asks[requestIndex]) fields[key] = asks[requestIndex][key]
        compare(controller.createEvent("google:one@gmail.com", fields), false)
      }
      compare(mailService.requests.length, 0)
      var event = {sourceId:"google:one@gmail.com",googleId:"meeting",eventType:"default",organizer:{self:true},
        start:{ms:start},end:{ms:start + 3600000}}
      verify(controller.rescheduleRefusal(event) !== "")
      mailService.backendCanGoogleCalendars = true
      compare(controller.rescheduleRefusal(event), "")
    }

    function test_immediate_transfer_sends_only_move_and_uses_new_event_identity() {
      mailService.backendCanGoogleCalendars = true
      controller.accountId = "one@gmail.com"
      controller.sourceList = {version:1,sources:[
        {id:"google:one@gmail.com",kind:"google",accountId:"one@gmail.com",calendarId:"primary",enabled:true},
        {id:"google:family",kind:"google",accountId:"one@gmail.com",calendarId:"family",enabled:true}]}
      controller.rangeStart = 0
      controller.rangeEnd = 0
      var event = {googleId:"meeting",eventType:"default",etag:"before",organizer:{self:true}}
      mailService.nextResult = {body:JSON.stringify({id:"meeting",etag:"after",summary:"Saved title",
        start:{dateTime:"2026-10-01T10:00:00Z"},end:{dateTime:"2026-10-01T11:00:00Z"},organizer:{self:true}})}
      var moved = null
      verify(controller.transferEvent("google:one@gmail.com","google:family",event,function(value,error) {
        compare(error,""); moved=value
      }))
      compare(mailService.requests.length,1)
      compare(mailService.requests[0].params.operation,"move")
      compare(mailService.requests[0].params.destination,"family")
      compare(mailService.requests[0].params.ifMatch,"before")
      compare(mailService.requests[0].params.body,undefined)
      compare(moved.sourceId,"google:family")
      compare(moved.etag,"after")
      compare(controller.eventWriting,false)
    }

    function init() {
      // Invariant: reset fixtures before assertions; a failing comparison aborts the case before trailing cleanup can run.
      mailService.accountSummaries = JSON.parse(JSON.stringify(originalSummaries))
      mailService.requests = []
      mailService.nextResult = ({ body: "{}", status: 200 })
      mailService.nextError = null
      mailService.backendCanDiscoverCalendars = true
      mailService.backendCanGoogleCalendars = true
      mailService.discoveryCallback = null
      mailService.backend.ready = false
      mailService.accountSummaries = [
        { id: "work@example.com", email: "work@example.com",
          provider: "gmail", calendarProvider: "google", signedIn: true },
        { id: "one@gmail.com", email: "one@gmail.com",
          provider: "gmail", signedIn: true },
        { id: "two@gmail.com", email: "two@gmail.com",
          provider: "gmail", signedIn: true }
      ]
      mailService.credentialWrites = []
      mailService.configWrites = []
      mailService.configCallback = null
      discoverySpy.clear()
      mailService.unifiedCalendarView = false
      controller.accountId = "work@example.com"
      controller.refreshScope = ""
      controller.refreshAccountId = ""
      controller.loading = false
      controller.rangeStart = 0
      controller.rangeEnd = 0
      controller.savingSource = false
      controller.discoveryChoices = null
      controller.creatingEvent = false
      controller.eventWriting = false
      controller.discoveringCalendars = false
      controller.discoveringAccountId = ""
      controller.discoverySaving = false
      controller.discoveryPendingCount = 0
      controller.discoveryError = ""
      controller.refreshAfterSourceWrite = false
      controller.sourceList = ({version:1, sources:[{
        id:"google:team", kind:"google", name:"Team",
        accountId:"work@example.com", calendarId:"team", discovered:true,
        enabled:true, readOnly:false, colorKey:"accent"
      }]})
    }

    function test_discovery_persists_through_platform_settings_data() {
      return [{tag:"saved", ok:true}, {tag:"failed", ok:false}]
    }

    function test_discovery_persists_through_platform_settings(data) {
      var before = JSON.stringify(controller.sourceList)
      mailService.accountSummaries = [{id:"work@example.com",
        calendarProvider:"google", signedIn:true}]
      mailService.backend.ready = true
      verify(controller.discoverAccountCalendars("work@example.com"))
      mailService.discoveryCallback({provider:"google", accountId:"work@example.com",
        calendars:[{sourceId:"google:work", calendarId:"work", name:"Work", readOnly:false}]}, null)
      compare(mailService.configWrites.length, 0)
      verify(controller.discoveryChoices !== null)
      controller.confirmDiscovery()
      compare(mailService.configWrites.length, 1)
      compare(mailService.configWrites[0].name, "calendars.json")
      compare(JSON.parse(mailService.configWrites[0].payload).sources.length, 1)
      compare(JSON.stringify(controller.sourceList), before, "no optimistic replacement before persistence")
      compare(controller.savingSource, true)
      compare(controller.discoverySaving, true)
      compare(discoverySpy.count, 0)
      controller.setSourceEnabled("google:team", false)
      compare(mailService.configWrites.length, 1, "no concurrent writer while saving discovery")
      mailService.configCallback(data.ok, data.ok ? "" : "synthetic write refusal")
      compare(controller.savingSource, false)
      compare(controller.discoverySaving, false)
      compare(controller.discoveryPendingCount, 0)
      compare(controller.refreshAfterSourceWrite, false)
      compare(discoverySpy.count, 1)
      compare(Array.prototype.slice.call(discoverySpy.signalArguments[0]), data.ok ? [true, "", 1]
        : [false, "The discovered calendars could not be saved", 0])
      compare(mailService.credentialWrites.length, 0, "discovery never writes a credential")
      if (data.ok) compare(controller.sourceList.sources.length, 1)
      else compare(JSON.stringify(controller.sourceList), before)
    }

    function test_native_request_preserves_the_callers_fields() {
      var fields = {start: "a", end: "b"}
      controller.nativeRequest({kind: "google", accountId: "one@gmail.com"}, "list", fields, function() {})
      compare(JSON.stringify(fields), '{"start":"a","end":"b"}')
      compare(mailService.requests[0].params.operation, "list")
    }

    function test_network_requests_are_owned_by_backend() {
      var source = {kind: "google", accountId: "one@gmail.com", id: "google:one@gmail.com"}
      var called = false
      controller.nativeRequest(source, "list", {start: "a", end: "b"}, function(result, error) {
        compare(error, "")
        compare(result.body, "{}")
        called = true
      })
      verify(called)
      compare(mailService.requests.length, 1)
      compare(mailService.requests[0].method, "calendar.request")
      compare(mailService.requests[0].params.source.accountId, "one@gmail.com")
      verify(mailService.requests[0].params.token === undefined)
    }

    function test_google_discovery_never_carries_credentials_or_accepts_a_removed_account() {
      mailService.accountSummaries = [{ id: "person@example.org", email: "person@example.org",
        provider: "gmail", calendarProvider: "google", signedIn: true }]
      mailService.backend.ready = true
      verify(controller.discoverAccountCalendars("person@example.org"))
      compare(mailService.requests.length, 1)
      compare(mailService.requests[0].method, "calendar.discover")
      compare(JSON.stringify(mailService.requests[0].params), JSON.stringify({accountId: "person@example.org"}))
      controller.setSourceEnabled("google:team", false)
      compare(mailService.configWrites.length, 0)
      mailService.discoveryCallback(null, {code: -32000, message: "calendar_auth_refused"})
      compare(controller.discoveringCalendars, false)
      compare(controller.discoveryError, "Sign in to this mailbox again")
      verify(controller.discoverAccountCalendars("person@example.org"))
      mailService.accountSummaries = []
      mailService.discoveryCallback({ provider: "google", accountId: "person@example.org", calendars: [] }, null)
      compare(controller.savingSource, false)
      compare(controller.discoveryError, "Calendars could not be discovered")
      compare(mailService.configWrites.length, 0)
      compare(mailService.credentialWrites.length, 0)
    }

    function test_discovery_failure_uses_only_known_rpc_messages() {
      var cases = [
        {message: "auth_signed_out", expected: "Sign in to this mailbox again"},
        {message: "calendar_auth_refused", expected: "Sign in to this mailbox again"},
        {message: "calendar_provider_unsupported", expected: "This mailbox does not support calendar discovery"},
        {message: "calendar_timeout", expected: "Calendar discovery timed out"},
        {message: "private diagnostic <img src='https://example.org/tracker'>", expected: "Calendars could not be discovered"}
      ]
      for (var caseIndex = 0; caseIndex < cases.length; caseIndex++) {
        compare(controller.discoveryFailure({code: -32000, message: cases[caseIndex].message}), cases[caseIndex].expected)
      }
      compare(controller.discoveryFailure(null), "Calendars could not be discovered")
    }

    function test_discovery_on_an_old_backend_makes_no_request_or_settings_write() {
      mailService.accountSummaries = [{ id: "person@example.org",
        calendarProvider: "google", signedIn: true }]
      mailService.backend.ready = true
      mailService.backendCanDiscoverCalendars = false
      compare(controller.discoverAccountCalendars("person@example.org"), false)
      compare(mailService.requests.length, 0)
      compare(mailService.configWrites.length, 0)
      compare(mailService.credentialWrites.length, 0)
      compare(controller.savingSource, false)
      compare(controller.discoveringCalendars, false)
    }
    function test_unsupported_saved_sources_are_preserved_without_requests_or_writes() {
      var sources = [{kind: "microsoft", calendarId: "other-calendar"}, {kind: "icloud"}, {kind: "caldav"}]
      var operations = ["list", "create", "update", "delete"]
      var replies = 0
      controller.sourceList = {version: 1, sources: sources}
      var before = JSON.stringify(controller.sourceList)
      for (var sourceIndex = 0; sourceIndex < sources.length; sourceIndex++) {
        for (var operationIndex = 0; operationIndex < operations.length; operationIndex++) {
          controller.nativeRequest(sources[sourceIndex], operations[operationIndex], {}, function(result, error) {
            compare(result, null)
            compare(error, "Only Google calendars are supported")
            replies++
          })
        }
      }
      compare(replies, 12)
      compare(mailService.requests.length, 0)
      compare(mailService.configWrites.length, 0)
      compare(mailService.credentialWrites.length, 0)
      compare(JSON.stringify(controller.sourceList), before)
    }

    function test_native_request_explains_google_recovery() {
      mailService.nextResult = null
      mailService.nextError = ({ code: -32000, message: "calendar_auth_refused" })
      var called = false
      controller.nativeRequest({ kind: "google" }, "list", {}, function(result, error) {
        compare(result, null)
        compare(error, "Google could not complete this calendar request. Refresh the event and try again")
        called = true
      })
      verify(called)
    }

    function test_a_calendar_error_names_a_discovered_calendar_with_its_mailbox() {
      mailService.accountSummaries = [
        { id: "me@contoso.com", email: "me@contoso.com", provider: "gmail", signedIn: true },
        { id: "other@contoso.com", email: "other@contoso.com", provider: "gmail", signedIn: true }
      ]
      controller.refreshScope = controller.calendarScope
      var source = { id: "google:other@contoso.com", kind: "google",
        name: "Calendar", accountId: "other@contoso.com", calendarId: "default-id", discovered: true }
      mailService.nextResult = null
      mailService.nextError = {code: -32000, message: "calendar_auth_refused"}
      controller.activeReads = 1
      controller.startNativeList(source, controller.refreshSerial, 1000, 2000)
      compare(controller.lastError, "Calendar · other@contoso.com: Google could not complete this calendar request. Refresh the event and try again")
      compare(mailService.requests.length, 1)
      compare(controller.activeReads, 0)
    }

    function test_native_request_does_not_display_backend_diagnostics() {
      mailService.nextResult = null
      mailService.nextError = ({ code: -32000, message: "private backend diagnostic" })
      var called = false
      controller.nativeRequest({ kind: "google" }, "list", {}, function(_result, error) {
        compare(error, "Google could not complete this calendar request. Refresh the event and try again")
        called = true
      })
      verify(called)
    }

    function sourceIds(list) {
      return list.sources.map(function(source) { return source.id })
    }

    function test_calendar_follows_the_active_mailbox_by_default() {
      var expected = ["google:team"]
      compare(JSON.stringify(sourceIds(controller.contextSources)),
        JSON.stringify(expected))
      compare(JSON.stringify(sourceIds(controller.sourcesForAccount(controller.accountId))),
        JSON.stringify(expected))
    }

    function test_unified_calendar_combines_every_signed_in_account() {
      mailService.unifiedCalendarView = true
      var expected = ["google:team", "google:one@gmail.com", "google:two@gmail.com"]
      compare(JSON.stringify(sourceIds(controller.contextSources)),
        JSON.stringify(expected))
      compare(JSON.stringify(sourceIds(controller.sourcesForAccount(controller.accountId))),
        JSON.stringify(expected))
    }

    // Performance: unified views share one calendar cache scope; account-scoped copies previously refetched on every mailbox switch.
    function test_the_scope_is_the_mailbox_only_when_the_view_follows_it() {
      compare(controller.calendarScope, "work@example.com")
      mailService.unifiedCalendarView = true
      compare(controller.calendarScope, "__unified__")
      controller.accountId = "one@gmail.com"
      compare(controller.calendarScope, "__unified__",
        "and it does not move when the mailbox does")
    }

    // Invariant: a mailbox switch does not invalidate an in-flight result for the same unified calendar scope.
    function test_a_mailbox_switch_does_not_discard_a_unified_refresh() {
      mailService.unifiedCalendarView = true
      controller.rangeStart = 1000
      controller.rangeEnd = 2000
      controller.refreshScope = controller.calendarScope
      controller.accountId = "two@gmail.com"
      compare(controller.refreshScope, controller.calendarScope,
        "the fetch in flight still belongs to the view on screen")
    }

    function test_the_default_mode_still_follows_the_mailbox() {
      controller.rangeStart = 1000
      controller.rangeEnd = 2000
      controller.refreshScope = controller.calendarScope
      controller.accountId = "one@gmail.com"
      verify(controller.refreshScope !== controller.calendarScope)
    }

    // Invariant: a controller without a mailbox already spans every source; changing its scope would orphan the bar cache.
    function test_a_controller_with_no_mailbox_keeps_its_scope() {
      controller.accountId = ""
      compare(controller.calendarScope, "")
      mailService.unifiedCalendarView = true
      compare(controller.calendarScope, "", "the bar preview was always unified")
    }

    function test_changing_calendar_scope_reloads_the_visible_range() {
      controller.rangeStart = 1000
      controller.rangeEnd = 2000
      controller.loading = true

      mailService.unifiedCalendarView = true

      compare(controller.rangeStart, 1000)
      compare(controller.rangeEnd, 2000)
      compare(controller.loading, false, "the obsolete request does not keep the visible range loading")
    }


    function test_a_calendar_arriving_with_a_sign_in_reloads_the_range() {
      var summaries = JSON.parse(JSON.stringify(mailService.accountSummaries))
      summaries[1].signedIn = false
      mailService.accountSummaries = summaries
      controller.accountId = "one@gmail.com"
      var cache = null
      for (var childIndex = 0; childIndex < controller.children.length; childIndex++) {
        if (controller.children[childIndex].cacheName !== undefined) cache = controller.children[childIndex]
      }
      verify(cache !== null, "the controller owns an event cache")
      cache.loaded = true
      controller.refresh(1000, 2000)
      mailService.requests = []
      mailService.accountSummaries = JSON.parse(JSON.stringify(summaries))
      compare(mailService.requests.length, 0, "a poll that changes nothing asks nothing")
      summaries = JSON.parse(JSON.stringify(summaries))
      summaries[1].signedIn = true
      mailService.accountSummaries = summaries
      var asked = mailService.requests.map(function(request) { return request.params.source.id })
      verify(asked.indexOf("google:one@gmail.com") >= 0, "asked " + JSON.stringify(asked))
      compare(mailService.requests[0].params.start, new Date(1000).toISOString())
      cache.loaded = false
    }

    // Invariant: repeated absent-file notifications must not start a registry-read and directory-touch refresh loop.
    function test_a_still_missing_sources_file_is_not_a_change() {
      var sourcesFile = null
      for (var childIndex = 0; childIndex < controller.data.length; childIndex++) {
        if (controller.data[childIndex] && typeof controller.data[childIndex].loadFailed === "function")
          sourcesFile = controller.data[childIndex]
      }
      verify(sourcesFile !== null, "the controller watches its sources file")
      var originalList = controller.sourceList
      var announced = 0
      var count = function() { announced++ }
      controller.sourceListChanged.connect(count)
      sourcesFile.loadFailed()
      compare(announced, 1, "an absent file empties a loaded list once")
      sourcesFile.loadFailed()
      sourcesFile.loadFailed()
      controller.sourceListChanged.disconnect(count)
      controller.sourceList = originalList
      compare(announced, 1)
      compare(controller.sourcesLoaded, true)
    }
  }
}

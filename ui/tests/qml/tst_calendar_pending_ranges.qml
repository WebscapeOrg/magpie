import QtQuick
import QtTest
import "../../calendar" as Calendar
import "../../calendar/Cache.js" as Cache

Item {
  width: 800; height: 600
  QtObject {
    id: backend
    property bool ready: false
    property int apiVersion: 8
    property var pending: []
    function call(method, params, callback) {
      if (method === "calendar.read") pending.push({params: params, callback: callback})
    }
  }
  Calendar.CalendarCache { id: shared; loaded: true }
  QtObject {
    id: service
    property var backend: backend
    property var calendarCache: shared
    property bool backendCanDiscoverCalendars: true
    property bool backendCanGoogleCalendars: true
    property bool unifiedCalendarView: false
    property var accountSummaries: [
      {id: "one@example.test", email: "one@example.test", provider: "gmail", signedIn: true},
      {id: "two@example.test", email: "two@example.test", provider: "gmail", signedIn: true}
    ]
  }
  Calendar.CalendarController {
    id: controller
    service: service
    pluginDir: "/tmp/magpie-calendar-acceptance"
    accountId: "one@example.test"
  }
  TestCase {
    name: "CalendarPendingRanges"
    when: windowShown
    function init() {
      controller.rangeStart = 0
      controller.rangeEnd = 0
      controller.accountId = "one@example.test"
      shared.store = Cache.emptyStore()
      shared.loaded = true
      backend.pending = []
    }
    function reply(index, title) {
      var request = backend.pending[index]
      var start = Date.parse(request.params.start) + 100
      var values = title === "" ? [] : [{uid: title, title: title,
        sourceId: request.params.source.id, start: {ms: start}, end: {ms: start + 100}}]
      request.callback({events: values}, null)
    }
    function test_old_month_and_account_replies_cannot_replace_the_visible_range() {
      controller.refresh(1000, 2000)
      compare(backend.pending.length, 1)
      controller.refresh(3000, 4000)
      compare(backend.pending.length, 2)
      reply(1, "current-month")
      reply(0, "old-month")
      compare(controller.rangeStart, 3000)
      compare(controller.events.length, 1)
      compare(controller.events[0].title, "current-month")
      compare(shared.get("sources", 3000, 4000, ["google:one@example.test"])[0].title, "current-month")
      controller.refresh(3000, 4000)
      var oldAccount = backend.pending.length - 1
      controller.accountId = "two@example.test"
      var newAccount = backend.pending.length - 1
      verify(newAccount > oldAccount)
      reply(newAccount, "other-account")
      reply(oldAccount, "late-original-account")
      compare(controller.accountId, "two@example.test")
      compare(controller.events.length, 1)
      compare(controller.events[0].title, "other-account")
    }
    function test_new_empty_range_wins_and_warm_reads_reuse_shared_cache() {
      controller.refresh(1000, 2000)
      controller.refresh(1000, 2000)
      compare(backend.pending.length, 2)
      reply(1, "")
      reply(0, "deleted-event")
      compare(controller.events.length, 0)
      compare(shared.get("sources", 1000, 2000, ["google:one@example.test"]).length, 0)
      verify(shared.knows("sources", 1000, 2000, "google:one@example.test"))
      controller.warmRange(1000, 2000, function() { return true })
      wait(20)
      compare(backend.pending.length, 2)
      controller.reminderMode = true
      compare(controller.cachedEventsFor(controller.calendarScope, 1000, 2000).length, 0)
      controller.reminderMode = false
    }
  }
}

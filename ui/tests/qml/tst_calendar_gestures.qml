import QtQuick
import QtTest
import "../../components" as Views
import "../../calendar/Calendar.js" as Calendar

Item {
  width: 1000
  height: 700
  SystemPalette { id: palette }
  QtObject {
    id: fixture
    property var service: null
    property bool eventWriting: false
    property bool loading: false
    property string sourceKind: "google"
    property bool apiReady: true
    property bool acceptReschedule: false
    function findSource(id) { return {id:id,kind:sourceKind} }
    function rescheduleRefusal(event) {
      var refusal = Calendar.writeRefusal(findSource(event.sourceId), event, "reschedule")
      return refusal === "" && !apiReady ? "Update the backend to move events by dragging" : refusal
    }
    signal eventUpdated(bool ok, string error)
    property var events: []
    function colorKeyFor() { return "accent" }
  }
  Views.WeekCalendarView {
    id: view
    anchors.fill: parent
    controller: fixture
    days: []
    nowMs: 0
    textColor: palette.text
    backgroundColor: palette.base
    accentColor: palette.highlight
    urgentColor: palette.highlight
    dimColor: palette.mid
    calendarBorderColor: palette.mid
    calendarTodayBackgroundColor: palette.alternateBase
    calendarBorderWidth: 1
    panelFontFamily: "sans-serif"
    selectedEventId: ""
  }
  Connections {
    target: view
    enabled: fixture.acceptReschedule
    function onEventRescheduled() { fixture.eventWriting = true }
  }
  SignalSpy { id: moved; target: view; signalName: "eventRescheduled" }
  SignalSpy { id: created; target: view; signalName: "createRange" }
  SignalSpy { id: allDayCreated; target: view; signalName: "createAllDay" }
  SignalSpy { id: activated; target: view; signalName: "eventActivated" }
  TestCase {
    name: "CalendarGestures"
    when: windowShown
    readonly property int quarterHourMs: 15 * 60 * 1000
    function init() {
      moved.clear()
      created.clear()
      allDayCreated.clear()
      activated.clear()
      fixture.eventWriting = false
      fixture.loading = false
      fixture.acceptReschedule = false
      fixture.events = [{sourceId:"personal",googleId:"meeting",uid:"uid",summary:"Planning",
        start:{ms:new Date(2026,9,1,10).getTime()},end:{ms:new Date(2026,9,1,11).getTime()}}]
      view.days = Calendar.weekDays(new Date(2026,9,1).getTime(), 1)
      view.pendingGesture = null
      view.dragPreview = null
      view.allDayDragStart = -1
      view.allDayDragEnd = -1
      fixture.sourceKind = "google"
      fixture.apiReady = true
      view.resetTimeScroll()
      waitForRendering(view)
      wait(50)
    }
    function dragMeetingEnd() {
      var drag = findChild(view, "calendar-event-drag-meeting")
      verify(drag !== null)
      mousePress(drag, drag.width / 2, drag.height - 2)
      mouseMove(drag, drag.width / 2, drag.height + 35, 20)
      mouseRelease(drag, drag.width / 2, drag.height + 35)
    }
    function test_legacy_provider_cannot_dispatch_resize() {
      for (var providerIndex = 0; providerIndex < 3; providerIndex++) {
        fixture.sourceKind = ["microsoft", "icloud", "caldav"][providerIndex]
        dragMeetingEnd()
        compare(moved.count, 0)
        compare(view.pendingGesture, null)
      }
    }
    function test_old_backend_cannot_dispatch_resize() {
      fixture.apiReady = false
      dragMeetingEnd()
      compare(moved.count, 0)
      compare(view.pendingGesture, null)
    }
    function test_pending_resize_is_immediate_and_failure_restores_it() {
      var originalEndMs = fixture.events[0].end.ms
      fixture.acceptReschedule = true
      dragMeetingEnd()
      verify(view.pendingGesture !== null)
      verify(view.pendingGesture.end > originalEndMs)
      compare(fixture.events[0].end.ms, originalEndMs)
      fixture.eventWriting = false
      fixture.eventUpdated(false, "Conflict")
      compare(view.pendingGesture, null)
    }
    function test_pending_resize_stays_until_refresh_finishes() {
      view.pendingGesture = {key:Calendar.eventKey(fixture.events[0]),start:fixture.events[0].start.ms,end:fixture.events[0].end.ms + quarterHourMs}
      fixture.eventUpdated(true, "")
      verify(view.pendingGesture !== null)
      fixture.loading = true
      fixture.loading = false
      compare(view.pendingGesture, null)
    }
    function test_gmail_generated_travel_event_does_not_dispatch_resize() {
      var event = JSON.parse(JSON.stringify(fixture.events[0]))
      event.eventType = "fromGmail"
      fixture.events = [event]
      wait(0)
      var drag = findChild(view, "calendar-event-drag-meeting")
      compare(drag.cursorShape, Qt.PointingHandCursor)
      mousePress(drag, drag.width / 2, drag.height - 2)
      mouseMove(drag, drag.width / 2, drag.height + 35, 20)
      compare(view.dragPreview, null)
      mouseRelease(drag, drag.width / 2, drag.height + 35)
      compare(moved.count, 0)
    }
    function test_resize_changes_only_the_end() {
      dragMeetingEnd()
      compare(moved.count, 1)
      compare(moved.signalArguments[0][1], fixture.events[0].start.ms)
      verify(moved.signalArguments[0][2] > fixture.events[0].end.ms)
      compare(moved.signalArguments[0][2] % quarterHourMs, 0)
    }
    function test_overlapping_events_have_separate_hit_targets() {
      var meeting = fixture.events[0]
      fixture.events = fixture.events.concat([{sourceId:"personal",googleId:"overlap",uid:"overlap",summary:"Review",
        start:{ms:meeting.start.ms + quarterHourMs},end:{ms:meeting.end.ms + quarterHourMs}}])
      wait(0)
      var first = findChild(view, "calendar-event-drag-meeting")
      var second = findChild(view, "calendar-event-drag-overlap")
      verify(first !== null && second !== null)
      var left = first.mapToItem(view, 0, 0)
      var right = second.mapToItem(view, 0, 0)
      verify(left.x + first.width <= right.x)
    }
    function test_empty_time_drag_creates_a_range() {
      var slots = findChild(view, "calendar-time-slots-2026-10-01")
      verify(slots !== null)
      var scrollOffsetY = findChild(view, "calendar-time-scroll").contentY
      mousePress(slots, slots.width / 2, scrollOffsetY + 20)
      mouseMove(slots, slots.width / 2, scrollOffsetY + 70, 20)
      verify(view.dragPreview !== null)
      verify(view.dragPreview.label.indexOf("–") > 0)
      mouseRelease(slots, slots.width / 2, scrollOffsetY + 70)
      compare(view.dragPreview, null)
      compare(created.count, 1)
      verify(created.signalArguments[0][1] > created.signalArguments[0][0])
      compare(created.signalArguments[0][0] % quarterHourMs, 0)
      compare(created.signalArguments[0][1] % quarterHourMs, 0)
    }
    function test_empty_all_day_lane_creates_single_and_multi_day_ranges() {
      compare(view.allDayCount, 0)
      var lane = findChild(view, "calendar-all-day-lane")
      verify(lane.visible && lane.height > 0)
      var slots = findChild(view, "calendar-all-day-slots-2026-10-01")
      mouseClick(slots, slots.width / 2, slots.height / 2)
      compare(allDayCreated.count, 1)
      compare(allDayCreated.signalArguments[0][0], new Date(2026,9,1).getTime())
      compare(allDayCreated.signalArguments[0][1], new Date(2026,9,2).getTime())
      mousePress(slots, slots.width / 2, slots.height / 2)
      mouseMove(slots, -slots.width / 2, slots.height / 2, 20)
      mouseRelease(slots, -slots.width / 2, slots.height / 2)
      compare(allDayCreated.count, 2)
      compare(allDayCreated.signalArguments[1][0], new Date(2026,8,30).getTime())
      compare(allDayCreated.signalArguments[1][1], new Date(2026,9,2).getTime())
      compare(view.allDayDragStart, -1)
    }
    function test_long_timed_event_moves_to_top_lane_and_keeps_original_times() {
      var stay = {sourceId:"personal",googleId:"stay",uid:"stay",summary:"Holiday",
        start:{ms:new Date(2026,8,29,12).getTime()},end:{ms:new Date(2026,9,3,12).getTime()}}
      fixture.events = fixture.events.concat([stay])
      wait(0)
      var bar = findChild(view,"calendar-all-day-event-stay")
      verify(bar !== null && bar.visible)
      verify(bar.width > view.width / 2)
      compare(findChild(view,"calendar-event-drag-stay"),null)
      compare(view.firstHour,0)
      mouseClick(bar,bar.width-10,bar.height/2)
      compare(activated.count,1)
      compare(activated.signalArguments[0][0].start.ms,stay.start.ms)
      compare(activated.signalArguments[0][0].start.allDay,undefined)
      view.days = [view.days[3]]
      wait(0)
      verify(findChild(view,"calendar-all-day-event-stay").visible)
      compare(findChild(view,"calendar-event-drag-stay"),null)
    }
    function test_day_and_week_scroll_to_late_evening_and_early_morning() {
      var originalDays = view.days
      var scroll = findChild(view, "calendar-time-scroll")
      for (var viewIndex = 0; viewIndex < 2; viewIndex++) {
        view.days = viewIndex === 0 ? [originalDays[3]] : originalDays
        wait(1)
        compare(view.firstHour, 0)
        compare(view.lastHour, 24)
        for (var scrollStep = 0; scrollStep < 20; scrollStep++) mouseWheel(scroll, scroll.width - 20, scroll.height / 2, 0, -120)
        compare(Math.round(scroll.contentY + scroll.height), Math.round(scroll.contentHeight))
        var slots = findChild(view, "calendar-time-slots-2026-10-01")
        created.clear()
        var lateHourY = 23 * scroll.hourHeight
        mousePress(slots, slots.width / 2, lateHourY)
        mouseMove(slots, slots.width / 2, lateHourY + scroll.hourHeight / 2, 20)
        mouseRelease(slots, slots.width / 2, lateHourY + scroll.hourHeight / 2)
        compare(created.count, 1)
        compare(new Date(created.signalArguments[0][0]).getHours(), 23)
        for (var scrollStep = 0; scrollStep < 20; scrollStep++) mouseWheel(scroll, scroll.width - 20, scroll.height / 2, 0, 120)
        compare(scroll.contentY, 0)
      }
    }
  }
}

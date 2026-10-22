import QtQuick
import QtTest
import "../../components" as Views
import "../../calendar/Calendar.js" as Calendar

Item {
  width: 1000
  height: 700
  SystemPalette { id: palette }
  property string shortcutFired: ""
  Shortcut { sequence: "j"; onActivated: shortcutFired = "j" }
  QtObject {
    id: serviceFixture
    property bool backendCanGoogleCalendars: true
    property string calendarPalettePath: ""
  }
  QtObject {
    id: fixture
    property var service: serviceFixture
    property var source: ({id:"google:test",kind:"google",calendarId:"primary",readOnly:false})
    property var availableSources: ({sources:[source]})
    property var events: []
    property var pending: []
    property bool sourcesLoaded: false
    property bool loading: false
    property bool clockRunning: false
    property bool eventWriting: false
    property double nowMs: Date.now()
    property string lastError: ""
    function findSource(id) { return source }
    function colorKeyFor(id) { return "accent" }
    function refresh(start, end) {}
    function nativeRequest(source, operation, fields, callback) {
      pending = pending.concat([{operation:operation,fields:fields,callback:callback}])
    }
  }
  Views.CalendarView {
    id: view
    anchors.fill: parent
    controller: fixture
    textColor: palette.text
    backgroundColor: palette.base
    accentColor: palette.highlight
    urgentColor: palette.highlight
    dimColor: palette.mid
    calendarBorderColor: palette.mid
    calendarTodayBackgroundColor: palette.alternateBase
    calendarBorderWidth: 1
    panelFontFamily: "sans-serif"
  }
  SignalSpy { id: created; target: view; signalName: "createAt" }
  TestCase {
    name: "CalendarDetailRefresh"
    when: windowShown
    function resource(id, count) {
      return {id:id,iCalUID:id,etag:"version-1",summary:"Planning",
        start:{dateTime:"2026-10-25T10:00:00Z"},end:{dateTime:"2026-10-25T11:00:00Z"},
        attendees:count === 2 ? [{email:"one@example.test"},{email:"two@example.test"}]
          : [{email:"one@example.test"}]}
    }
    function event(id) { return Calendar.eventsFromGoogle({items:[resource(id,1)]},fixture.source.id)[0] }
    function reply(index, id, count) { fixture.pending[index].callback({body:JSON.stringify(resource(id,count))}, "") }
    function init() {
      view.closeDetail()
      fixture.pending = []
      fixture.events = [event("first"),event("second")]
      created.clear()
    }
    function test_month_day_click_uses_nine_local_time_data() {
      return [{tag: "spring-transition", month: 2, day: 29, iso: "2026-03-29"},
        {tag: "autumn-transition", month: 9, day: 25, iso: "2026-10-25"}]
    }
    function test_month_day_click_uses_nine_local_time(data) {
      fixture.events = []
      view.visibleMonth = new Date(2026, data.month, 1)
      view.setView("month")
      var day = findChild(view, "calendar-month-day-" + data.iso)
      verify(day !== null)
      waitForRendering(day)
      mouseClick(day, day.width / 2, day.height / 2)
      compare(created.count, 1)
      compare(created.signalArguments[0][0], new Date(2026, data.month, data.day, 9).getTime())
    }
    function test_click_refreshes_guests_and_same_etag_list_does_not_erase_them() {
      view.activateEvent(fixture.events[0])
      compare(fixture.pending.length,1)
      compare(fixture.pending[0].operation,"get")
      compare(view.detailLoading,true)
      reply(0,"first",2)
      compare(view.detailEvent.attendees.length,2)
      compare(view.detailLoading,false)
      fixture.events = [event("first"),event("second")]
      compare(view.detailOpen,true)
      compare(view.detailEvent.attendees.length,2)
    }
    function test_previous_event_response_cannot_replace_current_details() {
      view.activateEvent(fixture.events[0])
      view.activateEvent(fixture.events[1])
      reply(0,"first",2)
      compare(view.detailEvent.googleId,"second")
      reply(1,"second",2)
      compare(view.detailEvent.attendees.length,2)
    }
    function test_closed_details_are_not_reopened_by_late_response() {
      view.activateEvent(fixture.events[0])
      view.closeDetail()
      reply(0,"first",2)
      compare(view.detailOpen,false)
    }
    function test_month_today_follows_the_running_clock() {
      view.setView("month")
      verify(fixture.clockRunning, "A visible month keeps the current-date clock running")
      fixture.nowMs = new Date(2026, 9, 20, 23, 59).getTime()
      compare(view.todayIso, "2026-10-20")
      fixture.nowMs = new Date(2026, 9, 21, 0, 0).getTime()
      compare(view.todayIso, "2026-10-21")
      view.visible = false
      compare(fixture.clockRunning, false)
      view.visible = true
      fixture.nowMs = Date.now()
    }

    function test_agenda_model_survives_a_clock_tick() {
      view.visibleMonth = new Date(2026,9,1)
      fixture.nowMs = Date.UTC(2026,9,20)
      view.setView("agenda")
      fixture.events = [event("first"),event("second")]
      var agenda = view.agendaEvents
      compare(agenda.length,2)
      fixture.nowMs = Date.UTC(2026,9,20) + 60000
      fixture.events = [event("first"),event("second")]
      verify(view.agendaEvents === agenda, "an unchanged agenda keeps its model")
      fixture.nowMs = Date.UTC(2026,9,26)
      compare(view.agendaEvents.length,0)
      fixture.nowMs = Date.now()
      view.setView("month")
    }
    function test_busy_day_preview_leaves_window_shortcuts_live() {
      view.visibleMonth = new Date(2026,9,1)
      view.setView("month")
      var values = []
      for (var eventIndex = 0; eventIndex < 20; eventIndex++) values.push(event("keys-" + eventIndex))
      fixture.events = values
      wait(0)
      var day = findChild(view,"calendar-month-day-2026-10-25")
      mouseMove(day,day.width/2,day.height-5)
      var preview = findChild(view,"calendar-month-overflow")
      tryCompare(preview,"opened",true)
      shortcutFired = ""
      keyClick(Qt.Key_J)
      compare(shortcutFired,"j")
      verify(view.dismissPreview())
      compare(preview.opened,false)
      verify(!view.dismissPreview())
      mouseMove(view,5,5)
    }
    function test_overflow_hover_shows_all_events_and_opens_hidden_event() {
      view.visibleMonth = new Date(2026,9,1)
      view.setView("month")
      var values = []
      for (var eventIndex = 0; eventIndex < 20; eventIndex++) values.push(event("busy-" + eventIndex))
      fixture.events = values
      wait(0)
      var day = findChild(view,"calendar-month-day-2026-10-25")
      verify(day.overflowCount > 0)
      mouseMove(day,day.width/2,day.height-5)
      var popup = findChild(view,"calendar-month-overflow")
      tryCompare(popup,"opened",true)
      compare(popup.events.length,20)
      var scroll = findChild(view,"calendar-month-overflow-scroll")
      verify(scroll.contentHeight > scroll.height)
      mouseMove(scroll,scroll.width/2,10)
      wait(350)
      compare(popup.opened,true)
      var hiddenEvent = findChild(scroll,"calendar-overflow-event-busy-19")
      verify(hiddenEvent !== null)
      scroll.contentY = Math.min(hiddenEvent.y, scroll.contentHeight - scroll.height)
      wait(0)
      mouseClick(hiddenEvent,hiddenEvent.width/2,hiddenEvent.height/2)
      compare(view.detailEvent.googleId,"busy-19")
      compare(popup.opened,false)
      view.closeDetail()
    }
  }
}

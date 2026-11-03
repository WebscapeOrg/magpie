import QtQuick
import QtTest
import "../../components" as Mail
import "../../inbox/Spending.js" as Spending

Item {
  width: 640
  height: 480
  Component {
    id: backendFactory
    QtObject {
      property bool ready: true
      property int apiVersion: 8
      property var calls: []
      function call(method, params, done) { calls = calls.concat([{method: method, params: params, done: done}]) }
    }
  }
  Component {
    id: serviceFactory
    QtObject { property var backend: null }
  }
  Item {
    id: holder
    anchors.fill: parent
  }
  Component {
    id: panelFactory
    Mail.SpendingSettings {
      width: 480
      textColor: palette.windowText
      dimColor: palette.placeholderText
      accentColor: palette.highlight
      panelFontFamily: "sans-serif"
      SystemPalette { id: palette }
    }
  }
  TestCase {
    name: "SpendingSettings"
    when: windowShown
    property var backend
    property var service
    property var panel
    function init() {
      backend = createTemporaryObject(backendFactory, parent)
      service = createTemporaryObject(serviceFactory, parent, {backend: backend})
      holder.visible = true
      panel = createTemporaryObject(panelFactory, holder, {service: service})
      verify(panel)
    }
    function last(method) {
      var rows = backend.calls.filter(function(row) { return row.method === method })
      return rows[rows.length - 1]
    }
    function reply(day, week, month, since) {
      return {periods: {day: {descriptions: 0, assistant: 0, pictures: day},
                        week: {descriptions: 0, assistant: 0, pictures: week},
                        month: {descriptions: 0, assistant: 0, pictures: month}}, since: since}
    }
    function test_asks_for_the_three_periods_on_this_computers_clock() {
      var request = last("ai.spending")
      verify(request)
      var now = Date.now()
      var params = request.params
      compare(Object.keys(params).sort().join(","), "day,month,week")
      verify(params.day <= now && params.day > now - 86400000 - 3600000)
      verify(params.week <= params.day && params.week > params.day - 7 * 86400000 - 3600000)
      verify(params.month <= params.day && params.month > now - 31 * 86400000 - 3600000)
      compare(new Date(params.day).getDate(), new Date().getDate())
      compare(new Date(params.month).getDate(), 1)
      compare(params.week, Spending.starts(new Date(params.day + 43200000), Qt.locale().firstDayOfWeek).week,
        "the week starts on the locale's first day")
    }
    function firstInstant(at, date) {
      compare(new Date(at).getDate(), date)
      verify(new Date(at - 1).getDate() !== date)
    }
    // Qt's JavaScript engine moves a midnight that summer time skips into the day before; the
    // Makefile also runs this file in America/Santiago and America/Havana, where that happens.
    function test_each_start_is_the_first_instant_of_its_day() {
      var spring = Spending.starts(new Date(2026, 8, 6, 10), 1)
      firstInstant(spring.day, 6)
      firstInstant(spring.week, 31)
      firstInstant(spring.month, 1)
      var autumn = Spending.starts(new Date(2026, 10, 3, 10), 0)
      firstInstant(autumn.day, 3)
      firstInstant(autumn.week, 1)
      firstInstant(autumn.month, 1)
    }
    function test_refresh_stops_while_settings_is_hidden() {
      last("ai.spending").done(reply(0, 0, 0, null), null)
      var refresh = findChild(panel, "settings-spending-refresh")
      verify(refresh.running)
      holder.visible = false
      verify(!refresh.running)
      holder.visible = true
      verify(refresh.running)
    }
    function test_a_refusal_after_an_answer_hides_the_section() {
      last("ai.spending").done(reply(120000000, 120000000, 120000000, null), null)
      verify(panel.visible)
      panel.load()
      last("ai.spending").done(null, {code: -32601, message: "unknown_method"})
      verify(!panel.visible)
    }
    function test_older_engine_hides_the_section() {
      verify(!panel.visible)
      last("ai.spending").done(null, {code: -32012, message: "backend_needs_update"})
      verify(!panel.visible)
      panel.load()
      last("ai.spending").done(null, {code: -32601, message: "unknown_method"})
      verify(!panel.visible)
    }
    function test_engine_below_api_8_is_not_asked() {
      var old = createTemporaryObject(backendFactory, parent, {apiVersion: 7})
      var oldService = createTemporaryObject(serviceFactory, parent, {backend: old})
      var oldPanel = createTemporaryObject(panelFactory, parent, {service: oldService})
      compare(old.calls.length, 0)
      verify(!oldPanel.visible)
    }
    function test_shows_each_period_with_its_spoken_label() {
      last("ai.spending").done(reply(120000000, 4000000, 2410000000, 0), null)
      verify(panel.visible)
      compare(findChild(panel, "settings-spending-day").text, "$0.12")
      compare(findChild(panel, "settings-spending-week").text, "under $0.01")
      compare(findChild(panel, "settings-spending-month").text, "$2.41")
      var day = findChild(panel, "settings-spending-day").parent
      compare(day.Accessible.name, "Sender pictures, today: $0.12")
      var note = findChild(panel, "settings-spending-note")
      verify(note.text.indexOf("Sender pictures painted on this computer, estimated") === 0)
      compare(note.textFormat, Text.PlainText)
    }
    function test_partial_periods_say_when_counting_began() {
      last("ai.spending").done(reply(0, 0, 0, Date.now() - 60000), null)
      var note = findChild(panel, "settings-spending-note")
      verify(note.text.indexOf("Magpie began counting today at ") === 0)
    }
    function test_a_failure_is_explained_and_a_later_answer_replaces_it() {
      last("ai.spending").done(null, {code: -32000, message: "inbox_storage_unavailable"})
      verify(panel.visible)
      var note = findChild(panel, "settings-spending-note")
      compare(note.text, "Magpie could not read what it has spent. It tries again in a minute.")
      verify(!findChild(panel, "settings-spending-table").visible)
      verify(findChild(panel, "settings-spending-refresh").running)
      panel.load()
      last("ai.spending").done(reply(5000000, 5000000, 5000000, null), null)
      verify(findChild(panel, "settings-spending-table").visible)
      compare(findChild(panel, "settings-spending-day").text, "$0.01")
      verify(note.text.indexOf("Sender pictures painted") === 0)
    }
    function test_a_failure_after_an_answer_keeps_the_amounts() {
      last("ai.spending").done(reply(120000000, 120000000, 120000000, null), null)
      panel.load()
      last("ai.spending").done(null, {code: -32000, message: "inbox_storage_unavailable"})
      compare(findChild(panel, "settings-spending-day").text, "$0.12")
      verify(findChild(panel, "settings-spending-note").text.indexOf("Sender pictures painted") === 0)
    }
  }
}

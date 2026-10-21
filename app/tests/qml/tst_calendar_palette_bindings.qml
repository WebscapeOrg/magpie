import QtQuick
import QtTest
import Quickshell
import "../../../ui/components" as Components

TestCase {
  id: testCase
  name: "CalendarPaletteBindings"
  when: windowShown
  width: 700
  height: 600
  visible: true
  HostFixture { id: host }
  Component {
    id: detailComponent
    Components.CalendarEventDetail {
      width: 700
      height: 600
      controller: null
      event: null
      textColor: Qt.rgba(1, 1, 1, 1)
      backgroundColor: Qt.rgba(0.06, 0.06, 0.06, 1)
      accentColor: Qt.rgba(1, 0.5, 0, 1)
      urgentColor: Qt.rgba(1, 0.2, 0.2, 1)
      dimColor: Qt.rgba(0.67, 0.67, 0.67, 1)
      panelFontFamily: "monospace"
    }
  }
  Component {
    id: composerComponent
    Components.CalendarEventComposer {
      width: 700
      height: 600
      controller: null
      textColor: Qt.rgba(1, 1, 1, 1)
      backgroundColor: Qt.rgba(0.06, 0.06, 0.06, 1)
      accentColor: Qt.rgba(1, 0.5, 0, 1)
      urgentColor: Qt.rgba(1, 0.2, 0.2, 1)
      dimColor: Qt.rgba(0.67, 0.67, 0.67, 1)
      panelFontFamily: "monospace"
    }
  }
  function test_calendar_colors_initialize_without_binding_loops_data() {
    return [{tag: "details", component: detailComponent},
      {tag: "composer", component: composerComponent}]
  }
  function test_calendar_colors_initialize_without_binding_loops(data) {
    Quickshell.fileStore = host
    failOnWarning(/Binding loop detected/)
    var view = createTemporaryObject(data.component, testCase)
    verify(view)
    wait(0)
    if (view.eventColor !== undefined) compare(view.eventColor, view.accentColor)
    view.accentColor = Qt.rgba(0.1, 0.6, 0.9, 1)
    wait(0)
    if (view.eventColor !== undefined) compare(view.eventColor, view.accentColor)
  }
}

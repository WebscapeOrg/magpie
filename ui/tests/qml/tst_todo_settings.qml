import QtQuick
import QtTest
import "../../components" as Mail

Item {
  width: 640
  height: 640
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
  Component {
    id: panelFactory
    Mail.TodoSettings {
      width: 480
      textColor: palette.windowText
      dimColor: palette.placeholderText
      accentColor: palette.highlight
      panelFontFamily: "sans-serif"
      SystemPalette { id: palette }
    }
  }
  TestCase {
    name: "TodoSettings"
    when: windowShown
    property var backend
    property var panel
    readonly property string link: "magpie://connect?server=https%3A%2F%2Fatlas.anotherdave.net&token=" + "Zq3_-".repeat(9)
    function init() {
      backend = createTemporaryObject(backendFactory, parent)
      var service = createTemporaryObject(serviceFactory, parent, {backend: backend})
      panel = createTemporaryObject(panelFactory, parent, {service: service})
      verify(panel)
    }
    function last() {
      var rows = backend.calls.filter(function(row) { return row.method === "inbox.todoConnection" })
      return rows[rows.length - 1]
    }
    function child(name) { return findChild(panel, "settings-todos-" + name) }
    function status() { return child("status").text }
    function test_an_engine_without_todos_hides_the_section() {
      verify(!panel.visible)
      last().done(null, {code: -32601, message: "method_not_found"})
      verify(!panel.visible)
    }
    function test_not_connected_says_where_the_link_is() {
      compare(last().params, {})
      last().done({connected: false, state: "off", open: 0, done: 0}, null)
      verify(panel.visible)
      compare(status(), "Not connected. In Atlas, open Settings → Connections → Magpie, choose Connect Magpie, and paste the link here.")
      verify(child("link").visible)
      verify(child("connect").visible)
      verify(!child("connect").enabled, "nothing to connect until a link is pasted")
      verify(!child("disconnect").visible)
      verify(child("link").password, "the link carries a key, so it is masked")
      verify(child("caption").text.indexOf("Magpie Mail never changes them") > 0)
    }
    function test_connecting_sends_the_link_once_and_clears_it() {
      last().done({connected: false, state: "off", open: 0, done: 0}, null)
      child("link").text = "  " + link + "\n"
      verify(child("connect").enabled)
      child("connect").clicked()
      compare(last().params, {link: link})
      compare(child("link").text, "", "the link is not kept in the field")
      compare(status(), "Checking")
      last().done({connected: true, state: "ready", open: 12, done: 5}, null)
      compare(status(), "Read for The Point: 12 open, 5 done in the last two weeks.")
      verify(!child("link").visible, "a working connection offers no field")
      verify(child("disconnect").visible)
    }
    function test_a_wrong_link_is_explained_and_cleared() {
      last().done({connected: false, state: "off", open: 0, done: 0}, null)
      child("link").text = "magpie://connect?server=https://atlas.evil.example&token=x"
      child("link").accepted()
      last().done(null, {code: -32000, message: "todos_link_invalid"})
      compare(status(), "That is not Atlas's link for Magpie. In Atlas, open Settings → Connections → Magpie and copy the link again.")
      compare(child("link").text, "")
      verify(child("link").visible)
    }
    function test_a_refused_key_asks_for_a_new_link_and_disconnect_forgets_it() {
      last().done({connected: true, state: "unauthorized", open: 0, done: 0}, null)
      compare(status(), "Atlas no longer accepts this connection. Connect Magpie again in Atlas and paste the new link.")
      verify(child("link").visible)
      verify(child("disconnect").visible)
      child("disconnect").clicked()
      compare(last().params, {link: ""})
      last().done({connected: false, state: "off", open: 0, done: 0}, null)
      verify(!child("disconnect").visible)
    }
    function test_a_read_that_failed_says_magpie_tries_again() {
      last().done({connected: true, state: "unavailable", open: 3, done: 0}, null)
      compare(status(), "Could not be read just now. Magpie Mail tries again in a few minutes.")
      verify(!child("link").visible)
    }
    function test_narrow_rows_keep_clear_space() {
      panel.width = 280
      last().done({connected: false, state: "off", open: 0, done: 0}, null)
      waitForItemPolished(panel)
      var items = [child("caption"), child("status"), child("link"), child("connect")]
      for (var index = 1; index < items.length; index++) {
        var above = items[index - 1].mapToItem(panel, 0, 0)
        var below = items[index].mapToItem(panel, 0, 0)
        verify(below.y >= above.y + items[index - 1].height + panel.spacing - 0.5, "space between " + items[index - 1].objectName + " and " + items[index].objectName)
        verify(items[index].width <= panel.width + 0.5)
      }
      verify(panel.spacing > 0)
    }
  }
}

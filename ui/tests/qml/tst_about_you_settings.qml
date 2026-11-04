import QtQuick
import QtTest
import "../../components" as Mail

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
  Component {
    id: panelFactory
    Mail.AboutYouSettings {
      width: 480
      textColor: palette.windowText
      dimColor: palette.placeholderText
      accentColor: palette.highlight
      panelFontFamily: "sans-serif"
      SystemPalette { id: palette }
    }
  }
  TestCase {
    name: "AboutYouSettings"
    when: windowShown
    property var backend
    property var service
    property var panel
    function init() {
      backend = createTemporaryObject(backendFactory, parent)
      service = createTemporaryObject(serviceFactory, parent, {backend: backend})
      panel = createTemporaryObject(panelFactory, parent, {service: service})
      verify(panel)
    }
    function last(method) {
      var rows = backend.calls.filter(function(row) { return row.method === method })
      return rows[rows.length - 1]
    }
    function writes() {
      return backend.calls.filter(function(row) { return row.method === "inbox.aboutYou" && row.params.text !== undefined })
    }
    function test_an_engine_without_the_bio_hides_the_section() {
      verify(!panel.visible)
      last("inbox.aboutYou").done(null, {code: -32601, message: "method_not_found"})
      verify(!panel.visible)
    }
    function test_the_saved_bio_is_shown_and_saving_sends_the_trimmed_text() {
      compare(last("inbox.aboutYou").params, {})
      last("inbox.aboutYou").done({text: "Sam Example, lives in Cork.", updated: 1, limit: 2000}, null)
      verify(panel.visible)
      var field = findChild(panel, "settings-about-you")
      var save = findChild(panel, "settings-about-you-save")
      var status = findChild(panel, "settings-about-you-status")
      compare(field.text, "Sam Example, lives in Cork.")
      verify(!save.visible, "nothing to save until the text changes")
      verify(status.text.indexOf("Magpie reads each email against this") === 0)
      field.text = "  Sam Example, lives in Cork.\nTwo children, Ada and Ben.  "
      verify(save.visible)
      save.clicked()
      var request = last("inbox.aboutYou")
      compare(request.params.text, "Sam Example, lives in Cork.\nTwo children, Ada and Ben.")
      compare(status.text, "Saving")
      verify(!field.enabled)
      request.done({text: "Sam Example, lives in Cork.\nTwo children, Ada and Ben.", updated: 2, limit: 2000}, null)
      compare(status.text, "Saved.")
      verify(!save.visible)
      verify(field.enabled)
    }
    function test_leaving_the_field_saves_a_change_once() {
      last("inbox.aboutYou").done({text: "", updated: 0, limit: 2000}, null)
      var field = findChild(panel, "settings-about-you")
      field.forceActiveFocus()
      verify(field.activeFocus)
      field.text = "Sam Example"
      findChild(panel, "settings-about-you-save").forceActiveFocus()
      compare(writes().length, 1)
      compare(last("inbox.aboutYou").params.text, "Sam Example")
      findChild(panel, "settings-about-you-save").clicked()
      compare(writes().length, 1, "a save already under way is not sent again")
    }
    function test_markup_invisible_characters_and_long_text_are_explained_and_not_sent() {
      last("inbox.aboutYou").done({text: "", updated: 0, limit: 20}, null)
      var field = findChild(panel, "settings-about-you")
      var status = findChild(panel, "settings-about-you-status")
      var save = findChild(panel, "settings-about-you-save")
      field.text = "Sam <b>Example</b>"
      save.clicked()
      compare(status.text, "Leave out the < and > characters.")
      field.text = "Sam​Example"
      save.clicked()
      compare(status.text, "Leave out invisible characters, such as those pasted from a web page.")
      field.text = "Sam Example lives in Cork"
      save.clicked()
      compare(status.text, "Keep it to 20 characters or fewer.")
      compare(writes().length, 0)
      field.text = "Sam Example"
      verify(status.text.indexOf("Magpie reads each email against this") === 0, "fixing the text clears the problem")
    }
    function test_clearing_the_bio_sends_empty_text_and_a_failure_keeps_the_text() {
      last("inbox.aboutYou").done({text: "Sam Example", updated: 1, limit: 2000}, null)
      var field = findChild(panel, "settings-about-you")
      var status = findChild(panel, "settings-about-you-status")
      field.text = ""
      findChild(panel, "settings-about-you-save").clicked()
      compare(last("inbox.aboutYou").params.text, "")
      last("inbox.aboutYou").done(null, {code: -32000, message: "storage"})
      compare(status.text, "This could not be saved. Try again.")
      compare(field.text, "")
      verify(findChild(panel, "settings-about-you-save").visible)
    }
    function test_a_reload_does_not_overwrite_unsaved_text() {
      last("inbox.aboutYou").done({text: "Sam Example", updated: 1, limit: 2000}, null)
      var field = findChild(panel, "settings-about-you")
      field.text = "Sam Example, Cork"
      panel.load()
      last("inbox.aboutYou").done({text: "Sam Example", updated: 1, limit: 2000}, null)
      compare(field.text, "Sam Example, Cork")
    }
    function test_tab_moves_out_of_the_field() {
      last("inbox.aboutYou").done({text: "Sam", updated: 1, limit: 2000}, null)
      var field = findChild(panel, "settings-about-you")
      field.forceActiveFocus()
      keyClick(Qt.Key_Tab)
      compare(field.text, "Sam", "Tab never types a tab into the bio")
    }
  }
}

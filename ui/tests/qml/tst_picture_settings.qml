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
    Mail.PictureSettings {
      width: 480
      textColor: palette.windowText
      dimColor: palette.placeholderText
      accentColor: palette.highlight
      panelFontFamily: "sans-serif"
      SystemPalette { id: palette }
    }
  }
  TestCase {
    name: "PictureSettings"
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
    function test_older_engine_hides_the_section() {
      verify(!panel.visible)
      last("inbox.pictureStatus").done(null, {code: -32012, message: "backend_needs_update"})
      verify(!panel.visible)
    }
    function test_key_is_sent_once_cleared_and_never_shown() {
      last("inbox.pictureStatus").done({present: false, problem: null, painted: 0, waiting: 0, spentTodayCents: 0, dailyLimitCents: 300}, null)
      verify(panel.visible)
      var field = findChild(panel, "settings-picture-key")
      var status = findChild(panel, "settings-picture-status")
      verify(field.password)
      verify(status.text.indexOf("Add an OpenAI API key") === 0)
      verify(!findChild(panel, "settings-picture-remove").visible)
      field.text = "  sk-synthetic-settings-key-0000000000 "
      field.accepted()
      var request = last("inbox.setPictureKey")
      compare(request.params.key, "sk-synthetic-settings-key-0000000000")
      verify(!field.enabled)
      request.done(null, {code: -32000, message: "pictures_key_invalid"})
      compare(status.text, "OpenAI did not accept this key. Paste a current key.")
      compare(field.text, "  sk-synthetic-settings-key-0000000000 ")
      field.accepted()
      last("inbox.setPictureKey").done({present: true, problem: null, painted: 0, waiting: 41, spentTodayCents: 0, dailyLimitCents: 300}, null)
      compare(field.text, "")
      compare(status.text, "0 sender pictures painted, 41 waiting. About $0.00 spent today of the $3.00 daily limit.")
      verify(status.text.indexOf("sk-") < 0)
      verify(findChild(panel, "settings-picture-remove").visible)
    }
    function test_an_unreadable_status_is_explained_in_place() {
      last("inbox.pictureStatus").done(null, {code: -32000, message: "pictures_key_storage"})
      verify(panel.visible)
      var status = findChild(panel, "settings-picture-status")
      compare(status.text, "The keyring could not be used. Unlock it, then try again.")
      panel.load()
      last("inbox.pictureStatus").done({present: true, problem: null, painted: 2, waiting: 0, spentTodayCents: 14, dailyLimitCents: 300}, null)
      compare(status.text, "2 sender pictures painted. About $0.14 spent today of the $3.00 daily limit.")
    }
    function test_a_locked_keyring_is_explained_and_not_polled() {
      var refresh = findChild(panel, "settings-picture-refresh")
      last("inbox.pictureStatus").done({present: true, problem: null, painted: 2, waiting: 5, spentTodayCents: 14, dailyLimitCents: 300}, null)
      verify(refresh.running)
      panel.load()
      last("inbox.pictureStatus").done({present: null, problem: "pictures_key_storage", painted: 2, waiting: 5, spentTodayCents: 14, dailyLimitCents: 300}, null)
      var status = findChild(panel, "settings-picture-status")
      compare(status.text, "The keyring could not be used. Unlock it, then open Settings again.")
      verify(!refresh.running)
      verify(!findChild(panel, "settings-picture-remove").visible)
    }
    function test_remove_key_returns_to_the_invitation() {
      last("inbox.pictureStatus").done({present: true, problem: "pictures_billing", painted: 3, waiting: 1, spentTodayCents: 21, dailyLimitCents: 300}, null)
      var status = findChild(panel, "settings-picture-status")
      verify(status.text.indexOf("no credit") > 0)
      findChild(panel, "settings-picture-remove").clicked()
      last("inbox.removePictureKey").done({present: false, problem: null, painted: 3, waiting: 1, spentTodayCents: 21, dailyLimitCents: 300}, null)
      verify(status.text.indexOf("Add an OpenAI API key") === 0)
      verify(!findChild(panel, "settings-picture-remove").visible)
    }
  }
}

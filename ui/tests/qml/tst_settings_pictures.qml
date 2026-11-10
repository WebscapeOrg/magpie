import QtQuick 2.15
import QtTest 1.3
import "../../components" as Omamail

// Invariant: the Settings page is shown and hidden, not rebuilt, so opening it must read the sender
// picture status again; otherwise a keyring problem stays on screen after the keyring is unlocked.
Item {
  width: 700
  height: 500

  QtObject {
    id: fakeBackend
    property bool ready: true
    property int apiVersion: 8
    property var calls: []
    function call(method, parameters, callback) {
      calls = calls.concat([{method: method, parameters: parameters, callback: callback}])
    }
    function last(method) {
      var rows = calls.filter(function(row) { return row.method === method })
      return rows.length ? rows[rows.length - 1] : null
    }
    function count(method) {
      return calls.filter(function(row) { return row.method === method }).length
    }
  }
  QtObject {
    id: fakeService
    property string activeAccountId: "a@example.org"
    property var accountSummaries: []
    property var accountSignatures: [
      { id: "a@example.org", email: "a@example.org", label: "", signature: "", provider: "gmail" }
    ]
    property int undoSendSeconds: 10
    property bool unifiedCalendarView: false
    property bool notifyNewMail: true
    property string contentDirection: "auto"
    property var auth: null
    property var backend: fakeBackend
    function setAccountSignatureHtml(_id, _html) {}
    function setAccountLabel(_id, _text) {}
    function setAccountSignature(_id, _text) {}
    function setUndoSendSeconds(_value) {}
    function setUnifiedCalendarView(_value) {}
    function setNotifyNewMail(_value) {}
    function setContentDirection(_value) {}
    function setAlwaysRenderHeavyMessages(_value) {}
  }

  Omamail.SettingsPage {
    id: page
    width: parent.width
    service: fakeService
    textColor: Qt.rgba(0.1, 0.1, 0.1, 1)
    dimColor: Qt.rgba(0.45, 0.45, 0.45, 1)
    accentColor: Qt.rgba(0.8, 0.4, 0, 1)
    urgentColor: Qt.rgba(0.8, 0.1, 0.1, 1)
    panelFontFamily: "monospace"
  }

  TestCase {
    name: "SettingsPictures"
    when: windowShown

    function test_opening_settings_reads_the_picture_status_again() {
      var first = fakeBackend.last("inbox.pictureStatus")
      verify(first, "the section asks for the status when the page is built")
      first.callback({present: null, problem: "pictures_key_storage", painted: 2, waiting: 0,
        spentTodayCents: 14, dailyLimitCents: 300}, null)
      var status = findChild(page, "settings-picture-status")
      compare(status.text, "The keyring could not be used. Unlock it, then open Settings again.")

      page.visible = false
      var asked = fakeBackend.count("inbox.pictureStatus")
      page.visible = true
      compare(fakeBackend.count("inbox.pictureStatus"), asked + 1)
      fakeBackend.last("inbox.pictureStatus").callback({present: true, problem: null, painted: 2, waiting: 0,
        spentTodayCents: 14, dailyLimitCents: 300}, null)
      compare(status.text, "2 sender pictures painted. About $0.14 spent today of the $3.00 daily limit.")
      verify(findChild(page, "settings-picture-remove").visible)
    }
  }
}

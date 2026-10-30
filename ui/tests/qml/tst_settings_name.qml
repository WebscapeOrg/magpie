import QtQuick 2.15
import QtTest 1.3
import "../../components" as Omamail

// Invariant: assigning field.text can pass while the field is unreachable; exercise real clicks and typing.
Item {
  width: 700
  height: 500

  QtObject {
    id: fakeBackend
    property bool ready: true
    property string method: ""
    property var parameters: null
    property var callback: null
    function call(method, parameters, callback) {
      fakeBackend.method = method; fakeBackend.parameters = parameters; fakeBackend.callback = callback
    }
  }
  QtObject {
    id: fakeService

    property string activeAccountId: "a@example.org"
    property var accountSummaries: []
    property var accountSignatures: [
      { id: "a@example.org", email: "a@example.org", label: "", signature: "",
        provider: "gmail" },
      { id: "b@example.net", email: "b@example.net", label: "Work", signature: "",
        provider: "gmail" },
      { id: "c@example.com", email: "c@example.com", label: "", signature: "",
        provider: "gmail" }
    ]
    property int undoSendSeconds: 10
    property bool unifiedCalendarView: false
    property bool notifyNewMail: true
    property string contentDirection: "auto"
    property var auth: null
    property var backend: fakeBackend
    property string signatureId: ""
    property string signatureHtml: ""
    function setAccountSignatureHtml(id, html) { signatureId = id; signatureHtml = html }

    property string namedId: ""
    property string namedText: ""
    property int nameWrites: 0

    function setAccountLabel(id, text) {
      namedId = String(id || "")
      namedText = String(text || "")
      nameWrites += 1
    }

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
    name: "SettingsName"
    when: windowShown

    function nameField() {
      return findChild(page, "settings-name-editor")
    }

    function init() {
      page.selectNameAccount("a@example.org")
      // Invariant: the fake does not persist writes; restore stored fields so typing cannot leak between tests.
      page.showNameAccount(page.signatureAccount("a@example.org"))
      fakeService.namedId = ""
      fakeService.namedText = ""
      fakeService.nameWrites = 0
    }

    function test_switches_expose_the_setting_name_data() {
      return [
        {tag: "bar", name: "showBarIconSwitch", label: "Show the icon in the bar"},
        {tag: "images", name: "imagesSwitch", label: "Always show remote images"},
        {tag: "heavy", name: "heavySwitch", label: "Always render heavy messages"},
        {tag: "suggestions", name: "suggestEventsSwitch", label: "Suggest calendar events from mail"},
        {tag: "notifications", name: "notifySwitch", label: "New mail notifications"}
      ]
    }
    function test_switches_expose_the_setting_name(data) {
      var toggle = findChild(page, data.name)
      verify(toggle)
      compare(toggle.Accessible.name, data.label)
    }

    function test_signature_import_waits_for_native_result_and_keeps_original_account() {
      fakeService.signatureHtml = ""
      page.selectedSignatureAccountId = "a@example.org"
      page.importStage = "read"
      page.importingAccountId = "a@example.org"
      page.importing = true
      page.finishImport(JSON.stringify({ok: true, mimeType: "image/png", data: "iVBORw0KGgoAAA=="}))
      compare(fakeBackend.method, "message.signatureImport")
      compare(fakeBackend.parameters.kind, "image")
      compare(page.importing, true)
      compare(fakeService.signatureHtml, "")
      page.selectedSignatureAccountId = "b@example.net"
      fakeBackend.callback({html: "<p>native</p>", plain: "", images: 1, dropped: 0, problem: ""}, null)
      compare(fakeService.signatureId, "a@example.org")
      compare(fakeService.signatureHtml, "<p>native</p>")
      compare(page.importing, false)
    }

    function test_the_field_is_on_the_page_and_starts_from_the_stored_name() {
      var field = nameField()
      verify(field, "the name field has to exist to be typed into")
      verify(field.width > 0)
      verify(field.height > 0)
      compare(field.enabled, true)
      compare(field.readOnly, false, "a field that cannot be written to is a label")
      compare(field.text, "", "this mailbox has no name yet")
      compare(field.placeholderText, "",
        "an empty field is empty: every prompt tried here was read as the name")
    }

    function test_clicking_the_field_gives_it_the_keyboard() {
      var field = nameField()
      verify(field)
      mouseClick(field, field.width / 2, field.height / 2)
      verify(field.activeFocus, "a click must put the cursor in the field")
    }

    function test_typing_into_it_reaches_the_mailbox_it_names() {
      var field = nameField()
      verify(field)
      mouseClick(field, field.width / 2, field.height / 2)
      verify(field.activeFocus)

      keyClick(Qt.Key_P)
      keyClick(Qt.Key_R)
      keyClick(Qt.Key_I)
      compare(field.text, "pri", "the keys have to land in the field")

      fakeService.nameWrites = 0
      keyClick(Qt.Key_Return)
      compare(fakeService.nameWrites, 1)
      compare(fakeService.namedId, "a@example.org")
      compare(fakeService.namedText, "pri")
    }

    function test_the_picker_moves_the_field_to_another_mailbox() {
      compare(page.selectedNameAccountId, "a@example.org")
      compare(nameField().text, "")

      page.selectNameAccount("b@example.net")
      compare(page.selectedNameAccountId, "b@example.net")
      compare(nameField().text, "Work", "the field shows that mailbox's own name")
    }

    function test_moving_away_saves_what_was_typed() {
      var field = nameField()
      mouseClick(field, field.width / 2, field.height / 2)
      keyClick(Qt.Key_X)
      compare(field.text, "x")

      page.selectNameAccount("b@example.net")
      compare(fakeService.nameWrites, 1)
      compare(fakeService.namedId, "a@example.org",
        "what was typed belongs to the mailbox it was typed for")
      compare(fakeService.namedText, "x")
    }


    function test_gmail_sender_names_are_not_reconfigured_in_mailbox_settings() {
      compare(findChild(page, "settings-sender-name-editor"), null)
      page.selectNameAccount("b@example.net")
      compare(findChild(page, "settings-sender-name-editor"), null)
    }
  }
}

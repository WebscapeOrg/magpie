import QtQuick 2.15
import QtTest 1.3
import "../../components" as Omamail

Item {
  width: 700
  height: 500

  QtObject {
    id: fakeBackend
    property bool ready: true
    property string method: ""
    property var params: null
    property var callback: null
    function call(method, params, callback) {
      fakeBackend.method = method; fakeBackend.params = params; fakeBackend.callback = callback
    }
  }
  QtObject {
    id: fakeService

    property string activeAccountId: "a@example.org"
    property var accountSummaries: []
    property var accountSignatures: [
      { id: "a@example.org", email: "a@example.org", label: "", signature: "",
        provider: "imap", senderName: "" },
      { id: "b@example.net", email: "b@example.net", label: "Work", signature: "",
        provider: "gmail", senderName: "" },
      { id: "c@example.com", email: "c@example.com", label: "", signature: "",
        provider: "outlook", senderName: "Jane Example" }
    ]
    property bool backendCanNameSender: true
    property int undoSendSeconds: 10
    property bool unifiedCalendarView: false
    property bool notifyNewMail: true
    property string contentDirection: "auto"
    property var auth: null
    property var backend: fakeBackend
    property var pickerCallback: null
    function chooseFiles(callback) { pickerCallback = callback }
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

    property string senderNamedId: ""
    property string senderNamedText: ""
    property int senderNameWrites: 0

    function setAccountSenderName(id, text) {
      senderNamedId = String(id || "")
      senderNamedText = String(text || "")
      senderNameWrites += 1
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
    calendarController: null
    textColor: Qt.rgba(0.1, 0.1, 0.1, 1)
    dimColor: Qt.rgba(0.45, 0.45, 0.45, 1)
    accentColor: Qt.rgba(0.8, 0.4, 0, 1)
    urgentColor: Qt.rgba(0.8, 0.1, 0.1, 1)
    panelFontFamily: "monospace"
  }

  TestCase {
    name: "SignatureImportLifecycle"
    when: windowShown
    function init() {
      page.y = 0
      fakeService.pickerCallback = null
      page.importing = false
      page.selectedSignatureAccountId = "a@example.org"
      fakeService.signatureId = ""
      fakeService.signatureHtml = ""
      fakeBackend.callback = null
    }
    function picked() { fakeService.pickerCallback({ok: true, paths: ["/synthetic/signature.png"]}) }
    function read() { fakeBackend.callback({ok: true, mimeType: "image/png", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"}, null) }
    function imported() { fakeBackend.callback({html: "<p>signature</p>", plain: "", images: 1, dropped: 0, problem: ""}, null) }
    function test_import_button_starts_the_owned_request() {
      var trigger = findChild(page, "settings-signature-import")
      verify(trigger)
      page.y = 20 - trigger.mapToItem(page, 0, 0).y
      waitForRendering(trigger)
      mouseClick(trigger, trigger.width / 2, trigger.height / 2)
      verify(fakeService.pickerCallback)
      compare(page.importingAccountId, "a@example.org")
      picked(); read(); imported()
      compare(fakeService.signatureId, "a@example.org")
    }
    function test_picker_completion_keeps_the_original_account() {
      page.importSignature()
      page.selectSignatureAccount("b@example.net")
      picked()
      compare(fakeBackend.method, "attachment.read")
      read()
      compare(fakeBackend.method, "message.signatureImport")
      imported()
      compare(fakeService.signatureId, "a@example.org")
      compare(page.selectedSignatureAccountId, "b@example.net")
      compare(page.importing, false)
    }
    function test_file_read_completion_keeps_the_original_account() {
      page.importSignature()
      picked()
      page.selectSignatureAccount("b@example.net")
      read()
      imported()
      compare(fakeService.signatureId, "a@example.org")
    }
    function test_repeated_import_does_not_replace_the_owner() {
      page.importSignature()
      page.selectSignatureAccount("b@example.net")
      page.importSignature()
      picked()
      read()
      imported()
      compare(fakeService.signatureId, "a@example.org")
    }
    function test_cancelled_picker_does_not_write() {
      page.importSignature()
      fakeService.pickerCallback({ok: false, error: "cancelled"})
      compare(fakeService.signatureId, "")
      compare(fakeBackend.callback, null)
      compare(page.importing, false)
    }
  }
}

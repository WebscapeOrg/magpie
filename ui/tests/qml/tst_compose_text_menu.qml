import QtQuick 2.15
import QtTest 1.3
import "../../components" as Omamail

Item {
  width: 900
  height: 600

  QtObject {
    id: mailService
    property bool sendPending: false
    property bool sending: false
    property int sendSecondsRemaining: 10
    property var lastSent: null
    property var recipientContacts: []
    property var sendAsAliases: []
    property var sendIdentities: [
      ({ email: "me@example.com", accountId: "me@example.com", label: "me" })
    ]
    property string accountEmail: "me@example.com"
    property string activeAccountId: "me@example.com"
    property var copied: []
    property var pastedInto: []
    property var clipboardCallback: null
    property bool delayClipboard: false
    function preferredSendAs(recipients) { return null }
    function switchTo(accountId) { return true }
    function refreshRecipientContacts() {}
    function send(fields) { return true }
    function copyText(text) { copied = copied.concat([String(text)]); return true }
    function clipboardAttachment(directory, callback) {
      var focused = compose.Window.activeFocusItem
      pastedInto = pastedInto.concat([focused ? String(focused.objectName) : ""])
      if (delayClipboard) clipboardCallback = callback
      else callback({ ok: false, error: "no-image" })
      return true
    }
  }

  Omamail.ComposeView {
    id: compose
    anchors.fill: parent
    service: mailService
    textColor: Qt.rgba(1, 1, 1, 1)
    backgroundColor: Qt.rgba(0.06, 0.06, 0.06, 1)
    accentColor: Qt.rgba(1, 0.5, 0, 1)
    dimColor: Qt.rgba(0.67, 0.67, 0.67, 1)
    dimmerColor: Qt.rgba(0.47, 0.47, 0.47, 1)
    popupBackgroundColor: Qt.rgba(0.13, 0.13, 0.13, 1)
    popupBorderColor: Qt.rgba(0.3, 0.3, 0.3, 1)
    panelFontFamily: "sans"
  }

  TestCase {
    name: "ComposeTextMenu"
    when: windowShown

    function menu() {
      var found = findChild(compose, "compose-text-menu")
      verify(found, "the form owns a text menu")
      return found
    }

    function init() {
      compose.begin("new", null, "", [])
      mailService.copied = []
      mailService.pastedInto = []
      mailService.clipboardCallback = null
      mailService.delayClipboard = false
      menu().close()
    }

    function cleanup() { menu().close() }

    function test_a_right_click_in_the_body_opens_an_editing_menu() {
      var body = findChild(compose, "compose-body-editor")
      verify(body)
      mouseClick(body, 20, 10, Qt.RightButton)
      wait(20)
      compare(menu().opened, true)
      compare(menu().editable, true)
      verify(menu().target === body)
    }

    function test_copy_in_the_body_goes_through_the_host() {
      var body = findChild(compose, "compose-body-editor")
      body.text = "draft words"
      body.select(0, 5)
      mouseClick(body, 20, 10, Qt.RightButton)
      wait(20)
      menu().copyRow.activated()
      compare(mailService.copied, ["draft"])
    }

    function test_paste_in_the_body_goes_the_way_ctrl_v_goes() {
      var body = findChild(compose, "compose-body-editor")
      mouseClick(body, 20, 10, Qt.RightButton)
      wait(20)
      menu().pasteRow.activated()
      wait(20)
      compare(mailService.pastedInto, ["compose-body-editor"])
    }

    function test_a_right_click_on_a_field_opens_the_menu_for_that_field() {
      var subject = findChild(compose, "compose-subject-field")
      verify(subject)
      subject.text = "a subject"
      mouseClick(subject, 20, subject.height / 2, Qt.RightButton)
      wait(20)
      compare(menu().opened, true)
      verify(menu().target === subject)
      menu().selectAllRow.activated()
      compare(subject.selectedText, "a subject")
    }

    function test_paste_lands_in_the_field_that_was_clicked() {
      var to = findChild(compose, "compose-to-field")
      verify(to)
      mouseClick(to, 20, to.height / 2, Qt.RightButton)
      wait(20)
      menu().pasteRow.activated()
      wait(20)
      compare(mailService.pastedInto, ["compose-to-field"])
    }

    function prepareClipboard() {
      var body = findChild(compose, "compose-body-editor")
      body.text = "recipient@example.test"
      body.selectAll()
      body.copy()
      body.text = ""
      return body
    }

    function pasteFromMenu(field) {
      mouseClick(field, 20, field.height / 2, Qt.RightButton)
      tryCompare(menu(), "opened", true)
      var row = menu().pasteRow
      mouseClick(row, row.width / 2, row.height / 2)
      tryCompare(menu(), "opened", false)
    }

    function test_reply_to_menu_pastes_into_reply_to() {
      var body = prepareClipboard()
      compose.replyToVisible = true
      var replyTo = findChild(compose, "compose-reply-to-field")
      waitForRendering(replyTo)
      pasteFromMenu(replyTo)
      compare(replyTo.text, "recipient@example.test")
      compare(body.text, "", "Reply-To paste must not alter the message body")
    }

    function test_delayed_text_paste_keeps_its_original_field() {
      var body = prepareClipboard()
      var subject = findChild(compose, "compose-subject-field")
      mailService.delayClipboard = true
      pasteFromMenu(subject)
      verify(mailService.clipboardCallback !== null)
      mouseClick(body, 20, 10)
      verify(body.activeFocus)
      mailService.clipboardCallback({ok: false, error: "no-image"})
      compare(subject.text, "recipient@example.test")
      compare(body.text, "", "A later focus change must not redirect pending paste")
    }

    function test_delayed_text_paste_cannot_enter_a_new_draft() {
      var body = prepareClipboard()
      var subject = findChild(compose, "compose-subject-field")
      mailService.delayClipboard = true
      pasteFromMenu(subject)
      verify(mailService.clipboardCallback !== null)
      compose.begin("new", null, "", [])
      mailService.clipboardCallback({ok: false, error: "no-image"})
      compare(subject.text, "", "The previous draft's paste must remain discarded")
      compare(body.text, "")
    }
  }
}

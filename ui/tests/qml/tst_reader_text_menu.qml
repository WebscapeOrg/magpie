import QtQuick 2.15
import QtTest 1.3
import qs.Commons
import "../../components" as Omamail
import "../../message/Html.js" as Html

Item {
  width: 900
  height: 600

  readonly property string senderHtml: '<p>Person 1 moved 4 cards.</p>'
    + '<p><a href="https://example.com/board">Open the board</a></p>'

  readonly property var rendered: Html.sanitize(senderHtml, ({ withReader: true }))

  QtObject {
    id: mailService

    property var copied: []
    property var opened: []

    property string selectedId: "message-9"
    property var selectedMessage: ({
      id: "message-9",
      subject: "Activity on Sprint board",
      from: ({ display: "Boards", email: "boards@example.com" }),
      to: [({ display: "Reader", email: "reader@example.com" })],
      fullTime: "24 August 2026",
      starred: false
    })
    property bool detailLoading: false
    property bool detailPainted: true
    property bool selectedHasHtml: rendered.html !== ""
    property var selectedDocument: rendered.document
    property var selectedReaderDocument: rendered.reader.document
    property bool selectedReaderTooHeavy: rendered.reader.tooHeavy
    property bool selectedReaderEmpty: rendered.reader.empty
    property int selectedRemoteImages: rendered.remoteImages
    property bool remoteImagesAllowed: false
    property bool selectedTooHeavy: rendered.tooHeavy
    property string unsubscribeLabel: ""
    property string unsubscribeDetail: ""
    property bool unsubscribing: false
    property var selectedBody: ({ text: "Person 1 moved 4 cards.", source: "html" })
    property var selectedImages: []
    property var selectedInvite: null
    property string selectedResponse: ""
    property bool canRespondToInvite: false
    property bool rsvpSending: false
    property bool canArchive: true
    property bool canOpenOnWeb: false
    property var selectedAttachments: []

    function getMessage() {}
    function showRemoteImages() {}
    function copyText(text) { copied = copied.concat([String(text)]); return true }
    function openExternal(url) { opened = opened.concat([String(url)]); return true }
  }

  Omamail.MessageReader {
    id: reader
    width: 900
    height: 600
    service: mailService
    textColor: Qt.rgba(1, 1, 1, 1)
    backgroundColor: Qt.rgba(0.06, 0.06, 0.06, 1)
    accentColor: Qt.rgba(1, 0.5, 0, 1)
    linkColor: Qt.rgba(0.3, 0.7, 1, 1)
    dimColor: Qt.rgba(0.67, 0.67, 0.67, 1)
    popupBackgroundColor: Qt.rgba(0.13, 0.13, 0.13, 1)
    popupBorderColor: Qt.rgba(0.47, 0.47, 0.47, 1)
    leadingBoundaryOverlap: 0
    dimmerColor: Qt.rgba(0.47, 0.47, 0.47, 1)
    panelFontFamily: "monospace"
    bodyMode: "reader"
    onBodyModeRequested: function(mode) { reader.bodyMode = mode }
  }

  TestCase {
    name: "ReaderTextMenu"
    when: windowShown

    function findByType(item, typeName) {
      if (!item) return null
      if (item.toString().indexOf(typeName) === 0) return item
      var children = item.children || []
      for (var index = 0; index < children.length; index++) {
        var match = findByType(children[index], typeName)
        if (match) return match
      }
      return null
    }

    function bodyEditor() {
      var editor = findByType(reader, "QQuickTextEdit")
      verify(editor, "the reader draws its message in a TextEdit")
      return editor
    }

    function menu() {
      var found = findChild(reader, "reader-text-menu")
      verify(found, "the reader owns a text menu")
      return found
    }

    function pointOf(editor, needle) {
      var plain = editor.getText(0, editor.length)
      var characterIndex = plain.indexOf(needle)
      verify(characterIndex >= 0, "the body holds " + needle)
      var rectangle = editor.positionToRectangle(characterIndex)
      return { x: rectangle.x + 3, y: rectangle.y + rectangle.height / 2 }
    }

    function init() {
      menu().close()
      bodyEditor().deselect()
      mailService.copied = []
      mailService.opened = []
    }

    function cleanup() { menu().close() }

    function test_a_right_click_on_the_body_opens_the_menu() {
      var editor = bodyEditor()
      var point = pointOf(editor, "Person 1")
      mouseClick(editor, point.x, point.y, Qt.RightButton)
      wait(20)
      compare(menu().opened, true)
      compare(menu().editable, false)
      compare(menu().link, "")
    }

    function test_a_right_click_keeps_the_selection_and_copy_copies_it() {
      var editor = bodyEditor()
      var start = editor.getText(0, editor.length).indexOf("moved")
      editor.select(start, start + 5)
      var point = pointOf(editor, "Person 1")
      mouseClick(editor, point.x, point.y, Qt.RightButton)
      wait(20)
      compare(editor.selectedText, "moved")
      compare(menu().copyRow.enabled, true)
      menu().copyRow.activated()
      compare(mailService.copied, ["moved"])
    }

    function test_a_right_click_on_a_link_offers_it() {
      var editor = bodyEditor()
      var point = pointOf(editor, "Open the board")
      mouseClick(editor, point.x, point.y, Qt.RightButton)
      wait(20)
      compare(menu().opened, true)
      compare(menu().link, "https://example.com/board")
      menu().copyLinkRow.activated()
      compare(mailService.copied, ["https://example.com/board"])
    }

    function test_open_link_opens_it_outside() {
      var editor = bodyEditor()
      var point = pointOf(editor, "Open the board")
      mouseClick(editor, point.x, point.y, Qt.RightButton)
      wait(20)
      menu().openLinkRow.activated()
      compare(mailService.opened, ["https://example.com/board"])
    }
  }
}

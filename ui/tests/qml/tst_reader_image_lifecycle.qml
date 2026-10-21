import "../../settings"
import QtQuick 2.15
import QtTest 1.3
import qs.Commons
import "../../components" as Omamail
import "../../message/Html.js" as Html

// Three ways of reading one message, and the two things that must stay true
// while moving between them: nothing is asked of the network, and the message
// on screen is still the message that was open.
//
// The reading column is here too, because how wide it is and where it sits are
// decided against a font Qt measures — which is the half of that decision no
// node test can make.
Item {
  width: MailStyle.space(900)
  height: 600

  readonly property string senderHtml: '<table width="600" align="center" bgcolor="#ffeedd"'
    + ' background="https://static.example.net/tile.png" class="card"><tr>'
    + '<td style="padding:24px;font-size:28px;font-family:Graphik;color:#123456">'
    + 'Activity on Sprint board</td>'
    + '</tr><tr><td style="padding:0 24px">Person 1 moved 4 cards. '
    + '<a href="https://example.com/board">Open the board</a></td></tr></table>'

  readonly property var rendered: Html.sanitize(senderHtml, ({ withReader: true }))

  QtObject {
    id: mailService

    // Every trip to the network a body could cause. Reading mode is built
    // beside the other two off one parse, so choosing between them must move
    // none of these.
    property var reading: ({accountId: "account-a"})
    property var callbacks: []
    function fetchDisplayImage(source, callback) { callbacks = callbacks.concat([{source: source, done: callback}]) }
    property int fetches: 0
    property int renders: 0

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
    property var selectedBody: ({ text: "[image 1]", source: "html" })
    property var selectedImages: ["https://images.example.com/first.png"]
    property var selectedInvite: null
    property string selectedResponse: ""
    property bool canRespondToInvite: false
    property bool rsvpSending: false
    property bool canArchive: true
    property bool canOpenOnWeb: false
    property var selectedAttachments: []

    function getMessage() { fetches++ }
    function showRemoteImages() { renders++ }
  }

  Omamail.MessageReader {
    id: reader
    // Sized rather than anchored: the panel's width is what these tests move.
    width: MailStyle.space(900)
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
    bodyMode: "plain"
    onBodyModeRequested: function(mode) { reader.bodyMode = mode }
  }

  TestCase {
    name: "ReaderImageLifecycle"
    when: windowShown

    readonly property string raster: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    function childOfType(item, type) {
      if (item.toString().indexOf(type) === 0) return item
      var children = item.children || []
      for (var childIndex = 0; childIndex < children.length; childIndex++) {
        var found = childOfType(children[childIndex], type)
        if (found) return found
      }
      return null
    }

    function popover() { return childOfType(reader, "ImagePopover") }

    function init() {
      popover().close()
      wait(1)
      mailService.selectedId = "message-9"
      mailService.reading = ({accountId: "account-a"})
      mailService.callbacks = []
      reader.visible = true
    }

    function cleanup() { popover().close(); wait(1) }

    function test_old_account_cannot_open_image() {
      reader.openImageMarker("https://images.example.com/first.png")
      mailService.reading = ({accountId: "account-b"})
      mailService.callbacks[0].done(raster)
      compare(popover().requested, "")
      compare(popover().source, "")
    }

    function test_old_message_cannot_open_image() {
      reader.openImageMarker("https://images.example.com/first.png")
      mailService.selectedId = "message-10"
      mailService.callbacks[0].done(raster)
      compare(popover().requested, "")
      compare(popover().source, "")
    }

    function test_latest_image_request_wins() {
      reader.openImageMarker("https://images.example.com/first.png")
      reader.openImageMarker("https://images.example.com/second.png")
      mailService.callbacks[1].done(raster)
      mailService.callbacks[0].done(raster)
      compare(popover().requested, "https://images.example.com/second.png")
    }

    function test_account_change_closes_prepared_image() {
      reader.openImageMarker(raster)
      verify(popover().source !== "")
      mailService.reading = ({accountId: "account-b"})
      tryCompare(popover(), "source", "")
    }

    function test_hidden_reader_cannot_open_image() {
      reader.openImageMarker("https://images.example.com/first.png")
      reader.visible = false
      mailService.callbacks[0].done(raster)
      compare(popover().requested, "")
    }

    function test_click_image_marker_opens_prepared_bytes() {
      var body = childOfType(reader, "QQuickTextEdit")
      verify(body)
      var position = null
      for (var y = 1; y < body.height && !position; y += 3) {
        for (var x = 1; x < body.width; x += 3) {
          if (body.linkAt(x, y) === "omarchy-image:1") { position = {x: x, y: y}; break }
        }
      }
      verify(position, "The plain message contains a clickable image marker")
      var character = body.positionToRectangle(4)
      mouseClick(body, character.x + 2, character.y + character.height / 2)
      compare(mailService.callbacks.length, 1)
      compare(popover().source, "")
      mailService.callbacks[0].done(raster)
      compare(popover().requested, "https://images.example.com/first.png")
      compare(popover().source, raster)
    }
  }
}

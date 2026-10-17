import "../../settings"
import QtQuick 2.15
import QtTest 1.3
import "../../components" as Omamail

Item {
  width: 900
  height: 600

  QtObject {
    id: mailService

    property string openedMessageId: ""
    property var openedAttachment: null
    property string starredId: ""
    property string browsedId: ""
    // What the service answers to. It is the summary's own id in a single
    // mailbox and the mailbox plus that id in a list made of several, and the
    // reader has to hand back this one rather than the one on the summary.
    property string selectedId: "message-4"
    property var selectedMessage: ({
      id: "message-4",
      subject: "Forwarded report",
      from: ({ display: "Sender", email: "sender@example.com" }),
      to: [({ display: "Reader", email: "reader@example.com" })],
      fullTime: "24 August 2026",
      starred: false
    })
    property bool listLoaded: true
    property var messages: []
    property string searchQuery: ""
    property bool canMoveToLabel: false
    property bool detailLoading: false
    property bool detailPainted: true
    property bool selectedHasHtml: false
    property var selectedDocument: null
    property int selectedRemoteImages: 0
    property bool remoteImagesAllowed: false
    property bool selectedTooHeavy: false
    property string unsubscribeLabel: ""
    property string unsubscribeDetail: ""
    property bool unsubscribing: false
    property var selectedBody: ({ text: "Forwarded message", source: "plain" })
    property var selectedImages: []
    property var selectedInvite: null
    property string selectedResponse: ""
    property bool canRespondToInvite: false
    property bool rsvpSending: false
    property bool canArchive: true
    property bool canOpenOnWeb: true
    property var selectedAttachments: [({
      filename: "Quarterly report.pdf",
      mimeType: "application/pdf",
      size: 1536,
      attachmentId: "att-7"
    })]

    property var previewCalls: []
    property bool deferPreviews: false
    property int cancelledPreviews: 0
    property int routedKeys: 0
    function previewAttachment(messageId, attachment, callback) {
      var call = {messageId:messageId, attachment:attachment, done:callback, cancelled:false}
      previewCalls = previewCalls.concat([call])
      if (!deferPreviews) callback("")
      return {cancel:function(){call.cancelled=true;mailService.cancelledPreviews++}}
    }
    property int saveCalls: 0
    property string savedMessageId: ""
    property var savedAttachment: null

    // Keyed by mailbox and attachment on the real service, because two
    // mailboxes can be saving parts whose ids collide. Empty here, so a reader
    // that looks up a bare attachment id finds nothing — which is what it did.
    property var savingAttachmentIds: ({})
    property string savingFor: ""

    function openAttachment(messageId, attachment) {
      openedMessageId = messageId
      openedAttachment = attachment
    }

    function saveAttachment(messageId, attachment) {
      saveCalls++
      savedMessageId = messageId
      savedAttachment = attachment
    }

    function attachmentIsSaving(messageId, attachmentId) {
      return savingFor !== "" && String(messageId) === savingFor
        && String(attachmentId) === "att-7"
    }

    function toggleStar(id) { starredId = String(id) }
    function openInBrowser(id) { browsedId = String(id) }
  }

  Omamail.MessageReader {
    id: reader
    width: 380
    height: 360
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
  }

  Omamail.KeyRouter { context: "reader"; onTriggered: mailService.routedKeys++ }

  TestCase {
    name: "AttachmentFooter"
    when: windowShown

    function named(item, name) {
      if (item.objectName === name) return item
      var children = item.children || []
      for (var i = 0; i < children.length; i++) {
        var found = named(children[i], name)
        if (found) return found
      }
      return null
    }

    function attachments(count) {
      var result = []
      for (var i = 0; i < count; i++)
        result.push({filename: "Report " + (i + 1) + ".pdf", mimeType: "application/pdf",
          size: 1536, attachmentId: "att-" + i})
      return result
    }

    function show(count) {
      mailService.selectedAttachments = attachments(count)
      waitForRendering(reader)
    }

    function cards() {
      var list = named(reader, "attachment-scroller")
      var children = list.contentItem.children[0].children
      var result = []
      for (var i=0;i<children.length;i++) if(children[i].attachment) result.push(children[i])
      return result
    }

    function init() {
      reader.width = MailStyle.space(380)
      reader.height = MailStyle.space(360)
      mailService.selectedAttachments = []
      mailService.selectedId = "message-4"
      mailService.savingFor = ""
      mailService.saveCalls = 0
      mailService.openedMessageId = ""
      mailService.savedMessageId = ""
      mailService.previewCalls = []
      mailService.deferPreviews = false
      mailService.cancelledPreviews = 0
      mailService.routedKeys = 0
      wait(0)
    }

    function test_files_are_individually_visible_without_a_disclosure() {
      show(0)
      var body = named(reader, "messageBodyScroller")
      var emptyHeight = body.height
      var list = named(reader, "attachment-scroller")
      compare(list.visible, false)
      show(40)
      compare(list.visible, true)
      compare(cards().length, 40)
      compare(named(reader,"attachment-toggle"), null)
      verify(list.contentWidth > list.width)
      verify(list.height > 0 && list.height <= MailStyle.space(112))
      verify(body.height >= 100, "many attachments leave readable body space: " + body.height)
      show(1)
      compare(cards()[0].filename, "Report 1.pdf")
      show(0)
      tryCompare(body, "height", emptyHeight)
    }

    function test_short_readers_keep_body_and_all_actions() {
      show(40)
      reader.height = MailStyle.space(280)
      reader.width = MailStyle.space(300)
      var body = named(reader, "messageBodyScroller")
      var list = named(reader, "attachment-scroller")
      tryVerify(function() {return body.height >= 60})
      verify(list.height > 0 && list.height < MailStyle.space(112))
      var card = cards()[0]
      var save = named(card,"attachment-save-button")
      var point = save.mapToItem(list,0,0)
      verify(point.y >= 0 && point.y+save.height <= list.height+1,
        "the save target stays inside even a short shelf")
    }

    function test_scroll_to_last_file_and_route_both_actions() {
      show(40)
      mailService.selectedId = "mailbox-b message-4"
      var list = named(reader, "attachment-scroller")
      waitForRendering(reader)
      mouseWheel(list, list.width/2, list.height/2, 0, -120000)
      tryVerify(function(){return list.atXEnd})
      var last = cards()[39]
      var save = named(last,"attachment-save-button")
      var point = save.mapToItem(list,0,0)
      verify(point.y >= 0 && point.y+save.height <= list.height+1)
      verify(point.x >= 0 && point.x+save.width <= list.width+1)
      mouseClick(last, last.width/2, 5)
      compare(mailService.openedMessageId,"mailbox-b message-4")
      compare(mailService.openedAttachment.attachmentId,"att-39")
      mouseClick(save,save.width/2,save.height/2)
      compare(mailService.savedMessageId,"mailbox-b message-4")
      compare(mailService.savedAttachment.attachmentId,"att-39")
    }

    function test_keyboard_focus_reveals_each_file_and_keeps_open_and_save_distinct() {
      show(40)
      var last = cards()[39]
      last.forceActiveFocus()
      var list = named(reader,"attachment-scroller")
      tryVerify(function(){return list.atXEnd})
      keyClick(Qt.Key_Return)
      compare(mailService.openedAttachment.attachmentId,"att-39")
      compare(mailService.saveCalls,0)
      var save = named(last,"attachment-save-button")
      save.forceActiveFocus()
      keyClick(Qt.Key_Space)
      compare(mailService.saveCalls,1)
      compare(mailService.savedAttachment.attachmentId,"att-39")
      compare(mailService.routedKeys,0,"Enter and Space reach attachment controls before mailbox shortcuts")
    }

    function test_switching_messages_cancels_previews_and_discards_late_results() {
      mailService.deferPreviews = true
      show(40)
      tryVerify(function(){return mailService.previewCalls.length === 1})
      var old = mailService.previewCalls[0]
      var list = named(reader,"attachment-scroller")
      list.contentX = list.contentWidth-list.width
      mailService.selectedId = "message-5"
      show(2)
      tryCompare(list,"contentX",0)
      verify(mailService.cancelledPreviews>0)
      old.done("http://127.0.0.1/forbidden")
      compare(Object.keys(reader.attachmentPreviews).length,0)
      tryVerify(function(){return mailService.previewCalls.length === 2})
      compare(mailService.previewCalls[1].messageId,"message-5")
    }

    function test_only_visible_supported_files_are_previewed_with_a_budget() {
      show(40)
      tryVerify(function(){return mailService.previewCalls.length>0})
      wait(100)
      verify(mailService.previewCalls.length<5,"the entire shelf is not downloaded at once")
      mailService.previewCalls=[]
      mailService.selectedAttachments=[{filename:"huge.pdf",mimeType:"application/pdf",size:9000000,attachmentId:"large"},
        {filename:"unknown.bin",mimeType:"application/octet-stream",size:20,attachmentId:"unknown"}]
      wait(100)
      compare(mailService.previewCalls.length,0)
      compare(cards().length,2,"unpreviewable files remain individually available")
    }

    function test_busy_state_and_plain_text_filenames() {
      mailService.selectedAttachments=[{filename:'<img src="https://example.invalid/tracker">',attachmentId:"att-7",mimeType:"application/pdf",size:128}]
      mailService.selectedId="mailbox-b message-4"
      mailService.savingFor="mailbox-b message-4"
      waitForRendering(reader)
      var card=cards()[0]
      var save=named(card,"attachment-save-button")
      compare(save.busy,true)
      mouseClick(save,save.width/2,save.height/2)
      compare(mailService.saveCalls,0)
      mailService.savingFor=""
      compare(save.busy,false)
      mouseClick(save,save.width/2,save.height/2)
      compare(mailService.saveCalls,1)
      compare(named(card,"attachment-filename").textFormat,Text.PlainText)
      compare(String(named(card,"attachment-thumbnail").source),"")
    }
  }
}

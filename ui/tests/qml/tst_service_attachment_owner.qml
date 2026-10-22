import QtQuick
import QtTest
import "../.." as Omamail
import "../../account/Unified.js" as Unified
import "BackendFixture.js" as BackendFixture

Item {
  id: fixture
  property var service: null
  property var transport: null
  readonly property string sourceAccount: "source@example.test"
  readonly property string otherAccount: "other@example.test"
  readonly property string sourceMessage: "42:INBOX"
  readonly property var attachments: [{attachmentId:"part-1", filename:"synthetic.txt", mimeType:"text/plain"}]
  Component {
    id: serviceFactory
    Omamail.Service { manifest: ({id:"omamail"}) }
  }
  TestCase {
    name: "ServiceAttachmentOwner"
    function init() {
      fixture.service = createTemporaryObject(serviceFactory, fixture)
      verify(fixture.service)
      fixture.service.applyAccounts(JSON.stringify({version:1,activeId:fixture.otherAccount,accounts:[
        {id:fixture.sourceAccount,email:fixture.sourceAccount,provider:"gmail",clientId:""},
        {id:fixture.otherAccount,email:fixture.otherAccount,provider:"gmail",clientId:""}
      ]}))
      tryCompare(fixture.service,"accountCount",2)
      compare(fixture.service.activeAccountId,fixture.otherAccount)
      fixture.transport = BackendFixture.markReady(fixture.service,8)
      fixture.transport.answers["attachment.retain"] = function() { return undefined }
    }
    function retained() {
      return fixture.transport.requests.filter(function(request) { return request.method === "attachment.retain" })
    }
    function test_explicit_owner_survives_active_account_change() {
      fixture.service.loadAttachments(fixture.sourceMessage,fixture.attachments,function(){},"draft-owner",fixture.sourceAccount)
      compare(retained().length,1)
      compare(retained()[0].params.accountId,fixture.sourceAccount)
      compare(retained()[0].params.messageId,fixture.sourceMessage)
    }
    function test_composed_id_is_decoded_after_leaving_unified_view() {
      compare(fixture.service.unified,false)
      fixture.service.loadAttachments(Unified.unifiedId(fixture.sourceAccount,fixture.sourceMessage),fixture.attachments,function(){},"draft-owner",fixture.sourceAccount)
      compare(retained().length,1)
      compare(retained()[0].params.accountId,fixture.sourceAccount)
      compare(retained()[0].params.messageId,fixture.sourceMessage)
    }
    function test_conflicting_composed_owner_never_dispatches() {
      var error = ""
      fixture.service.loadAttachments(Unified.unifiedId(fixture.otherAccount,fixture.sourceMessage),fixture.attachments,function(values,reason){error=reason},"draft-owner",fixture.sourceAccount)
      compare(retained().length,0)
      verify(error.length>0)
    }
    function test_missing_owner_never_falls_back_to_current_account() {
      var error = ""
      fixture.service.loadAttachments(fixture.sourceMessage,fixture.attachments,function(values,reason){error=reason},"draft-owner","removed@example.test")
      compare(retained().length,0)
      verify(error.length>0)
    }
    function test_legacy_call_still_uses_current_account() {
      fixture.service.loadAttachments(fixture.sourceMessage,fixture.attachments,function(){},"draft-owner")
      compare(retained().length,1)
      compare(retained()[0].params.accountId,fixture.otherAccount)
    }
  }
}

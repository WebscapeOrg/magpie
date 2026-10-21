import QtQuick
import "Model.js" as Model
import "../message/AttachmentPreview.js" as AttachmentPreview

Item {
  id: root
  required property var account
  readonly property var backend: account.backend

  function summaryProgress(ids, base, serial) {
    var arrived = Object.create(null)
    return function(payloads) {
      if (serial !== root.account.listSerial) return
      for (var i=0;i<payloads.length;i++) {
        var summary=payloads[i].nativeSummary
        if (summary && summary.id) arrived[String(summary.id)]=summary
      }
      var partial=[]
      for (var j=0;j<ids.length;j++) if (arrived[String(ids[j])]) partial.push(arrived[String(ids[j])])
      if (partial.length) root.account.messages=base.concat(partial)
    }
  }

  function warmNeighbours(messageId) {
    if (!backend || !backend.ready || Number(backend.apiVersion)<8) return
    var at = Model.indexById(account.messages,messageId)
    if (at<0) return
    var ids=[]
    for (var offset=-2;offset<=2;offset++) {
      if (offset===0 || at+offset<0 || at+offset>=account.messages.length) continue
      ids.push(account.messages[at+offset].id)
    }
    backend.call("reader.prefetch",{accountId:account.accountId,ids:ids,now:Date.now(),
      options:{allowRemoteImages:false,withReader:true}},function(){})
  }

  function previewAttachment(messageId, attachment, callback) {
    var done = typeof callback === "function" ? callback : function() {}
    var id = String(messageId || "")
    var source = null
    for (var i = 0; i < account.selectedAttachments.length; i++) {
      if (attachment && account.selectedAttachments[i].attachmentId === attachment.attachmentId)
        source = account.selectedAttachments[i]
    }
    if (!account.ready || id !== account.selectedId || !source || !AttachmentPreview.supported(source)
        || !backend || !backend.ready || Number(backend.apiVersion) < 8) { done(""); return null }
    var serial = account.detailSerial
    var identity = account.accountId
    var cancelled = false
    var request=backend.call("attachment.preview",{accountId:identity,messageId:id,
      attachmentId:String(source.attachmentId),filename:String(source.filename || "attachment"),
      mimeType:String(source.mimeType || "").toLowerCase()},function(result,error) {
        if (cancelled || !root || identity !== root.account.accountId
            || id !== root.account.selectedId || serial !== root.account.detailSerial) return
        done(error || !result ? "" : String(result.data || ""))
    })
    return {cancel:function(){cancelled=true; if(request && typeof request.cancel === "function") request.cancel()}}
  }

  function downloadAttachment(messageId, source, open) {
    var key = String(source.attachmentId || "")
    if (account.savingAttachmentIds[key]) return
    var identity = account.accountId
    account.markSavingAttachment(key,true)
    account.note((open ? "Opening " : "Saving ") + String(source.filename || "attachment"))
    backend.call("attachment.download",{accountId:identity,messageId:String(messageId),attachmentId:key,
      filename:String(source.filename || "attachment"),mimeType:String(source.mimeType || "application/octet-stream"),open:open},function(result,error) {
        if (identity !== root.account.accountId) return
        root.account.markSavingAttachment(key,false)
        if (error || !result || !result.path) {root.account.fail("That attachment could not be " + (open ? "opened" : "saved"));return}
        if (open && root.account.platform && typeof root.account.platform.openExternal === "function")
          root.account.platform.openExternal(String(result.path))
        root.account.note(open ? "Opening " + String(source.filename || "attachment") : "Saved " + String(result.path))
    })
  }
}

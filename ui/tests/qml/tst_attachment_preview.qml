import QtQuick
import QtTest
import "../../account" as Accounts

Item {
  QtObject {
    id: backend
    property bool ready: true
    property int apiVersion: 8
    property var requests: []
    function call(method,params,done) {
      var request={method:method,params:params,done:done,cancelled:false}
      if(method === "attachment.preview") requests=requests.concat([request])
      return {cancel:function(){request.cancelled=true}}
    }
  }
  Component {
    id: clientFactory
    QtObject {
      property var requests: []
      function getAttachment(messageId,attachmentId,done) {
        var request={messageId:messageId,attachmentId:attachmentId,done:done,aborted:false}
        requests=requests.concat([request]);return request
      }
      function abortRequest(handle){if(handle)handle.aborted=true}
      function getProfile(done){}
      function getLabels(done){}
      function getSendAs(done){}
      function getInboxUnread(done){}
      function listMessages(query,limit,token,done){done({ids:[],estimate:0,nextPageToken:""},"");return {aborted:false}}
    }
  }
  Accounts.MailAccount {
    id: account
    pluginDir:"/synthetic/plugin"
    backend:backend
    configuredEmail:"ada@example.org"
    clientOverride:clientFactory
  }
  TestCase {
    name:"AttachmentPreview"
    readonly property var file:({attachmentId:"same-part",filename:"report.pdf",mimeType:"application/pdf",size:1024})
    function init(){
      account.accountId="ada@example.org"
      account.auth.toolsChecked=true;account.auth.missingTools=[]
      account.auth.credentials = {clientId: "123-example.apps.googleusercontent.com", clientSecret: "synthetic-secret"}
      account.auth.loggedIn = true
      backend.apiVersion=8
      account.selectedId="one";account.selectedAttachments=[file]
      compare(account.ready,true)
      account.api.requests=[];backend.requests=[]
    }
    function test_old_apis_unknown_parts_and_other_messages_cause_no_fetch(){
      backend.apiVersion=7
      account.previewAttachment("one",file,function(data){compare(data,"")})
      backend.apiVersion=8
      account.previewAttachment("two",file,function(data){compare(data,"")})
      account.previewAttachment("one",{attachmentId:"other"},function(data){compare(data,"")})
      account.selectedAttachments=[{attachmentId:"same-part",filename:"large.pdf",mimeType:"application/pdf",size:9000000}]
      account.previewAttachment("one",file,function(data){compare(data,"")})
      compare(account.api.requests.length,0)
      compare(backend.requests.length,0)
    }
    function test_previews_use_listed_metadata_and_return_prepared_bytes(){
      var result=""
      account.previewAttachment("one",{attachmentId:"same-part",mimeType:"text/html"},function(data){result=data})
      compare(account.api.requests.length,0)
      compare(backend.requests.length,1)
      compare(backend.requests[0].params.accountId,"ada@example.org")
      compare(backend.requests[0].params.messageId,"one")
      compare(backend.requests[0].params.attachmentId,"same-part")
      compare(backend.requests[0].params.filename,"report.pdf")
      compare(backend.requests[0].params.mimeType,"application/pdf")
      backend.requests[0].done({data:"prepared-raster"},null)
      compare(result,"prepared-raster")
    }
    function test_message_and_account_switches_discard_late_bytes(){
      var result="pending"
      account.previewAttachment("one",file,function(data){result=data})
      account.selectedId="two"
      backend.requests[0].done({data:"stale-raster"},null)
      compare(result,"pending")
      account.selectedId="one"
      account.previewAttachment("one",file,function(data){result=data})
      compare(backend.requests.length,2)
      account.accountId="bob@example.net"
      backend.requests[1].done({data:"foreign-raster"},null)
      compare(result,"pending")
      compare(account.api.requests.length,0)
    }
    function test_cancel_withdraws_request_and_ignores_late_preview(){
      var called=false
      var handle=account.previewAttachment("one",file,function(){called=true})
      handle.cancel()
      compare(backend.requests[0].cancelled,true)
      backend.requests[0].done({data:"cancelled-raster"},null)
      compare(called,false)
      compare(backend.requests.length,1)
      compare(account.api.requests.length,0)
    }
  }
}

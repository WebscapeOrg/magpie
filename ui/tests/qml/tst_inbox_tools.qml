import QtQuick
import QtTest
import "../../inbox" as Inbox
Item {
  width: 400; height: 300
  QtObject { id: first; property string accountId: "one@example.org"; property string providerId: "gmail" }
  QtObject { id: second; property string accountId: "two@example.org"; property string providerId: "gmail" }
  QtObject {
    id: backend
    property bool ready: false
    property int apiVersion: 7
    property var calls: []
    function call(method,params,done) { calls=calls.concat([{method:method,params:params,done:done}]) }
  }
  QtObject {
    id: service
    property var backend: backend
    property bool windowOpen: true
    property var accountSummaries: [{id:"one@example.org"},{id:"two@example.org"}]
    property var messages: [{id:"one-message",sourceId:"shared-id",from:{email:"alex@example.com"}},{id:"two-message",sourceId:"shared-id",from:{email:"alex@example.com"}}]
    function hostForId(id) { return String(id).indexOf("two-")===0 ? second : first }
  }
  Inbox.InboxTools { id: tools; service: service; visibleRows: service.messages }
  TestCase {
    name: "InboxTools"
    when: windowShown
    function init() { backend.ready=false;backend.apiVersion=7;backend.calls=[];tools.avatarRefreshId="";tools.avatarEpoch++;tools.paused=false;tools.overviews=({});tools.avatars=({});tools.avatarPending=({});tools.snapshotsPending=({});tools.requesting=false;service.windowOpen=true;tools.visibleRows=service.messages }
    function cleanup() { backend.ready=false }
    function test_admission_failure_explains_each_affected_row_without_leaking_error() {
      backend.apiVersion=8;backend.ready=true
      var job=backend.calls.filter(function(request){return request.method==="inbox.overviews"})[0]
      verify(job)
      job.done(null,{message:"secret credential"})
      var overview=tools.overviewFor(service.messages[0])
      compare(overview.state,"failed")
      compare(overview.reason,"AI request could not start; retry from Menu")
      verify(JSON.stringify(overview).indexOf("secret")<0)
    }
    function test_fixed_api_gate_prevents_new_requests_on_old_backend() {
      backend.ready=true;tools.refresh()
      compare(tools.available,false)
      compare(backend.calls.length,0)
    }
    function test_hidden_window_starts_no_overviews_or_avatar_fetches() {
      service.windowOpen=false
      backend.apiVersion=8;backend.ready=true
      tools.refresh()
      verify(!backend.calls.some(function(request){return request.method==="inbox.overviews" || request.method==="inbox.avatar"}))
    }
    function test_only_visible_rows_request_overviews_and_avatars() {
      tools.visibleRows=[service.messages[0]]
      backend.apiVersion=8;backend.ready=true
      var jobs=backend.calls.filter(function(request){return request.method==="inbox.overviews" || request.method==="inbox.avatar"})
      compare(jobs.length,2)
      for (var requestIndex=0;requestIndex<jobs.length;requestIndex++) compare(jobs[requestIndex].params.accountId,first.accountId)
    }
    function test_pause_keeps_avatars_available_and_stops_new_overview_admission() {
      tools.paused=true
      backend.apiVersion=8;backend.ready=true
      tools.refresh()
      verify(!backend.calls.some(function(request){return request.method==="inbox.overviews"}))
      verify(backend.calls.some(function(request){return request.method==="inbox.avatar"}))
      tools.setPaused(false)
      verify(backend.calls.some(function(request){return request.method==="inbox.overviews"}))
    }
    function test_refresh_images_ignores_stale_callbacks_and_reissues_each_account() {
      tools.paused=true;backend.apiVersion=8;backend.ready=true
      var old=backend.calls.filter(function(request){return request.method==="inbox.avatar"})[0]
      verify(old)
      tools.refreshAvatars()
      var calls=backend.calls.filter(function(request){return request.method==="inbox.avatar" && request.params.refreshId!==""})
      compare(calls.length,2)
      verify(/^[A-Za-z0-9-]+$/.test(calls[0].params.refreshId))
      old.done({data:"stale"},null)
      compare(tools.avatarFor(service.messages[0]),"")
      calls[0].done({data:"current"},null)
      compare(tools.avatarFor(service.messages[0]),"current")
      compare(tools.avatarFor(service.messages[1]),"")
    }
    function test_overviews_with_shared_message_ids_keep_account_ownership() {
      backend.apiVersion=8;backend.ready=true
      tryVerify(function() { return backend.calls.length>0 })
      var snapshot=backend.calls.filter(function(request){return request.method==="inbox.snapshot" && request.params.accountId==="one@example.org"})[0]
      verify(snapshot)
      snapshot.done({overviews:{"shared-id":{text:"First account only",state:"ready"}},snoozes:[]},null)
      compare(tools.overviewFor(service.messages[0]).text,"First account only")
      compare(tools.overviewFor(service.messages[1]).text,undefined)
      var jobs=backend.calls.filter(function(request){return request.method==="inbox.overviews"})
      verify(jobs.length>0)
      compare(jobs[0].params.accountId,"one@example.org")
      compare(jobs[0].params.ids.length,1)
      compare(jobs[0].params.ids[0],"shared-id")
    }
  }
}

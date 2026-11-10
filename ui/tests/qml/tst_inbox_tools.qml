import QtQuick
import QtTest
import "../../inbox" as Inbox
Item {
  width: 400; height: 300
  QtObject { id: first; property string accountId: "one@example.org"; property string providerId: "gmail"; property var delivered: []; function deliverNotification(rows) { delivered = delivered.concat(rows) } }
  QtObject { id: second; property string accountId: "two@example.org"; property string providerId: "gmail"; property var delivered: []; function deliverNotification(rows) { delivered = delivered.concat(rows) } }
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
    property bool alwaysShowImages: false
    property bool notifyNewMail: true
    function findAccount(account) { return account === first.accountId ? first : account === second.accountId ? second : null }
    property var accountSummaries: [{id:"one@example.org"},{id:"two@example.org"}]
    property bool curatedInbox: false
    property var rawMessages: messages
    property var messages: [{id:"one-message",sourceId:"shared-id",from:{email:"alex@example.com"}},{id:"two-message",sourceId:"shared-id",from:{email:"alex@example.com"}}]
    function hostForId(id) { return String(id).indexOf("two-")===0 ? second : first }
  }
  Inbox.InboxTools { id: tools; service: service; visibleRows: service.messages }
  TestCase {
    name: "InboxTools"
    when: windowShown
    function init() { backend.ready=false;backend.apiVersion=7;backend.calls=[];tools.avatarRefreshId="";tools.avatarEpoch++;tools.paused=false;tools.selecting=false;tools.writingIds=({});tools.descriptionsEnabled=true;tools.overviews=({});tools.avatars=({});tools.avatarPending=({});tools.avatarChecked=({});tools.pictureRevision=-1;tools.snapshotsPending=({});tools.requesting=false;tools.notificationRows=({});tools.notificationsPending=({});first.delivered=[];second.delivered=[];service.windowOpen=true;service.curatedInbox=false;tools.visibleRows=service.messages }
    function cleanup() { backend.ready=false }
    function test_stack_uses_live_owned_work_but_drain_keeps_the_raw_queue() {
      backend.apiVersion=8;backend.ready=true;service.curatedInbox=true
      compare(tools.stack.count,2);compare(tools.stack.messages.length,1)
      tools.writingIds=({"two@example.org":["shared-id"]})
      compare(tools.stack.currentId,"two-message","account plus message, not a bare Gmail id")
      compare(service.rawMessages.length,2,"collapsing never removes scheduler candidates")
      tools.overviews=({"two@example.org\nshared-id":{state:"ready",version:2,text:"Your books are ready.",expiresAt:0,refresh:true}})
      compare(tools.stack.currentId,"two-message","ready card stays briefly while it lifts");
      tryCompare(tools,"departingId","two-message");
      tryVerify(function(){return tools.stack.currentId === "one-message"});compare(tools.stack.messages.length,2)
      tools.selecting=true
      compare(tools.stack.currentId,"");compare(tools.stack.messages.length,2)
      tools.selecting=false;tools.paused=true
      compare(tools.stack.currentId,"");compare(tools.stack.messages.length,2)
    }
    function test_painted_pictures_replace_avatars_without_blanking_them() {
      backend.apiVersion=8;backend.ready=true
      var first=backend.calls.filter(function(request){return request.method==="inbox.avatar"})[0]
      verify(first)
      first.done({data:"data:image/png;base64,b2xk",source:"organization"},null)
      compare(tools.avatarFor(service.messages[0]),"data:image/png;base64,b2xk")
      var snapshot=backend.calls.filter(function(request){return request.method==="inbox.snapshot" && request.params.accountId===first.params.accountId})[0]
      verify(snapshot)
      snapshot.done({overviews:{},snoozes:[],preferences:{paused:false},pictures:4},null)
      compare(tools.pictureRevision,4)
      var asked=backend.calls.filter(function(request){return request.method==="inbox.avatar"}).length
      tools.drain()
      compare(backend.calls.filter(function(request){return request.method==="inbox.avatar"}).length,asked)
      tools.notePictureRevision(5)
      tools.drain()
      var again=backend.calls.filter(function(request){return request.method==="inbox.avatar" && request.params.email===first.params.email && request.params.accountId===first.params.accountId})
      compare(again.length,2)
      compare(again[1].params.refreshId,"")
      compare(tools.avatarFor(service.messages[0]),"data:image/png;base64,b2xk")
      again[1].done(null,{code:-32000,message:"inbox_unavailable"})
      compare(tools.avatarFor(service.messages[0]),"data:image/png;base64,b2xk")
      tools.notePictureRevision(6)
      tools.drain()
      var third=backend.calls.filter(function(request){return request.method==="inbox.avatar" && request.params.email===first.params.email && request.params.accountId===first.params.accountId})
      compare(third.length,3)
      third[2].done({data:"data:image/png;base64,cGFpbnRlZA==",source:"painted"},null)
      compare(tools.avatarFor(service.messages[0]),"data:image/png;base64,cGFpbnRlZA==")
    }
    function test_notifications_wait_for_owned_ready_unread_inbox_members() {
      backend.apiVersion=8;backend.ready=true
      tools.queueNotifications(first.accountId,[{id:"pending"},{id:"read"},{id:"gone"},{id:"ready"},{id:"unknown"}])
      compare(first.delivered.length,0)
      var values=({})
      for (var id of ["read","gone","ready","unknown"]) values[first.accountId+"\n"+id]={state:"ready",version:2,text:"Prepared notification",expiresAt:0}
      tools.overviews=values;tools.flushNotifications(first.accountId)
      var request=backend.calls.filter(function(row){return row.method==="local.summaries"})[0]
      verify(request);compare(request.params.accountId,first.accountId)
      verify(request.params.ids.indexOf("pending")<0)
      request.done({summaries:[{id:"read",matchesQuery:false},{id:"ready",matchesQuery:true},{id:"unknown"}]},null)
      compare(first.delivered.length,1);compare(first.delivered[0].id,"ready");compare(first.delivered[0].subject,"Prepared notification")
      compare(second.delivered.length,0)
      compare(Object.keys(tools.notificationRows[first.accountId]).join(","),"pending")
    }
    function test_every_inbox_row_shows_moving_lines_only_while_its_point_is_written() {
      service.curatedInbox=true;tools.visibleRows=[];tools.preparationFailures=({});tools.unansweredSince=0
      backend.apiVersion=8;backend.ready=true
      verify(backend.calls.some(function(request){return request.method==="inbox.overviews"}))
      compare(tools.status(service.rawMessages[0]),"writing");compare(tools.writingCount,2)
      tools.overviews={"one@example.org\nshared-id":{state:"ready",version:2,text:"Prepared mail",expiresAt:0},"two@example.org\nshared-id":{state:"failed",version:2,text:"Unverified text",expiresAt:0,attempts:1}}
      compare(tools.status(service.rawMessages[0]),"ready")
      compare(tools.status(service.rawMessages[1]),"plain","a message whose own attempt failed shows its subject")
      compare(tools.writingCount,0);compare(tools.hold,"","a message's own failure is no warning")
      tools.overviews={"two@example.org\nshared-id":{state:"running",version:2,updated:Date.now()}}
      compare(tools.status(service.rawMessages[0]),"writing","a message not asked yet is being written")
      compare(tools.status(service.rawMessages[1]),"writing");compare(tools.writingCount,2)
      tools.overviews={"two@example.org\nshared-id":{state:"running",version:2,updated:Date.now(),attempts:1}}
      compare(tools.status(service.rawMessages[1]),"plain","asking again after its own failure is quiet");compare(tools.writingCount,1)
      tools.overviews={"two@example.org\nshared-id":{state:"failed",version:2,problem:"overview_ai_unavailable",updated:Date.now()}}
      compare(tools.status(service.rawMessages[1]),"writing","Claude not answering once still counts as being written")
      tools.paused=true
      compare(tools.hold,"paused");compare(tools.holdText,"New Points are paused.");compare(tools.status(service.rawMessages[1]),"plain");compare(tools.writingCount,0)
      tools.paused=false;tools.descriptionsEnabled=false
      compare(tools.status(service.rawMessages[0]),"plain");compare(tools.writingCount,0);compare(tools.hold,"")
      tools.descriptionsEnabled=true;service.curatedInbox=false
      compare(tools.status(service.rawMessages[0]),"plain","All mail and search show subjects");compare(tools.writingCount,0)
      service.curatedInbox=true;tools.overviews=({});compare(tools.writingCount,2)
      backend.ready=false
      compare(tools.status(service.rawMessages[0]),"plain","no engine, nothing being written");compare(tools.writingCount,0);compare(tools.hold,"")
      backend.ready=true;backend.apiVersion=7
      compare(tools.status(service.rawMessages[0]),"plain","an engine too old to write Points");compare(tools.writingCount,0)
      backend.apiVersion=8;service.curatedInbox=false
      compare(tools.admitted(second.accountId,[{id:"shared-id"}]).length,0)
    }
    function test_every_subscription_out_holds_the_points_and_a_lasting_silence_is_named() {
      service.curatedInbox=true;tools.preparationFailures=({});tools.unansweredSince=0
      backend.apiVersion=8;backend.ready=true
      tools.overviews={"one@example.org\nshared-id":{state:"failed",version:2,problem:"overview_ai_paused",updated:Date.now()}}
      compare(tools.hold,"subscriptions");compare(tools.holdText,"Your Claude subscriptions are all used up for now. Points continue when one resets.")
      compare(tools.status(service.rawMessages[1]),"plain","nothing is being written while every subscription is out");compare(tools.writingCount,0)
      var refused=Date.now()-60000
      tools.overviews={"one@example.org\nshared-id":{state:"failed",version:2,problem:"overview_ai_paused",updated:refused},"two@example.org\nshared-id":{state:"ready",version:2,text:"Prepared",expiresAt:0,updated:refused-1}}
      compare(tools.hold,"subscriptions","a Point written before the refusal does not end it")
      tools.overviews={"one@example.org\nshared-id":{state:"failed",version:2,problem:"overview_ai_paused",updated:refused},"two@example.org\nshared-id":{state:"ready",version:2,text:"Prepared",expiresAt:0,updated:refused+1}}
      compare(tools.hold,"","a Point written since means a subscription is back");compare(tools.status(service.rawMessages[0]),"writing")
      tools.overviews={"one@example.org\nshared-id":{state:"failed",version:2,problem:"ai_unreachable",updated:Date.now()}}
      var now=Date.now();tools.overviewClock=now
      tools.unansweredSince=now-14*60000;compare(tools.hold,"","a short silence shows as Points being written");compare(tools.writingCount,2)
      tools.unansweredSince=now-25*60000-1000;compare(tools.hold,"unanswered");compare(tools.holdText,"Claude has not answered for 25 minutes. Magpie Mail keeps trying.")
      compare(tools.status(service.rawMessages[0]),"plain")
      tools.overviews={"one@example.org\nshared-id":{state:"ready",version:2,text:"Prepared",expiresAt:0},"two@example.org\nshared-id":{state:"ready",version:2,text:"Prepared",expiresAt:0}}
      compare(tools.hold,"","nothing unfinished, nothing to report")
      tools.unansweredSince=0
    }
    function test_claudes_silence_starts_with_a_fresh_failure_and_ends_with_the_next_point() {
      service.curatedInbox=true;tools.preparationFailures=({});tools.unansweredSince=0
      backend.apiVersion=8;backend.ready=true
      function snapshotDone(overviews) {
        var calls=backend.calls.filter(function(request){return request.method==="inbox.snapshot" && request.params.accountId==="one@example.org"})
        verify(calls.length);calls[calls.length-1].done({overviews:overviews,snoozes:[]},null)
      }
      snapshotDone({"shared-id":{state:"failed",version:2,problem:"ai_unreachable",updated:Date.now()-600000}})
      compare(tools.unansweredSince,0,"an old failure does not start the clock")
      tools.snapshot("one@example.org")
      snapshotDone({"shared-id":{state:"failed",version:2,problem:"ai_unreachable",updated:Date.now()}})
      verify(tools.unansweredSince>0)
      var started=tools.unansweredSince
      tools.snapshot("one@example.org")
      snapshotDone({"shared-id":{state:"failed",version:2,problem:"overview_unsupported_claim",updated:Date.now()}})
      compare(tools.unansweredSince,started,"a message's own failure neither starts nor ends it")
      tools.snapshot("one@example.org")
      snapshotDone({"shared-id":{state:"ready",version:2,text:"Prepared",expiresAt:0}})
      compare(tools.unansweredSince,0,"a new Point ends it")
    }
    function test_cached_relative_words_expire_while_disconnected() {
      wait(400)
      tools.overviewClock=Date.now()
      tools.overviews={"one@example.org\nshared-id":{text:"Due today",state:"ready",version:2,expiresAt:Date.now()+50}}
      compare(tools.overviewFor(service.messages[0]).text,"Due today")
      tryVerify(function(){return tools.overviewFor(service.messages[0]).text===""},6000)
      compare(backend.calls.length,0)
    }
    function test_expired_descriptions_fall_back_and_remote_images_remain_opt_in() {
      tools.overviews={"one@example.org\nshared-id":{text:"Due yesterday",state:"ready",version:2,expiresAt:1}}
      compare(tools.overviewFor(service.messages[0]).text,"")
      backend.apiVersion=8;backend.ready=true
      var job=backend.calls.filter(function(request){return request.method==="inbox.overviews"})[0]
      verify(job)
      compare(job.params.allowRemoteImages,false)
    }
    function test_original_subject_mode_keeps_preparation_and_avatars() {
      tools.descriptionsEnabled=false
      backend.apiVersion=8;backend.ready=true;tools.refresh()
      verify(backend.calls.some(function(request){return request.method==="inbox.overviews"}))
      verify(backend.calls.some(function(request){return request.method==="inbox.avatar"}))
    }
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
      snapshot.done({overviews:{"shared-id":{text:"First account only",state:"ready",version:2,expiresAt:0}},snoozes:[]},null)
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

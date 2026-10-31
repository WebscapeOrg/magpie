import QtQuick
import QtTest
import "../../inbox" as Inbox
Item {
 id: root
 width:400;height:300
 property var delivered: []
 QtObject {id:host;property string accountId:"a@example.test";property string providerId:"gmail";function deliverNotification(rows){root.delivered=root.delivered.concat(rows)}}
 QtObject {id:backend;property bool ready:false;property int apiVersion:8;property var protocolInfo:({engineService:true});property var calls:[];function call(method,params,done){calls=calls.concat([{method:method,params:params,done:done}])}}
 QtObject {
  id:service
  property var backend:backend
  property bool windowOpen:false
  property bool accountsLoaded:true
  property bool windowPrefsLoaded:true
  property int saves:0
  function saveWindowPrefs(){saves++}
  property bool alwaysShowImages:false
  property bool notifyNewMail:true
  property bool curatedInbox:true
  property bool listLoading:false
  property bool hasMore:false
  property int preparingInbox:0
  property var accountSummaries:[{id:"a@example.test"}]
  property var rawMessages:[]
  property var messages:[]
  function hostForId(id){return host}
  function findAccount(id){return accountSummaries.some(function(a){return a.id===id})?host:null}
 }
 Inbox.InboxTools {id:tools;service:service}
 TestCase {
  name:"CuratedNotifications";when:windowShown
  function init(){backend.ready=false;backend.calls=[];root.delivered=[];service.accountsLoaded=true;service.saves=0;tools.preferenceQueue=({});tools.preparationFailures=({});tools.preferenceWrites=0;tools.error="";service.accountSummaries=[{id:"a@example.test"}];tools.overviews=({});tools.snapshotsPending=({});tools.notificationRows=({});tools.notificationsPending=({});tools.overviewClock=1000;backend.ready=true;tools.overviewClock=1000}
  function cleanup(){backend.ready=false}
  function ready(id,expiry){var records=Object.assign({},tools.overviews);records["a@example.test\n"+id]={version:2,state:"ready",text:"Prepared "+id,expiresAt:expiry||0};tools.overviews=records}
  function summaryRequest(){var calls=backend.calls.filter(function(c){return c.method==="local.summaries"});return calls[calls.length-1]}

  function test_unready_archived_notifications_are_pruned_in_bounded_rotating_batches(){
   var rows=[];for(var n=0;n<201;n++)rows.push({id:"pending"+n})
   tools.queueNotifications("a@example.test",rows)
   for(var n=0;n<3;n++) { tools.flushNotifications("a@example.test");var q=summaryRequest();verify(q);verify(q.params.ids.length<=100);q.done({summaries:[]},null) }
   compare(root.delivered.length,0);compare(Object.keys(tools.notificationRows["a@example.test"]).length,0)
  }
  function test_startup_waits_for_account_inventory_and_removal_is_persisted(){
   backend.ready=false;service.accountsLoaded=false;service.accountSummaries=[]
   tools.restorePreparation({preparationQueue:{"a@example.test":{allowRemoteImages:false}},preparationFailures:{}})
   tools.retainAccounts();verify(tools.preferenceQueue["a@example.test"])
   service.accountSummaries=[{id:"a@example.test"}];service.accountsLoaded=true;tools.retainAccounts();verify(tools.preferenceQueue["a@example.test"])
   var saves=service.saves;service.accountSummaries=[];tools.retainAccounts();compare(Object.keys(tools.preferenceQueue).length,0);verify(service.saves>saves)
  }
  function test_removed_account_clears_never_ready_rows(){
   tools.queueNotifications("a@example.test",[{id:"forever"}]);service.accountSummaries=[];tools.retainAccounts();compare(Object.keys(tools.notificationRows).length,0)
  }
  function test_successful_preference_retry_clears_only_its_own_warning(){
   function prefs(){return backend.calls.filter(function(c){return c.method==="inbox.preferences"})}
   tools.savePreparationPreferences("paused",true);prefs()[0].done(null,"offline");verify(tools.error.indexOf("Enterprise has not received")===0)
   tools.flushPreparationPreferences();prefs()[1].done({paused:true},null);compare(tools.error,"")
   tools.error="Other failure";tools.flushPreparationPreferences();compare(tools.error,"Other failure")
  }
  function test_newer_preference_survives_old_save_response(){
   function prefs(){return backend.calls.filter(function(c){return c.method==="inbox.preferences"})}
   tools.savePreparationPreferences("allowRemoteImages",true);var first=prefs()[0];verify(first)
   tools.savePreparationPreferences("allowRemoteImages",false);first.done({allowRemoteImages:true},null)
   compare(tools.preferenceQueue["a@example.test"].allowRemoteImages,false);var second=prefs()[1];verify(second);compare(second.params.allowRemoteImages,false)
   second.done({allowRemoteImages:false},null);compare(Object.keys(tools.preferenceQueue).length,0)
  }
  function test_transport_failure_age_survives_repeated_failure_and_clears_on_success(){
   var name="a@example.test\nsnapshot",start=Date.now()-901000
   var values=({});values[name]=start;tools.preparationFailures=values;tools.preparationResult("a@example.test","snapshot",true)
   compare(tools.preparationFailures[name],start);service.preparingInbox=1;tools.overviewClock=Date.now();verify(tools.preparationProblem.indexOf("All mail")>=0)
   tools.preparationResult("a@example.test","snapshot",false);compare(Object.keys(tools.preparationFailures).length,0);service.preparingInbox=0
  }

  function test_no_subject_or_alert_before_ready(){
   tools.queueNotifications("a@example.test",[{id:"one",subject:"raw subject"}]);compare(summaryRequest(),undefined);compare(root.delivered.length,0)
   ready("one");tools.flushNotifications("a@example.test");var q=summaryRequest();verify(q);compare(q.params.ids.length,1)
   q.done({summaries:[{id:"one",matchesQuery:true,subject:"raw subject",snippet:"raw body"}]},null)
   compare(root.delivered.length,1);compare(root.delivered[0].subject,"Prepared one");compare(root.delivered[0].snippet,"")
  }
  function test_read_archived_unknown_and_missing_rows_never_alert(){
   for(var n=0;n<4;n++) {
    var id="held"+n;ready(id);tools.queueNotifications("a@example.test",[{id:id}]);tools.flushNotifications("a@example.test");var q=summaryRequest();verify(q)
    var row={id:id};if(n===0)row.matchesQuery=false;if(n===1)row.matchesQuery=null;if(n===2)row.matchesQuery=undefined
    q.done({summaries:n===3?[]:[row]},null)
   }
   compare(root.delivered.length,0);compare(Object.keys(tools.notificationRows["a@example.test"]).length,0)
  }
  function test_batches_are_bounded_and_later_ready_ids_are_not_lost(){
   var rows=[];for(var n=0;n<201;n++){var id="m"+n;rows.push({id:id});ready(id)}
   tools.queueNotifications("a@example.test",rows)
   for(var batch=0;batch<3;batch++){
    tools.flushNotifications("a@example.test");var q=summaryRequest();verify(q);verify(q.params.ids.length<=100);compare(q.params.ids.length,batch<2?100:1)
    q.done({summaries:q.params.ids.map(function(id){return{id:id,matchesQuery:true}})},null)
   }
   compare(root.delivered.length,201);compare(Object.keys(tools.notificationRows["a@example.test"]).length,0)
  }
  function test_removed_account_and_late_expiry_do_not_deliver(){
   ready("expire",1001);tools.queueNotifications("a@example.test",[{id:"expire"}]);tools.flushNotifications("a@example.test");var q=summaryRequest();verify(q)
   tools.overviewClock=2000;q.done({summaries:[{id:"expire",matchesQuery:true}]},null);compare(root.delivered.length,0)
   ready("removed");tools.queueNotifications("a@example.test",[{id:"removed"}]);tools.flushNotifications("a@example.test");q=summaryRequest();service.accountSummaries=[]
   q.done({summaries:[{id:"removed",matchesQuery:true}]},null);compare(root.delivered.length,0)
  }
 }
}

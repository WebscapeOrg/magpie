import QtQuick
import QtTest
import "../.." as Magpie
import "BackendFixture.js" as BackendFixture
import "ModelFixture.js" as ModelFixture

Item {
  id: fixture
  property var service: null
  property var transport: null
  property bool capture: false
  property bool structured: false
  property bool deferPreparation: false
  readonly property string first: "search-first@example.test"
  readonly property string second: "search-second@example.test"
  function accounts() {
    return [{id:first,email:first,provider:"gmail",clientId:""},
      {id:second,email:second,provider:"gmail",clientId:""}]
  }
  function calls(method,query) {
    return transport.requests.filter(function(request) {
      return request.method === method && (query === undefined || request.params.query === query)
    })
  }
  Component {
    id: serviceFactory
    Magpie.Service { manifest:({id:"magpie"}); initialSettings:({unifiedMailboxes:true,notifyNewMail:"Off"}) }
  }
  TestCase {
    name: "SearchParticipants"
    function init() {
      failOnWarning(/TypeError|ReferenceError|invalid context/)
      fixture.capture=false
      fixture.structured=false
      fixture.deferPreparation=false
      fixture.service=createTemporaryObject(serviceFactory,fixture)
      verify(fixture.service)
      fixture.transport=BackendFixture.install(fixture.service)
      fixture.transport.answers={
        "auth.token":{access_token:"synthetic-access",expires_in:3600},
        "credentials.get":{found:true,secret:"synthetic-password"},
        "local.status":{stored:2,pendingEdits:0},
        "local.watch":{coverage:{stored:2,pendingEdits:0},summaries:[],labels:[],unread:0},
        "local.overview":{coverage:{stored:2,pendingEdits:0},summaries:[],labels:[],unread:0},
        "local.refresh":{coverage:{stored:2,pendingEdits:0},summaries:[],labels:[],unread:0},
        "local.edits":[], "local.unwatch":{}, "gmail.invalidate":{},
        "gmail.profile":{email:"synthetic@example.test"}, "gmail.sendAs":[], "gmail.labels":[],
        "local.list":function(params) {return {summaries:[],nextPageToken:"",coverage:{stored:2}}},
        "local.summaries":function(params) {return {summaries:[],missingIds:params.ids,pendingNextPageToken:""}},
        "gmail.list":function(params) {return fixture.capture ? undefined : {ids:[],nextPageToken:"",estimate:0}},
        "model.unified":function(params) {return ModelFixture.unified(params)},
        "providers.resolve":function(params) {
          if (fixture.deferPreparation && params.operation === "query") return undefined
          return {value:params.search || params.value || "in:inbox",search:{valid:true,structured:fixture.structured}}
        }
      }
      fixture.service.applyAccounts(JSON.stringify({version:1,activeId:fixture.first,accounts:fixture.accounts()}))
      tryCompare(fixture.service,"accountCount",2)
      BackendFixture.markReady(fixture.service,8)
      tryVerify(function() {return !!fixture.service.findAccount(fixture.second)},1000)
      fixture.service.eachHost(function(host) {
        host.profile={email:host.accountId};host.sendAsLoaded=true
          host.auth.credentials={clientId:"synthetic.apps.googleusercontent.com",clientSecret:"synthetic-secret"}
          host.auth.loggedIn=true
      })
      wait(80)
      fixture.service.eachHost(function(host) {host.auth.loggedIn=true})
      tryVerify(function() {return fixture.service.findAccount(fixture.second).ready},1000)
      compare(fixture.service.unified,true)
      fixture.capture=true
      fixture.transport.requests=[]
    }
    function cleanup() {fixture.capture=false;fixture.deferPreparation=false}
    function test_one_preparation_dispatches_unchanged_query_and_date_to_both_accounts_data() {
      return [{tag:"plain", query:"invoice"}, {tag:"syntax",query:"from:me label:\"Work projects\" newer_than:7d"}]
    }
    function test_one_preparation_dispatches_unchanged_query_and_date_to_both_accounts(data) {
      fixture.service.search(data.query)
      tryCompare(fixture.service,"submittedUnifiedQuery",data.query,1000)
      tryVerify(function(){return fixture.calls("gmail.list",data.query).length === 2},1000)
      var prepares=fixture.calls("providers.resolve")
      compare(prepares.length,1)
      compare(prepares[0].params.search,data.query)
      verify(prepares[0].params.asOf > 0)
      var locals=fixture.calls("local.list",data.query)
      compare(locals.length,2)
      var ids=[]
      for(var index=0;index<locals.length;index++) {
        ids.push(locals[index].params.accountId)
        compare(locals[index].params.asOf,prepares[0].params.asOf)
        compare(locals[index].params.query,data.query)
      }
      compare(ids.sort(),[fixture.first,fixture.second].sort())
      compare(fixture.service.searchParticipantIds,[fixture.first,fixture.second])
      compare(fixture.service.searchStatus.scope,"All accounts · 2 accounts searched")
      var lists=fixture.calls("gmail.list",data.query)
      for(var index=0;index<lists.length;index++) BackendFixture.respond(fixture.service,lists[index],{ids:[],nextPageToken:"",estimate:0})
      tryVerify(function(){return fixture.service.searchStatus.phase === "complete"},1000)
      compare(fixture.service.unifiedMessages.length,0)
      compare(fixture.service.hasMore,false)
      compare(fixture.calls("providers.resolve").length,1)
    }
    function test_stop_retry_keeps_participants_and_ignores_late_replies() {
      fixture.service.search("invoice")
      tryVerify(function(){return fixture.calls("gmail.list","invoice").length === 2},1000)
      var old=fixture.calls("gmail.list","invoice")
      fixture.service.stopSearch()
      for(var index=0;index<old.length;index++) BackendFixture.respond(fixture.service,old[index],{ids:["forbidden-late"],nextPageToken:"",estimate:1})
      wait(20)
      compare(fixture.calls("gmail.read").length,0)
      fixture.service.retrySearch()
      tryVerify(function(){return fixture.calls("gmail.list","invoice").length === 4},1000)
      compare(fixture.calls("providers.resolve").length,1)
    }
    function test_single_account_uses_one_preparation() {
      fixture.service.settings=Object.assign({},fixture.service.settings,{unifiedMailboxes:false})
      fixture.transport.requests=[]
      fixture.service.search("to:me")
      tryVerify(function(){return fixture.calls("gmail.list","to:me").length === 1},1000)
      compare(fixture.calls("providers.resolve").length,1)
      compare(fixture.calls("local.list","to:me")[0].params.accountId,fixture.first)
    }
    function test_invalid_submission_makes_no_mail_requests() {
      fixture.deferPreparation=true
      fixture.service.search("from:(")
      tryCompare(fixture.service,"preparingSearchQuery","from:(",1000)
      var preparation=fixture.calls("providers.resolve")[0]
      BackendFixture.respond(fixture.service,preparation,{value:"from:(",search:{valid:false,message:"Close the group."}})
      tryVerify(function(){return fixture.service.searchStatus.phase === "invalid"},1000)
      compare(fixture.calls("gmail.list").length,0)
      compare(fixture.calls("local.list","from:(").length,0)
    }
    function test_new_account_does_not_join_an_existing_submission() {
      fixture.structured=true
      fixture.service.search("is:read")
      tryVerify(function(){return fixture.calls("gmail.list","is:read").length === 2},1000)
      var values=fixture.accounts()
      values.push({id:"new@example.test",email:"new@example.test",provider:"gmail",clientId:""})
      fixture.service.applyAccounts(JSON.stringify({version:1,activeId:fixture.first,accounts:values}))
      tryCompare(fixture.service,"accountCount",3)
      tryVerify(function(){return !!fixture.service.findAccount("new@example.test")},1000)
      compare(fixture.service.searchParticipant(fixture.service.findAccount("new@example.test")),false)
      compare(fixture.service.unifiedSources.length,2)
      compare(fixture.service.findAccount("new@example.test").searchQuery,"")
      compare(fixture.calls("gmail.list","is:read").length,2)
    }
    function test_stopped_preparation_retries_the_requested_query_and_ignores_old_reply() {
      fixture.deferPreparation=true
      fixture.structured=true
      fixture.service.search("is:read")
      tryVerify(function(){return fixture.calls("providers.resolve").length === 1},1000)
      var old=fixture.calls("providers.resolve")[0]
      fixture.service.stopSearch()
      compare(fixture.service.searchStatus.phase,"stopped")
      fixture.service.retrySearch()
      tryVerify(function(){return fixture.calls("providers.resolve").length === 2},1000)
      var latest=fixture.calls("providers.resolve")[1]
      BackendFixture.respond(fixture.service,old,{value:"is:read",search:{valid:true,structured:true}})
      wait(20)
      compare(fixture.service.submittedUnifiedQuery,"")
      fixture.deferPreparation=false
      BackendFixture.respond(fixture.service,latest,{value:"is:read",search:{valid:true,structured:true}})
      tryVerify(function(){return fixture.calls("gmail.list","is:read").length === 2},1000)
      compare(fixture.service.submittedUnifiedQuery,"is:read")
    }
    function test_rebuilding_accounts_during_preparation_cancels_old_submission() {
      fixture.deferPreparation=true
      fixture.service.search("from:me")
      tryVerify(function(){return fixture.calls("providers.resolve").length === 1},1000)
      var pending=fixture.calls("providers.resolve")[0]
      fixture.service.accountList=Object.assign({},fixture.service.accountList,{accounts:fixture.service.accountList.accounts.concat([{id:"new@example.test",email:"new@example.test",provider:"gmail",clientId:""}])})
      tryCompare(fixture.service,"accountCount",3)
      BackendFixture.respond(fixture.service,pending,{value:"from:me",search:{valid:true}})
      wait(20)
      compare(fixture.calls("gmail.list","from:me").length,0)
      compare(fixture.service.submittedUnifiedQuery,"")
      compare(fixture.service.findAccount("new@example.test").searchQuery,"")
    }
    function test_account_switch_cancels_single_preparation() {
      fixture.service.settings=Object.assign({},fixture.service.settings,{unifiedMailboxes:false})
      fixture.deferPreparation=true
      fixture.transport.requests=[]
      fixture.service.search("is:read")
      var old=fixture.calls("providers.resolve")[0]
      fixture.service.switchTo(fixture.second)
      BackendFixture.respond(fixture.service,old,{value:"is:read",search:{valid:true}})
      wait(20)
      compare(fixture.calls("gmail.list","is:read").length,0)
      compare(fixture.service.current.searchQuery,"")
    }
    function test_leaving_unified_search_restores_mailbox_and_invalidates_late_results() {
      fixture.structured=true
      fixture.service.search("is:read")
      tryVerify(function(){return fixture.calls("gmail.list","is:read").length === 2},1000)
      var requests=fixture.calls("gmail.list","is:read")
      fixture.service.settings=Object.assign({},fixture.service.settings,{unifiedMailboxes:false})
      compare(fixture.service.unified,false)
      compare(fixture.service.searchQuery,"")
      compare(fixture.service.current.searchQuery,"")
      compare(fixture.service.current.submittedSearch.active,false)
      for (var index=0;index<requests.length;index++) BackendFixture.respond(fixture.service,requests[index],{ids:["stale"],nextPageToken:"",estimate:1})
      wait(20)
      compare(fixture.calls("gmail.read").length,0)
    }
  }
}

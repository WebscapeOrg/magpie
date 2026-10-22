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
  readonly property string legacy: "imap:search-legacy@example.test"
  function accounts() {
    return [{id:first,email:first,provider:"gmail",clientId:""},
      {id:second,email:second,provider:"gmail",clientId:""},
      {id:legacy,email:"search-legacy@example.test",provider:"imap",imap:{
        imapHost:"imap.example.test",imapPort:993,smtpHost:"smtp.example.test",smtpPort:465,
        username:"search-legacy@example.test"}}]
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
        "imap.folders":{folders:[],special:{},capabilities:[],labels:[]},"imap.cancel":{},
        "local.list":function(params) {return {summaries:[],nextPageToken:"",coverage:{stored:2}}},
        "local.summaries":function(params) {return {summaries:[],missingIds:params.ids,pendingNextPageToken:""}},
        "gmail.list":function(params) {return fixture.capture ? undefined : {ids:[],nextPageToken:"",estimate:0}},
        "imap.list":function(params) {return fixture.capture && params.query === "invoice" ? undefined : {page:{ids:[],nextPageToken:"",estimate:0}}},
        "model.unified":function(params) {return ModelFixture.unified(params)},
        "providers.resolve":function(params) {
          if (fixture.deferPreparation && params.operation === "query") return undefined
          return {value:params.search || params.value || "in:inbox",search:{valid:true,structured:fixture.structured}}
        }
      }
      fixture.service.applyAccounts(JSON.stringify({version:1,activeId:fixture.first,accounts:fixture.accounts()}))
      tryCompare(fixture.service,"accountCount",3)
      BackendFixture.markReady(fixture.service,8)
      tryVerify(function() {return !!fixture.service.findAccount(fixture.legacy)},1000)
      fixture.service.eachHost(function(host) {
        host.profile={email:host.accountId};host.sendAsLoaded=true
        if (host.providerId === "gmail") {
          host.auth.credentials={clientId:"synthetic.apps.googleusercontent.com",clientSecret:"synthetic-secret"}
          host.auth.loggedIn=true
        } else host.auth.password="synthetic-password"
      })
      wait(80)
      fixture.service.eachHost(function(host) {if (host.providerId === "gmail") host.auth.loggedIn=true})
      tryVerify(function() {return fixture.service.findAccount(fixture.legacy).ready},1000)
      compare(fixture.service.unified,true)
      fixture.capture=true
      fixture.transport.requests=[]
    }
    function cleanup() {fixture.capture=false;fixture.deferPreparation=false}
    function test_structured_search_excludes_legacy_rows_errors_loading_and_capabilities() {
      var legacy=fixture.service.findAccount(fixture.legacy)
      legacy.messages=[{id:"stale-legacy",subject:"Unrelated",dateMs:1700000000000}]
      legacy.lastError="Unrelated legacy error"
      legacy.listLoading=true
      fixture.structured=true
      fixture.service.search("from:alice")
      tryCompare(fixture.service,"submittedUnifiedQuery","from:alice",1000)
      tryVerify(function(){return fixture.calls("gmail.list","from:alice").length === 2},1000)
      compare(fixture.calls("imap.list","from:alice").length,0)
      compare(fixture.service.searchParticipantIds,[fixture.first,fixture.second])
      compare(fixture.service.unifiedSources.length,2)
      compare(fixture.service.unifiedStates.length,2)
      compare(fixture.service.unifiedAbilities.length,2)
      compare(fixture.service.searchStatus.scope,"Gmail accounts · 2 of 3 accounts searched")
      var lists=fixture.calls("gmail.list","from:alice")
      for (var index=0;index<lists.length;index++) BackendFixture.respond(fixture.service,lists[index],{ids:[],nextPageToken:"",estimate:0})
      tryCompare(fixture.service,"serverSearchLoading",false,1000)
      tryVerify(function(){return fixture.service.searchStatus.phase === "complete"},1000)
      compare(fixture.service.unifiedMessages.length,0)
      verify(fixture.service.lastError.indexOf("legacy") < 0)
      compare(fixture.service.hasMore,false)
    }
    function test_plain_text_search_includes_all_and_legacy_stop_retry_really_restarts() {
      fixture.service.search("invoice")
      tryVerify(function(){return fixture.calls("gmail.list","invoice").length === 2},1000)
      tryVerify(function(){return fixture.calls("imap.list","invoice").length === 1},1000)
      compare(fixture.service.searchParticipantIds,[fixture.first,fixture.second,fixture.legacy])
      compare(fixture.service.searchStatus.scope,"All accounts · 3 accounts searched")
      fixture.service.stopSearch()
      var legacy=fixture.service.findAccount(fixture.legacy)
      compare(legacy.listLoading,false)
      compare(legacy.legacySearchStopped,true)
      var old=fixture.calls("imap.list","invoice")[0]
      BackendFixture.respond(fixture.service,old,{page:{ids:["forbidden-late"],nextPageToken:"",estimate:1}})
      wait(20)
      compare(fixture.calls("imap.messages").length,0)
      fixture.service.retrySearch()
      tryVerify(function(){return fixture.calls("gmail.list","invoice").length === 4},1000)
      tryVerify(function(){return fixture.calls("imap.list","invoice").length === 2},1000)
      compare(legacy.legacySearchStopped,false)
    }
    function test_new_account_does_not_join_an_existing_submission() {
      fixture.structured=true
      fixture.service.search("is:read")
      tryVerify(function(){return fixture.calls("gmail.list","is:read").length === 2},1000)
      var values=fixture.accounts()
      values.push({id:"new@example.test",email:"new@example.test",provider:"gmail",clientId:""})
      fixture.service.applyAccounts(JSON.stringify({version:1,activeId:fixture.first,accounts:values}))
      tryCompare(fixture.service,"accountCount",4)
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

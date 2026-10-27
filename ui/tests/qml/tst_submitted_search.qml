import QtQuick
import QtTest
import qs.Commons
import qs.Commons as Commons
import "../../account" as Account
import "../../components" as Components

Item {
  id: fixture
  width: 600
  height: 400
  property var requests: []
  property bool capture: false
  property bool deferPreparation: false
  property var saved: ({})
  property var pendingRows: []

  function row(id, extra) {
    return Object.assign({id:id,subject:"Synthetic " + id,dateMs:1700000000000,
      unread:true,labelIds:["INBOX","UNREAD"],pendingEdit:false,matchesQuery:true}, extra || {})
  }
  function automatic(request, result, error) {
    Qt.callLater(function() {
      if (!request.withdrawn && !request.settled) fixture.answer(request, result, error)
    })
  }
  function answer(request, result, error) {
    request.settled = true
    request.callback(result, error || null)
  }
  function calls(method) {
    return requests.filter(function(request) { return request.method === method })
  }
  function next(method) {
    var matches = calls(method).filter(function(request) { return !request.settled && !request.withdrawn })
    return matches.length ? matches[0] : null
  }
  QtObject {
    id: transport
    property bool ready: false
    property int apiVersion: 8
    property string executable: "/synthetic/search-backend"
    property var protocolInfo: ({apiVersion:8,methods:[]})
    signal notification(string method, var params)
    function call(method, parameters, callback) {
      var request = {method:method,params:JSON.parse(JSON.stringify(parameters)),callback:callback,
        settled:false,withdrawn:false,unsent:false}
      request.withdraw = function() {
        if (request.settled || request.withdrawn || !request.unsent) return false
        request.withdrawn = true
        return true
      }
      fixture.requests.push(request)
      if (method === "providers.resolve") {
        if (fixture.deferPreparation && parameters.operation === "query") return request
        fixture.automatic(request, {value:parameters.search || parameters.value || "in:inbox",search:{valid:true}})
      } else if (method === "local.list") {
        if (!fixture.capture) fixture.automatic(request, {summaries:[],nextPageToken:"",coverage:{stored:2}})
      } else if (method === "local.summaries") {
        var rows = [], missing = []
        for (var index = 0; index < parameters.ids.length; index++) {
          var id = parameters.ids[index]
          if (Object.prototype.hasOwnProperty.call(fixture.saved,id)) rows.push(fixture.saved[id])
          else missing.push(id)
        }
        if (parameters.includePending) rows = rows.concat(fixture.pendingRows)
        fixture.automatic(request, {summaries:rows,missingIds:missing,pendingNextPageToken:"",asOf:parameters.asOf})
      } else if (method === "gmail.list" || method === "gmail.read") {
        if (!fixture.capture) fixture.automatic(request, {ids:[],nextPageToken:"",estimate:0})
      } else if (method === "message.summaries") {
        fixture.automatic(request, {summaries:parameters.messages.map(function(message) { return fixture.row(message.id) })})
      } else if (method === "local.status") fixture.automatic(request, {stored:2,pendingEdits:0})
      else if (method === "local.watch" || method === "local.overview" || method === "local.refresh")
        fixture.automatic(request, {coverage:{stored:2,pendingEdits:0},summaries:[],labels:[],unread:0})
      else if (method === "gmail.profile") fixture.automatic(request, {email:"search@example.test"})
      else if (method === "auth.token") fixture.automatic(request, {access_token:"synthetic-access",expires_in:3600})
      else if (method === "gmail.sendAs" || method === "gmail.labels" || method === "local.edits") fixture.automatic(request, [])
      else if (method === "model.apply") {
        var summaries = parameters.args && parameters.args.length ? parameters.args[0] : []
        fixture.automatic(request, {summaries:summaries,visible:summaries,live:summaries})
      } else fixture.automatic(request, {})
      return request
    }
  }
  Component {
    id: accountFactory
    Account.MailAccount {
      pluginDir: "/synthetic/search"
      backend: transport
      accountId: "search@example.test"
      configuredEmail: "search@example.test"
    }
  }
  Components.SearchBar {
    id: searchBar
    width: 500
    textColor: Commons.Color.foreground
    accentColor: Commons.Color.accent
    dimColor: Commons.Color.foreground
    popupBackgroundColor: Commons.Color.background
    popupBorderColor: Commons.Color.foreground
    panelFontFamily: "Sans"
    onSubmitted: function(query) { if (testCase.account) testCase.account.search(query) }
    onCleared: if (testCase.account) testCase.account.search("")
  }
  SignalSpy { id: rowsChanged; target:testCase.account; signalName:"messagesChanged" }
  TestCase {
    id: testCase
    name: "SubmittedSearch"
    when: windowShown
    property var account: null
    function init() {
      failOnWarning(/TypeError|ReferenceError|invalid context/)
      fixture.capture = false
      fixture.deferPreparation = false
      fixture.requests = []
      fixture.saved = ({})
      fixture.pendingRows = []
      transport.ready = false
      account = accountFactory.createObject(fixture)
      verify(account !== null)
      account.profile = {email:"search@example.test"}
      account.sendAsLoaded = true
      account.auth.credentials = {clientId:"synthetic.apps.googleusercontent.com",clientSecret:"synthetic-secret"}
      account.auth.loggedIn = true
      transport.ready = true
      tryVerify(function() { return !!account.api && account.ready }, 1000)
      account.active = true
      account.windowOpen = true
      wait(50)
      account.auth.loggedIn = true
      wait(0)
      account.messages = []
      fixture.requests = []
      fixture.capture = true
      searchBar.setQuery("")
    }
    function cleanup() {
      fixture.capture = false
      if (account) account.destroy()
      wait(0)
      account = null
      transport.ready = false
    }
    function submitted(query, localRows, cursor) {
      account.search(query)
      function pending(method) {
        var requests=fixture.calls(method).filter(function(request) {
          return request.params.query === query && !request.settled && !request.withdrawn
        })
        return requests.length ? requests[requests.length-1] : null
      }
      tryVerify(function() { return !!pending("local.list") }, 1000)
      fixture.answer(pending("local.list"), {summaries:localRows || [],nextPageToken:cursor || "",coverage:{stored:2}})
      tryVerify(function() { return !!pending("gmail.list") }, 1000)
      return pending("gmail.list")
    }
    function complete(request, ids, cursor) {
      fixture.answer(request, {ids:ids,nextPageToken:cursor || "",estimate:ids.length})
      tryCompare(account.submittedSearch, "phase", "complete", 1000)
      tryCompare(account.submittedSearch, "savedBusy", false, 1000)
    }
    function ids() { return account.messages.map(function(message) { return message.id }) }

    function test_typing_has_no_provider_request_and_submit_uses_saved_rows_first() {
      searchBar.focusField()
      var text="from:alice@example.test"
      for (var index=0;index<text.length;index++) keyClick(text[index])
      wait(50)
      compare(fixture.calls("gmail.list").length, 0)
      compare(fixture.calls("gmail.read").length, 0)
      compare(fixture.calls("providers.resolve").length, 0)
      keyClick(Qt.Key_Return)
      tryVerify(function() { return !!fixture.next("local.list") }, 1000)
      compare(fixture.calls("gmail.list").length, 0)
      fixture.answer(fixture.next("local.list"), {summaries:[fixture.row("saved")],nextPageToken:"",coverage:{stored:2}})
      compare(ids(), ["saved"])
      tryCompare(account.submittedSearch, "phase", "checking", 1000)
      compare(fixture.calls("gmail.list").length, 1)
    }
    function test_duplicate_submission_coalesces_local_and_remote_work() {
      var request = submitted("is:unread", [fixture.row("saved")])
      account.search("is:unread")
      account.search("is:unread")
      compare(fixture.calls("local.list").length, 1)
      compare(fixture.calls("gmail.list").length, 1)
      fixture.saved = {saved:fixture.row("saved")}
      complete(request,["saved"])
      account.search("is:unread")
      tryVerify(function() { return fixture.calls("local.list").length === 2 }, 1000)
    }
    function test_duplicate_submission_coalesces_preparation_and_stop_cancels_it() {
      fixture.deferPreparation=true
      account.search("is:read")
      account.search("is:read")
      compare(fixture.calls("providers.resolve").length,1)
      var request=fixture.next("providers.resolve")
      account.stopSearch()
      fixture.answer(request,{value:"is:read",search:{valid:true}})
      wait(20)
      compare(fixture.calls("local.list").length,0)
      compare(fixture.calls("gmail.list").length,0)
      compare(account.searchStatus.phase,"stopped")
    }
    function test_retry_after_stopping_initial_preparation_resubmits_requested_query() {
      fixture.deferPreparation=true
      account.search("is:read")
      var before=fixture.next("providers.resolve")
      account.stopSearch()
      account.retrySearch()
      compare(fixture.calls("providers.resolve").length,2)
      var latest=fixture.calls("providers.resolve")[1]
      compare(latest.params.search,"is:read")
      fixture.answer(before,{value:"is:read",search:{valid:true}})
      compare(fixture.calls("local.list").length,0)
      fixture.answer(latest,{value:"is:read",search:{valid:true}})
      compare(fixture.calls("local.list").length,1)
      compare(fixture.next("local.list").params.query,"is:read")
    }
    function test_retry_after_stopping_replacement_preparation_keeps_new_query() {
      fixture.saved={saved:fixture.row("saved")}
      complete(submitted("is:unread",[fixture.row("saved")]),["saved"])
      fixture.deferPreparation=true
      account.search("from:new")
      account.stopSearch()
      account.retrySearch()
      var latest=fixture.calls("providers.resolve").slice(-1)[0]
      compare(latest.params.search,"from:new")
      fixture.answer(latest,{value:"from:new",search:{valid:true}})
      compare(fixture.next("local.list").params.query,"from:new")
    }
    function test_clear_or_same_mailbox_navigation_during_preparation_cancels_search() {
      for (var index=0;index<2;index++) {
        fixture.deferPreparation=true
        account.search("is:read")
        var request=fixture.next("providers.resolve")
        if (index === 0) account.search("")
        else account.selectMailbox(account.mailboxKey)
        fixture.answer(request,{value:"is:read",search:{valid:true}})
        wait(20)
        compare(account.submittedSearch.phase,"")
        compare(account.submittedSearch.active,false)
        compare(account.searchQuery,"")
        compare(fixture.calls("gmail.list").length,0)
      }
    }
    function test_unsupported_local_query_continues_to_gmail_once() {
      account.search("list:team@example.test")
      tryVerify(function() { return !!fixture.next("local.list") },1000)
      fixture.answer(fixture.next("local.list"),null,{message:"local_search_unsupported"})
      tryVerify(function() { return !!fixture.next("gmail.list") },1000)
      compare(fixture.next("gmail.list").params.query,"list:team@example.test")
      compare(account.searchStatus.text,"Checking Gmail…")
      compare(fixture.calls("gmail.list").length,1)
    }
    function test_cached_confirmed_ids_do_not_fetch_metadata_and_missing_ids_do() {
      fixture.saved = {cached:fixture.row("cached")}
      var request = submitted("subject:invoice", [fixture.row("provisional")])
      fixture.answer(request,{ids:["cached","missing"],nextPageToken:"",estimate:2})
      tryVerify(function() { return !!fixture.next("gmail.read") }, 1000)
      compare(fixture.calls("gmail.read").length, 1)
      compare(fixture.next("gmail.read").params.id,"missing")
      compare(fixture.next("gmail.read").params.full,false)
      fixture.answer(fixture.next("gmail.read"),{id:"missing",payload:{headers:[]}})
      tryCompare(account.submittedSearch,"phase","complete",1000)
      compare(ids().sort(),["cached","missing"])
      compare(fixture.calls("gmail.list").length,1)
    }
    function test_saved_changes_and_reopening_do_not_repeat_gmail_search() {
      fixture.saved = {saved:fixture.row("saved")}
      complete(submitted("is:unread",[fixture.row("saved")]),["saved"])
      transport.notification("local.changed",{accountId:account.accountId,status:{stored:3,pendingEdits:0},changed:true})
      wait(200)
      account.windowOpen = false
      account.windowOpen = true
      account.loadMessages(false,true)
      wait(50)
      compare(fixture.calls("gmail.list").length,1)
      compare(fixture.calls("gmail.read").length,0)
      verify(fixture.calls("local.summaries").length > 1)
    }
    function test_hiding_completed_account_preserves_completion_and_server_cursor() {
      fixture.saved={saved:fixture.row("saved")}
      complete(submitted("is:unread",[fixture.row("saved")]),["saved"],"server-next")
      account.active=false
      compare(account.searchStatus.phase,"complete")
      compare(account.nextPageToken,"server-next")
      account.active=true
      wait(20)
      compare(account.searchStatus.phase,"complete")
      compare(account.nextPageToken,"server-next")
      compare(fixture.calls("gmail.list").length,1)
    }
    function test_unchanged_saved_rows_do_not_replace_the_visible_model() {
      fixture.saved={saved:fixture.row("saved")}
      complete(submitted("is:unread",[fixture.row("saved")]),["saved"])
      fixture.saved={saved:fixture.row("saved")}
      rowsChanged.clear()
      account.submittedSearch.refreshSaved()
      tryCompare(account.submittedSearch,"savedBusy",false,1000)
      compare(rowsChanged.count,0)
      compare(fixture.calls("gmail.list").length,1)
    }
    function test_empty_gmail_result_clears_provisional_rows() {
      var request = submitted("subject:missing",[fixture.row("obsolete")])
      compare(ids(),["obsolete"])
      complete(request,[])
      compare(ids(),[])
      compare(account.resultEstimate,0)
    }
    function test_failure_keeps_saved_rows_and_reason_and_retry_is_explicit() {
      var request = submitted("is:unread",[fixture.row("saved")],"local-next")
      fixture.answer(request,null,{message:"gmail_request_deferred"})
      tryCompare(account.submittedSearch,"phase","failed",1000)
      compare(ids(),["saved"])
      compare(account.searchStatus.errorCode,"gmail_request_deferred")
      verify(account.searchStatus.error.indexOf("Magpie") >= 0)
      compare(account.nextPageToken,"local-next")
      wait(50)
      compare(fixture.calls("gmail.list").length,1)
      account.retrySearch()
      compare(fixture.calls("gmail.list").length,2)
      compare(fixture.next("gmail.list").params.pageToken,"")
    }
    function test_stop_preserves_rows_and_late_results_cannot_fetch_or_paint() {
      var request = submitted("is:unread",[fixture.row("saved")])
      account.stopSearch()
      compare(account.submittedSearch.phase,"stopped")
      fixture.answer(request,{ids:["forbidden-late"],nextPageToken:"",estimate:1})
      wait(20)
      compare(ids(),["saved"])
      compare(fixture.calls("gmail.read").length,0)
      compare(fixture.calls("local.summaries").length,0)
    }
    function test_logout_with_saved_mail_stops_active_search() {
      var request=submitted("is:unread",[fixture.row("saved")])
      account.auth.loggedIn=false
      tryCompare(account.submittedSearch,"phase","stopped",1000)
      fixture.answer(request,{ids:["after-logout"],nextPageToken:"",estimate:1})
      wait(20)
      compare(ids(),["saved"])
      compare(fixture.calls("gmail.read").length,0)
      compare(account.listLoading,false)
    }
    function test_backend_restart_stops_search_and_discards_late_response() {
      var request=submitted("is:unread",[fixture.row("saved")])
      transport.ready=false
      compare(account.submittedSearch.phase,"stopped")
      fixture.answer(request,{ids:["after-restart"],nextPageToken:"",estimate:1})
      wait(20)
      compare(ids(),["saved"])
      compare(fixture.calls("gmail.read").length,0)
      compare(account.listLoading,false)
    }
    function test_stop_withdraws_unsent_saved_search() {
      account.search("is:unread")
      tryVerify(function() { return !!fixture.next("local.list") },1000)
      var request=fixture.next("local.list")
      request.unsent=true
      account.stopSearch()
      compare(request.withdrawn,true)
      compare(account.listLoading,false)
      compare(fixture.calls("gmail.list").length,0)
    }
    function test_replacement_query_discards_old_local_and_remote_callbacks() {
      account.search("from:old")
      tryVerify(function() { return !!fixture.next("local.list") },1000)
      var oldLocal=fixture.next("local.list")
      var fresh=submitted("from:new",[fixture.row("new")])
      fixture.answer(oldLocal,{summaries:[fixture.row("old")],nextPageToken:"",coverage:{stored:2}})
      compare(fixture.calls("gmail.list").length,1)
      compare(fresh.params.query,"from:new")
      var oldRemote=fresh
      var newest=submitted("from:newest",[fixture.row("newest")])
      fixture.answer(oldRemote,{ids:["late"],nextPageToken:"",estimate:1})
      wait(20)
      compare(ids(),["newest"])
      compare(fixture.calls("gmail.read").length,0)
      compare(newest.params.query,"from:newest")
    }
    function test_account_switch_cancels_result_ownership() {
      var request=submitted("from:alice",[fixture.row("saved")])
      account.accountId="another@example.test"
      fixture.answer(request,{ids:["foreign"],nextPageToken:"",estimate:1})
      wait(20)
      compare(account.submittedSearch.active,false)
      compare(fixture.calls("gmail.read").length,0)
      verify(ids().indexOf("foreign") < 0)
    }
    function test_destroyed_account_discards_saved_completion_without_follow_on_requests() {
      account.search("is:unread")
      tryVerify(function() { return !!fixture.next("local.list") },1000)
      var request=fixture.next("local.list")
      account.destroy()
      wait(0)
      account=null
      fixture.answer(request,{summaries:[fixture.row("late")],nextPageToken:"",coverage:{stored:2}})
      wait(20)
      compare(fixture.calls("gmail.list").length,0)
    }
    function test_destroyed_account_discards_gmail_completion_without_metadata_reads() {
      var request=submitted("is:unread",[fixture.row("saved")])
      account.destroy()
      wait(0)
      account=null
      fixture.answer(request,{ids:["late"],nextPageToken:"",estimate:1})
      wait(20)
      compare(fixture.calls("gmail.read").length,0)
      compare(fixture.calls("local.summaries").length,0)
    }
    function test_pending_edit_survives_server_membership_and_acknowledgement() {
      var local=fixture.row("edited",{pendingEdit:true,matchesQuery:true})
      fixture.saved={edited:local}
      fixture.pendingRows=[local]
      complete(submitted("is:unread",[local]),[])
      compare(ids(),["edited"])
      compare(account.searchStatus.pendingCount,1)
      fixture.saved={edited:fixture.row("edited")}
      fixture.pendingRows=[]
      account.submittedSearch.refreshSaved()
      tryCompare(account.submittedSearch,"savedBusy",false,1000)
      compare(ids(),["edited"])
      compare(account.searchStatus.pendingCount,0)
      compare(fixture.calls("gmail.list").length,1)
    }
    function test_unknown_pending_preview_cannot_survive_empty_gmail_membership() {
      var local=fixture.row("incomplete",{pendingEdit:true,matchesQuery:null,pendingLabelMatch:null,
        labelIds:["INBOX","STARRED"]})
      fixture.saved={incomplete:local}
      fixture.pendingRows=[local]
      var request=submitted("-needle is:starred",[local])
      compare(ids(),["incomplete"])
      complete(request,[])
      compare(ids(),[])
      compare(account.resultEstimate,0)
      fixture.saved={incomplete:fixture.row("incomplete",{matchesQuery:null,pendingLabelMatch:null,
        labelIds:["INBOX","STARRED"]})}
      fixture.pendingRows=[]
      account.submittedSearch.refreshSaved()
      tryCompare(account.submittedSearch,"savedBusy",false,1000)
      compare(ids(),[])
      compare(account.searchStatus.pendingCount,0)
      compare(fixture.calls("gmail.list").length,1)
      compare(fixture.calls("gmail.read").length,0)
    }
    function test_unknown_pending_membership_preserves_a_gmail_confirmed_row() {
      var local=fixture.row("confirmed",{pendingEdit:true,matchesQuery:null,pendingLabelMatch:null,
        labelIds:["INBOX","STARRED"]})
      fixture.saved={confirmed:local}
      fixture.pendingRows=[local]
      complete(submitted("-needle is:starred",[local]),["confirmed"])
      compare(ids(),["confirmed"])
      fixture.saved={confirmed:fixture.row("confirmed",{matchesQuery:null,pendingLabelMatch:null,
        labelIds:["INBOX","STARRED"]})}
      fixture.pendingRows=[]
      account.submittedSearch.refreshSaved()
      tryCompare(account.submittedSearch,"savedBusy",false,1000)
      compare(ids(),["confirmed"])
      compare(account.searchStatus.pendingCount,0)
      compare(fixture.calls("gmail.list").length,1)
      compare(fixture.calls("gmail.read").length,0)
    }
    function test_pending_label_change_hides_stale_gmail_member() {
      var local=fixture.row("read-now",{pendingEdit:true,matchesQuery:false,pendingLabelMatch:false,
        unread:false,labelIds:["INBOX"]})
      fixture.saved={"read-now":local}
      fixture.pendingRows=[local]
      complete(submitted("is:unread",[]),["read-now"])
      compare(ids(),[])
      compare(account.searchStatus.pendingCount,1)
      compare(fixture.calls("gmail.read").length,0)
    }
    function test_partial_metadata_failure_keeps_rows_and_never_claims_completion() {
      fixture.saved={cached:fixture.row("cached")}
      var request=submitted("subject:invoice",[fixture.row("saved")])
      fixture.answer(request,{ids:["cached","missing"],nextPageToken:"server-next",estimate:2})
      tryVerify(function() { return !!fixture.next("gmail.read") },1000)
      fixture.answer(fixture.next("gmail.read"),null,{message:"gmail_timeout"})
      tryCompare(account.submittedSearch,"phase","failed",1000)
      compare(ids().sort(),["cached","saved"])
      compare(account.nextPageToken,"")
      compare(account.searchStatus.errorCode,"gmail_timeout")
      compare(account.searchStatus.canRetry,true)
    }
    function test_server_settlement_preserves_surviving_reader_selection() {
      fixture.saved={selected:fixture.row("selected")}
      var request=submitted("from:alice",[fixture.row("selected"),fixture.row("obsolete")])
      account.selectedId="selected"
      account.selectedMessage={id:"selected",subject:"Open reader"}
      complete(request,["selected"])
      compare(account.selectedId,"selected")
      compare(account.selectedMessage.subject,"Open reader")
      compare(ids(),["selected"])
    }
    function test_failed_search_uses_local_cursor_and_complete_search_uses_server_cursor() {
      var request=submitted("newer_than:7d",[fixture.row("saved")],"saved-cursor")
      var asOf=fixture.calls("local.list")[0].params.asOf
      fixture.answer(request,null,{message:"gmail_timeout"})
      account.submittedSearch.loadMore()
      var local=fixture.next("local.list")
      verify(local)
      compare(local.params.pageToken,"saved-cursor")
      compare(local.params.asOf,asOf)
      fixture.answer(local,{summaries:[fixture.row("saved2")],nextPageToken:"",coverage:{stored:3}})
      compare(fixture.calls("gmail.list").length,1)
      account.retrySearch()
      complete(fixture.next("gmail.list"),[],"gmail-cursor")
      account.submittedSearch.loadMore()
      compare(fixture.next("gmail.list").params.pageToken,"gmail-cursor")
      compare(fixture.calls("local.list").length,2)
    }
  }
}

import QtQuick
import QtTest
import "../../providers" as Providers
import "transports.js" as Transports

Item {
  Component {
    id: fixture
    Item {
      property alias api: client
      QtObject {
        id: auth
        property string accountId: "jmap:ada@example.org"
        property bool loggedIn: false
        property var settings: ({sessionUrl:"https://example.org/session",username:"ada"})
        signal verifyRequested(var settings, string address, string secret)
        signal loggedOut()
      }
      Providers.JmapClient { id: client; auth: auth }
    }
  }
  TestCase {
    when: windowShown
    function setup() {
      var scenario = createTemporaryObject(fixture, this)
      Transports.install(scenario.api)
      return scenario
    }
    name: "JmapFailureRecovery"
    // Import, submission, cleanup and 404 retry ordering are native Rust
    // workflow tests. UI must preserve payload identity, propagate failure
    // once, and never compensate by issuing another mutation itself.
    function test_failed_draft_save_keeps_original_id_and_never_retries_or_destroys() {
      var scenario = setup()
      var answers = 0
      var error = ""
      var payload = {draftId:"original",raw:"U3ViamVjdDogeA0KDQpib2R5"}
      scenario.api.saveDraft(payload,function(result,failure) { answers++; error=failure; compare(result,null) })
      var request = Transports.transports(scenario.api)[0]
      compare(request.method, "jmap.saveDraft")
      compare(request.params.draftId,"original")
      compare(request.params.raw,payload.raw)
      Transports.reply(request,null,{message:"jmap_import_failed"})
      compare(answers,1)
      verify(error.length > 0)
      compare(Transports.transports(scenario.api).length,1)
      compare(payload.draftId,"original")
    }
    function test_unconfirmed_send_is_reported_without_retry() {
      var scenario = setup()
      var error = ""
      scenario.api.sendMessage({draftId:"original",raw:"U3ViamVjdDogeA0KDQpib2R5"},function(result,failure) { error=failure })
      var request=Transports.transports(scenario.api)[0]
      compare(request.method,"jmap.send")
      compare(request.params.draftId,"original")
      Transports.reply(request,null,{message:"jmap_submission_unconfirmed"})
      compare(error,"The server did not confirm sending. Check Sent before trying again")
      compare(Transports.transports(scenario.api).length,1)
    }
    function test_confirmed_save_preserves_backend_warning_and_identity() {
      var scenario = setup()
      var answer = null
      scenario.api.saveDraft({draftId:"old",raw:"eA"},function(result,error) {compare(error,"");answer=result})
      Transports.complete(Transports.transports(scenario.api)[0], {id:"new",warning:"Original draft could not be removed"})
      compare(answer.id,"new")
      verify(answer.warning.length > 0)
      compare(Transports.transports(scenario.api).length,1)
    }
    function test_stale_verification_cannot_restore_a_changed_account() {
      var scenario=setup()
      var answered=false
      scenario.api.verifyCredentials({},"ada@example.org","synthetic-secret",function(){answered=true})
      var request=Transports.transports(scenario.api)[0]
      scenario.api.forgetServer()
      Transports.reply(request,{session:{state:"old"},mailboxes:[],sessionUrl:"https://old.example.org/session",accountId:"old"},"")
      compare(scenario.api.session,null)
      compare(scenario.api.mailboxList.length,0)
      compare(answered,false)
    }
    function test_failed_discovery_never_replaces_session_or_starts_followup() {
      var scenario=setup()
      scenario.api.session={state:"original"}
      var failure=""
      scenario.api.verifyCredentials({},"ada@example.org","synthetic-secret",function(result,error){failure=error})
      var request=Transports.transports(scenario.api)[0]
      compare(request.method,"jmap.verify")
      compare(request.params.address,"ada@example.org")
      Transports.reply(request,null,{message:"jmap_discovery_failed"})
      compare(scenario.api.session.state,"original")
      verify(failure.length>0)
      compare(scenario.api.credentialsRejected,false)
      compare(Transports.transports(scenario.api).length,1)
    }
  }
}

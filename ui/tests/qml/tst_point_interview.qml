import QtQuick
import QtTest
import "../../components" as Mail
Item {
  width: 640; height: 800
  Component { id: backendFactory; QtObject {
    property bool ready: true
    property int apiVersion: 8
    property var calls: []
    function call(method, params, done) { calls = calls.concat([{method:method,params:params,done:done}]) }
  } }
  Component { id: serviceFactory; QtObject { property var backend: null } }
  Component { id: panelFactory; Mail.PointInterview {
    width: 380; textColor: palette.windowText; dimColor: palette.placeholderText; accentColor: palette.highlight; panelFontFamily: "sans-serif"
  } }
  TestCase {
    name: "PointInterview"; when: windowShown
    property var backend; property var panel
    function init() {
      backend = createTemporaryObject(backendFactory, parent)
      var service = createTemporaryObject(serviceFactory, parent, {backend:backend})
      panel = createTemporaryObject(panelFactory, parent, {service:service})
      verify(panel)
      panel.begin("Sam lives in Cork.")
    }
    function child(name) { return findChild(panel, "interview-" + name) }
    function calls(method) { return backend.calls.filter(function(c) { return c.method === method }) }
    function last() { var c=calls("inbox.interview"); return c[c.length-1] }
    function start() { child("start").clicked(); last().done({question:"Who lives with you?",draft:"",completed:0,total:6},null) }
    function test_start_needs_consent_and_a_response_is_not_a_save() {
      compare(calls("inbox.interview").length,0)
      start()
      child("answer").text="Alex"
      child("draft").clicked()
      compare(last().params.answers,[{question:"Who lives with you?",answer:"Alex"}])
      last().done({question:"",draft:"Sam lives with Alex.",completed:1,total:6},null)
      compare(panel.phase,"review")
      compare(calls("inbox.aboutYou").filter(function(c){return c.params.text !== undefined}).length,0)
      child("bio").text="Sam lives with Alex in Cork."
      child("save").clicked()
      var writes=calls("inbox.aboutYou").filter(function(c){return c.params.text !== undefined})
      compare(writes.length,1)
      compare(writes[0].params.text,"Sam lives with Alex in Cork.")
      child("save").clicked()
      compare(calls("inbox.aboutYou").filter(function(c){return c.params.text !== undefined}).length,1)
      writes[0].done({text:"Sam lives with Alex in Cork.",updated:1,limit:2000},null)
      verify(!panel.active)
    }
    function test_failure_keeps_answers_and_retry_does_not_duplicate() {
      start(); child("answer").text="Alex"; child("next").clicked()
      last().done(null,{message:"overview_ai_unavailable"})
      compare(child("answer").text,"Alex"); compare(panel.answers.length,0)
      verify(child("status").text.indexOf("still here")>=0)
      child("next").clicked(); compare(last().params.answers.length,1)
      last().done({question:"What is your work situation?",draft:"",completed:1,total:6},null)
      compare(panel.answers.length,1); compare(child("answer").text,"")
    }
    function test_cancel_ignores_a_late_answer_and_writes_no_bio() {
      start(); child("answer").text="Alex"; child("draft").clicked()
      var request=last(); child("cancel").clicked()
      request.done({question:"",draft:"Unapproved text",completed:1,total:6},null)
      verify(!panel.active); compare(child("bio").text,"")
      compare(calls("inbox.aboutYou").filter(function(c){return c.params.text !== undefined}).length,0)
    }
    function test_skip_sends_no_typed_answer_and_untrusted_output_is_plain() {
      start(); child("answer").text="Not shared"; child("skip").clicked()
      compare(last().params.answers[0].answer,"")
      last().done({question:"<img src='https://example.test'>",draft:"",completed:1,total:6},null)
      compare(panel.answers.length,0); compare(child("answer").text,"Not shared")
      compare(child("question").textFormat,Text.PlainText)
    }
    function test_skipped_answers_do_not_offer_an_empty_draft() {
      panel.begin(""); start(); child("skip").clicked()
      last().done({question:"What is your work situation?",draft:"",completed:1,total:6},null)
      verify(!child("draft").visible)
      child("answer").text="I teach."
      verify(child("draft").visible)
    }
    function test_keyboard_and_narrow_layout() {
      panel.width=300; start()
      child("answer").forceActiveFocus(); keyClick(Qt.Key_Tab)
      verify(!child("answer").activeFocus)
      wait(20)
      for (var name of ["question","answer","skip","cancel"]) {
        var item=child(name); verify(item.width<=panel.width, name + " fits")
      }
    }
  }
}

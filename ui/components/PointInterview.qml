import QtQuick
import QtQuick.Controls as QQC
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Column {
  id: root
  required property var service
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily
  property string about: ""
  property bool active: false
  property string phase: "consent"
  property string question: ""
  property var answers: []
  property bool busy: false
  property string error: ""
  property int generation: 0
  signal saved(var page)
  signal closed()
  visible: active
  spacing: MailStyle.space(12)

  function begin(text) {
    generation++
    about = text
    answers = []
    question = ""
    response.text = ""
    bio.text = ""
    phase = "consent"
    error = ""
    busy = false
    active = true
    if (service && service.backend) service.backend.call("inbox.aboutYou", {interviewOffered: true}, function() {})
  }
  function close() {
    generation++
    active = false
    busy = false
    response.text = ""
    bio.text = ""
    answers = []
    about = ""
    closed()
  }
  function safe(text, limit) {
    return typeof text === "string" && Array.from(text).length <= limit
      && !/[<>\x00-\x08\x0b-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/.test(text)
  }
  function problem(failure) {
    var code = String(failure && failure.message || "")
    if (code === "overview_ai_paused") return "Every Claude subscription is out for now. Your answers are still here; try again later."
    if (code === "interview_busy") return "The previous answer is still finishing. Try again in a moment."
    if (code === "interview_no_answers") return "Add one detail about yourself before asking for a bio."
    if (code === "interview_invalid_response") return "Claude’s answer could not be used. Your answers are still here; try again."
    return "Claude could not answer. Your answers are still here; try again."
  }
  function ask(skip, draft) {
    if (busy || !active || !service || !service.backend || service.backend.apiVersion < 8) return
    var next = answers.slice()
    if (phase === "questions") {
      var typed = skip ? "" : response.text.trim()
      if (!safe(typed, 1200)) { error = "Use plain text, up to 1,200 characters, without < or >."; return }
      if (!skip && !draft && typed === "") return
      if (!draft || typed !== "") next.push({question: question, answer: typed})
    }
    busy = true
    error = ""
    var ticket = ++generation
    service.backend.call("inbox.interview", {about: about, answers: next, draft: draft}, function(result, failure) {
      if (ticket !== root.generation || !root.active) return
      root.busy = false
      if (failure || !result) { root.error = root.problem(failure); return }
      var drafting = typeof result.draft === "string" && result.draft !== ""
      var value = drafting ? result.draft : result.question
      if (typeof result.question !== "string" || typeof result.draft !== "string"
          || (result.question !== "") === (result.draft !== "")
          || !root.safe(value, drafting ? 2000 : 300) || value.trim() === ""
          || Number(result.completed) !== next.length || Number(result.total) !== 6) {
        root.error = "Claude’s answer could not be used. Your answers are still here; try again."
        return
      }
      root.answers = next
      root.responseText("")
      root.phase = drafting ? "review" : "questions"
      if (drafting) { bio.text = value; bio.forceActiveFocus() }
      else { root.question = value; response.forceActiveFocus() }
    })
  }
  function responseText(text) { response.text = text }
  function save() {
    if (busy || phase !== "review" || !active) return
    var text = bio.text.trim()
    if (!safe(text, 2000) || text === "") { error = "Use plain text, up to 2,000 characters, without < or >."; return }
    busy = true
    error = ""
    var ticket = ++generation
    service.backend.call("inbox.aboutYou", {text: text}, function(result, failure) {
      if (ticket !== root.generation || !root.active) return
      root.busy = false
      if (failure || !result) { root.error = "Your bio could not be saved. It is still here; try again."; return }
      root.saved(result)
      root.close()
    })
  }
  onVisibleChanged: if (!visible && active) close()

  Text {
    width: parent.width
    text: root.phase === "review" ? "Review your bio" : "Magpie interviews you"
    textFormat: Text.PlainText
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.body
  }
  Text {
    width: parent.width
    text: root.phase === "consent"
      ? "Answer a few questions so Magpie can understand what your mail means for you. Your answers and your current bio go to Claude, Anthropic’s AI. Skip anything you prefer. You will edit the draft before saving it."
      : root.phase === "review" ? "Check and edit this before saving. Only the bio you save is used with your mail."
      : "Question " + (root.answers.length + 1) + " of 6 · Every answer is optional."
    textFormat: Text.PlainText
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }
  Text {
    objectName: "interview-question"
    width: parent.width
    visible: root.phase === "questions"
    text: root.question
    textFormat: Text.PlainText
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    wrapMode: Text.WordWrap
  }
  component AnswerField: QQC.TextArea {
    width: root.width
    textFormat: TextEdit.PlainText
    wrapMode: TextEdit.Wrap
    enabled: !root.busy
    selectByMouse: true
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    padding: MailStyle.space(8)
    height: Math.max(implicitHeight, MailStyle.space(96))
    placeholderTextColor: root.dimColor
    background: BorderSurface {
      color: Style.controlFill(parent.activeFocus, parent.hovered, root.textColor, root.accentColor)
      borderSpec: Border.controlSpec(parent.activeFocus ? "focus" : "normal", root.textColor, root.accentColor)
      radius: Style.cornerRadius
    }
    Keys.onTabPressed: function(event) { var next = nextItemInFocusChain(true); if (next) next.forceActiveFocus(Qt.TabFocusReason); event.accepted = true }
    Keys.onBacktabPressed: function(event) { var next = nextItemInFocusChain(false); if (next) next.forceActiveFocus(Qt.BacktabFocusReason); event.accepted = true }
  }
  AnswerField {
    id: response
    objectName: "interview-answer"
    visible: root.phase === "questions"
    placeholderText: "Your answer"
    Accessible.name: "Your answer"
  }
  AnswerField {
    id: bio
    objectName: "interview-bio"
    visible: root.phase === "review"
    Accessible.name: "Review your bio"
  }
  Text {
    objectName: "interview-status"
    width: parent.width
    visible: text !== ""
    text: root.error || (root.busy ? (root.phase === "review" ? "Saving" : "Claude is thinking") : "")
    textFormat: Text.PlainText
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }
  Flow {
    width: parent.width
    spacing: MailStyle.space(8)
    component Action: Widgets.Button {
      foreground: root.textColor
      fontFamily: root.panelFontFamily
      fontSize: MailStyle.caption
      maximumWidth: root.width
      focusable: true
      bordered: true
      enabled: !root.busy
    }
    Action { objectName: "interview-start"; visible: root.phase === "consent"; text: "Start interview"; onClicked: root.ask(false, false) }
    Action { objectName: "interview-next"; visible: root.phase === "questions"; text: root.answers.length === 5 ? "Draft my bio" : "Continue"; enabled: !root.busy && response.text.trim() !== ""; onClicked: root.ask(false, false) }
    Action { objectName: "interview-skip"; visible: root.phase === "questions"; text: "Skip"; onClicked: root.ask(true, false) }
    Action { objectName: "interview-draft"; visible: root.phase === "questions" && (root.answers.some(function(a) { return a.answer.trim() !== "" }) || response.text.trim() !== "" || root.about !== ""); text: "Draft my bio now"; onClicked: root.ask(false, true) }
    Action { objectName: "interview-save"; visible: root.phase === "review"; text: "Save bio"; onClicked: root.save() }
    Action { objectName: "interview-cancel"; text: root.phase === "consent" ? "Not now" : "Cancel"; enabled: !(root.busy && root.phase === "review"); onClicked: root.close() }
  }
}

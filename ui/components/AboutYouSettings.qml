import QtQuick
import QtQuick.Controls as QQC
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Settings → About you: the owner's own description of themselves, which The Point reads each
// email against.
// Invariant: the engine keeps the text on this computer and refuses markup, controls and invisible
// characters; the field explains a refusal in place and never saves part of the text.
Column {
  id: root
  required property var service
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily
  property var saved: null
  property string error: ""
  property bool busy: false
  property bool justSaved: false
  readonly property bool ready: !!service && !!service.backend && service.backend.ready === true
    && Number(service.backend.apiVersion) >= 8
  readonly property int limit: saved && Number(saved.limit) > 0 ? Number(saved.limit) : 2000
  readonly property int length: Array.from(field.text.trim()).length
  readonly property bool changed: saved !== null && field.text.trim() !== String(saved.text || "")
  visible: saved !== null
  spacing: MailStyle.space(6)

  function load() {
    if (!ready) return
    service.backend.call("inbox.aboutYou", {}, function(result, failure) {
      if (!failure && result) {
        // Text being edited is kept; otherwise the field shows what is saved now.
        var edited = field.text.trim() !== (root.saved === null ? "" : String(root.saved.text || ""))
        root.saved = result
        root.error = ""
        if (!edited) field.text = String(result.text || "")
        return
      }
      if (failure && (failure.code === -32012 || failure.code === -32601)) { root.saved = null; return }
      if (root.saved === null) root.saved = ({text: "", updated: 0, limit: 2000})
      root.error = "What you wrote here could not be read. Open Settings again to try again."
    })
  }
  function problem(text) {
    if (Array.from(text).length > limit) return "Keep it to " + limit + " characters or fewer."
    if (/[<>]/.test(text)) return "Leave out the < and > characters."
    if (/[\x00-\x08\x0b-\x1f\x7f-\x9f​-‏‪-‮⁠-⁯﻿]/.test(text))
      return "Leave out invisible characters, such as those pasted from a web page."
    return ""
  }
  function save() {
    if (!ready || busy || !changed) return
    var text = field.text.trim()
    var reason = problem(text)
    error = reason
    if (reason !== "") return
    busy = true
    service.backend.call("inbox.aboutYou", {text: text}, function(result, failure) {
      root.busy = false
      if (failure || !result) { root.error = "This could not be saved. Try again."; return }
      root.saved = result
      root.justSaved = true
    })
  }
  onReadyChanged: load()
  Component.onCompleted: load()

  Text {
    width: parent.width
    text: "ABOUT YOU"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }
  QQC.TextArea {
    id: field
    objectName: "settings-about-you"
    readonly property var borderSpec: Border.controlSpec(activeFocus ? "focus" : (hovered ? "hover-cursor" : "normal"), root.textColor, root.accentColor)
    width: parent.width
    height: Math.max(implicitHeight, MailStyle.space(96))
    textFormat: TextEdit.PlainText
    wrapMode: TextEdit.Wrap
    enabled: root.ready && !root.busy
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    placeholderText: "Your name, where you live, who you live with, your work, and what is going on in your life now"
    placeholderTextColor: MailStyle.muted(root.textColor, Commons.Color.background)
    selectionColor: Style.selectionFillFor(root.textColor, root.accentColor)
    selectedTextColor: root.textColor
    selectByMouse: true
    padding: MailStyle.space(8)
    Accessible.name: "About you"
    Accessible.description: caption.text
    background: BorderSurface {
      color: Style.controlFill(field.activeFocus, field.hovered, root.textColor, root.accentColor)
      borderSpec: field.borderSpec
      radius: Style.cornerRadius
    }
    // Tab moves on instead of typing a tab, so the keyboard can leave the field.
    Keys.onTabPressed: function(event) {
      var next = field.nextItemInFocusChain(true)
      if (next) next.forceActiveFocus(Qt.TabFocusReason)
      event.accepted = true
    }
    Keys.onBacktabPressed: function(event) {
      var previous = field.nextItemInFocusChain(false)
      if (previous) previous.forceActiveFocus(Qt.BacktabFocusReason)
      event.accepted = true
    }
    onTextChanged: { root.justSaved = false; if (root.error !== "" && root.problem(text.trim()) === "") root.error = "" }
    onActiveFocusChanged: if (!activeFocus) root.save()
  }
  Text {
    id: caption
    objectName: "settings-about-you-status"
    width: parent.width
    textFormat: Text.PlainText
    text: root.error !== "" ? root.error
      : root.busy ? "Saving"
      : root.justSaved ? "Saved."
      : "Magpie reads each email against this to tell you what it means for you. It stays on this computer and goes to Claude with the mail it reads."
        + (root.length > root.limit * 0.9 ? " " + root.length + " of " + root.limit + " characters." : "")
    color: root.error !== "" ? root.accentColor : root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }
  Widgets.Button {
    objectName: "settings-about-you-save"
    visible: root.changed
    text: "Save"
    enabled: root.ready && !root.busy
    foreground: root.textColor
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.caption
    onClicked: root.save()
  }
}

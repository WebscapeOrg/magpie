import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui

// Settings → Calendar: whether The Point may read each Google account's calendar.
// Invariant: Magpie only reads the calendar (calendar.readonly). Allowing it signs the account in
// again so Google adds that permission, then asks the engine to read the calendar at once.
Column {
  id: root
  required property var service
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily
  property var states: null
  property var notes: ({})
  property string asking: ""
  property string checking: ""
  readonly property bool ready: !!service && !!service.backend && service.backend.ready === true
    && Number(service.backend.apiVersion) >= 8
  readonly property var accounts: states ? Object.keys(states).sort() : []
  readonly property var askingAuth: {
    if (asking === "" || !service || typeof service.findAccount !== "function") return null
    var host = service.findAccount(asking)
    return host ? host.auth : null
  }
  visible: accounts.length > 0
  spacing: MailStyle.space(6)

  function load() {
    if (!ready) return
    service.backend.call("inbox.calendarAccess", {}, function(result, failure) {
      if (!failure && result && result.accounts) { root.states = result.accounts; return }
      if (failure && (failure.code === -32012 || failure.code === -32601)) root.states = null
    })
  }
  function note(account, text) {
    var next = Object.assign({}, notes)
    if (text === "") delete next[account]
    else next[account] = text
    notes = next
  }
  function allow(account) {
    if (asking !== "" || checking !== "" || !service || typeof service.findAccount !== "function") return
    var host = service.findAccount(account)
    if (!host || !host.auth) { note(account, "Sign in to this account first."); return }
    note(account, "")
    asking = account
    host.signIn()
    if (!host.auth.loginBusy) {
      asking = ""
      note(account, "Magpie Mail could not open Google sign-in. Try again.")
    }
  }
  function recheck(account) {
    checking = account
    service.backend.call("inbox.calendarAccess", {accountId: account}, function(result, failure) {
      root.checking = ""
      if (failure || !result || !result.accounts) {
        root.note(account, "Magpie Mail could not read this calendar. Try again in a few minutes.")
        return
      }
      root.states = result.accounts
      if (result.accounts[account] === "permission_required")
        root.note(account, "Google did not give Magpie Mail the calendar. Allow it again and leave the calendar ticked.")
    })
  }
  function status(account) {
    if (checking === account) return "Checking"
    if (asking === account) return "Finish allowing it in your browser."
    if (notes[account]) return notes[account]
    var state = states ? states[account] : ""
    if (state === "ready") return "Read for The Point."
    if (state === "permission_required") return "Not allowed yet."
    if (state === "unavailable") return "Could not be read just now. Magpie Mail tries again in a few minutes."
    return "Checking"
  }
  onReadyChanged: load()
  Component.onCompleted: load()

  Connections {
    target: root.askingAuth
    ignoreUnknownSignals: true
    function onLoginSucceeded() {
      var account = root.asking
      root.asking = ""
      root.recheck(account)
    }
    function onSessionUnavailable() {
      var account = root.asking
      root.asking = ""
      root.note(account, "Magpie Mail did not get the permission. Try again.")
    }
    function onLoginBusyChanged() {
      // A sign-in closed or timed out without an answer ends here; success and refusal end above.
      Qt.callLater(function() {
        if (root.asking !== "" && root.askingAuth && !root.askingAuth.loginBusy) {
          var account = root.asking
          root.asking = ""
          root.note(account, "Magpie Mail did not get the permission. Try again.")
        }
      })
    }
  }

  Text {
    width: parent.width
    text: "CALENDAR"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }
  Text {
    objectName: "settings-calendar-caption"
    width: parent.width
    textFormat: Text.PlainText
    text: "The Point reads your Google Calendar, from a week back to a month ahead, so it knows what you have planned. Magpie Mail never changes it, and the events go to Claude with the mail it reads."
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }
  Repeater {
    model: root.accounts
    delegate: Column {
      id: row
      required property string modelData
      objectName: "settings-calendar-" + modelData
      width: root.width
      spacing: MailStyle.space(4)
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: row.modelData
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        elide: Text.ElideMiddle
      }
      Text {
        objectName: "settings-calendar-status"
        width: parent.width
        textFormat: Text.PlainText
        text: root.status(row.modelData)
        color: root.notes[row.modelData] ? root.accentColor : root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }
      Widgets.Button {
        objectName: "settings-calendar-allow"
        visible: root.states && root.states[row.modelData] === "permission_required"
          && root.asking !== row.modelData && root.checking !== row.modelData
        text: "Allow"
        enabled: root.asking === "" && root.checking === ""
        foreground: root.textColor
        fontFamily: root.panelFontFamily
        fontSize: MailStyle.caption
        onClicked: root.allow(row.modelData)
      }
    }
  }
}

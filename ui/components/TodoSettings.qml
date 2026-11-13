import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui

// Settings → Todos: whether The Point reads the owner's todos from Atlas.
// Invariant: the link from Atlas carries a key that reads only the todo feed. It is sent once to the
// engine and cleared from the field, whatever the answer; it is never saved in settings or read back.
Column {
  id: root
  required property var service
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily
  property var connection: null
  property string error: ""
  property bool busy: false
  readonly property bool ready: !!service && !!service.backend && service.backend.ready === true
    && Number(service.backend.apiVersion) >= 8
  readonly property bool connected: !!connection && connection.connected === true
  readonly property bool needsLink: !connected || connection.state === "unauthorized"
  visible: connection !== null
  spacing: MailStyle.space(6)

  function problem(code) {
    if (code === "todos_link_invalid")
      return "That is not Atlas's link for Magpie. In Atlas, open Settings → Connections → Magpie and copy the link again."
    return "Magpie Mail could not reach Atlas just now. Try again in a few minutes."
  }
  function load() {
    if (!ready) return
    service.backend.call("inbox.todoConnection", {}, function(result, failure) {
      if (!failure && result) { root.connection = result; root.error = ""; return }
      if (failure && (failure.code === -32012 || failure.code === -32601)) { root.connection = null; return }
      if (root.connection === null) root.connection = ({connected: false, state: "off"})
      root.error = root.problem(failure ? failure.message : "")
    })
  }
  function send(link) {
    if (busy || !ready) return
    busy = true
    error = ""
    service.backend.call("inbox.todoConnection", {link: link}, function(result, failure) {
      root.busy = false
      if (failure || !result) { root.error = root.problem(failure ? failure.message : ""); return }
      root.connection = result
    })
  }
  function connect() {
    var link = linkEdit.text.trim()
    linkEdit.text = ""
    if (link !== "") send(link)
  }
  function disconnect() { send("") }
  function summary() {
    if (busy) return "Checking"
    if (error !== "") return error
    if (!connected)
      return "Not connected. In Atlas, open Settings → Connections → Magpie, choose Connect Magpie, and paste the link here."
    var state = connection.state
    if (state === "ready")
      return "Read for The Point: " + Number(connection.open || 0) + " open, " + Number(connection.done || 0) + " done in the last two weeks."
    if (state === "unauthorized")
      return "Atlas no longer accepts this connection. Connect Magpie again in Atlas and paste the new link."
    if (state === "unavailable") return "Could not be read just now. Magpie Mail tries again in a few minutes."
    return "Checking"
  }
  onReadyChanged: load()
  Component.onCompleted: load()

  Text {
    width: parent.width
    text: "TODOS"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }
  Text {
    objectName: "settings-todos-caption"
    width: parent.width
    textFormat: Text.PlainText
    text: "The Point reads your open todos in Atlas, and those done in the last two weeks, so it knows what you have planned and handled. Magpie Mail never changes them, and they go to Claude with the mail it reads."
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }
  Text {
    objectName: "settings-todos-status"
    width: parent.width
    textFormat: Text.PlainText
    text: root.summary()
    color: root.error !== "" || (root.connected && root.connection.state === "unauthorized") ? root.accentColor : root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }
  Widgets.TextField {
    id: linkEdit
    objectName: "settings-todos-link"
    visible: root.needsLink
    width: parent.width
    password: true
    placeholderText: "Paste the link from Atlas"
    enabled: root.ready && !root.busy
    foreground: root.textColor
    accent: root.accentColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    onAccepted: root.connect()
  }
  Widgets.Button {
    objectName: "settings-todos-connect"
    visible: root.needsLink
    text: "Connect"
    enabled: !root.busy && linkEdit.text.trim() !== ""
    foreground: root.textColor
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.caption
    onClicked: root.connect()
  }
  Widgets.Button {
    objectName: "settings-todos-disconnect"
    visible: root.connected
    text: "Disconnect"
    enabled: !root.busy
    foreground: root.dimColor
    bordered: false
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.caption
    onClicked: root.disconnect()
  }
}

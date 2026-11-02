import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui
import "../inbox/Pictures.js" as Pictures

// Settings → Sender pictures: the OpenAI key that paints Inbox senders in Marmalade's style.
// Invariant: the key is sent once to the engine and cleared from the field; it is never read back.
Column {
  id: root
  required property var service
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily
  property var status: null
  property string error: ""
  property bool busy: false
  readonly property bool ready: !!service && !!service.backend && service.backend.ready === true
    && Number(service.backend.apiVersion) >= 8
  visible: status !== null
  spacing: MailStyle.space(6)

  function load() {
    if (!ready) return
    service.backend.call("inbox.pictureStatus", {}, function(result, failure) {
      if (!failure && result) { root.status = result; root.error = ""; return }
      if (failure && (failure.code === -32012 || failure.code === -32601)) { root.status = null; return }
      // Keep the section visible and say why the status could not be read.
      if (root.status === null) root.status = ({present: false})
      root.error = Pictures.problem(failure ? failure.message : "unknown")
    })
  }
  function save() {
    var key = keyEdit.text.trim()
    if (key === "" || busy || !ready) return
    busy = true
    error = ""
    service.backend.call("inbox.setPictureKey", {key: key}, function(result, failure) {
      root.busy = false
      if (failure || !result) { root.error = Pictures.problem(failure ? failure.message : "unknown"); return }
      keyEdit.text = ""
      root.status = result
    })
  }
  function remove() {
    if (busy || !ready) return
    busy = true
    error = ""
    service.backend.call("inbox.removePictureKey", {}, function(result, failure) {
      root.busy = false
      if (failure || !result) { root.error = Pictures.problem(failure ? failure.message : "unknown"); return }
      root.status = result
    })
  }
  onReadyChanged: load()
  Component.onCompleted: load()
  Timer {
    interval: 30000
    repeat: true
    running: root.ready && !!root.status && Number(root.status.waiting) > 0
    onTriggered: root.load()
  }

  Text {
    width: parent.width
    text: "SENDER PICTURES"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }
  Widgets.TextField {
    id: keyEdit
    objectName: "settings-picture-key"
    width: parent.width
    password: true
    placeholderText: root.status && root.status.present ? "Paste a new OpenAI API key to replace the saved one" : "Paste an OpenAI API key"
    enabled: root.ready && !root.busy
    foreground: root.textColor
    accent: root.accentColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    onAccepted: root.save()
  }
  Text {
    objectName: "settings-picture-status"
    width: parent.width
    textFormat: Text.PlainText
    text: root.busy ? "Checking the key with OpenAI" : (root.error || Pictures.summary(root.status))
    color: root.error !== "" || (root.status && root.status.problem) ? root.accentColor : root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }
  Widgets.Button {
    objectName: "settings-picture-remove"
    visible: !!root.status && root.status.present === true
    text: "Remove key"
    enabled: !root.busy
    foreground: root.dimColor
    bordered: false
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.caption
    onClicked: root.remove()
  }
}

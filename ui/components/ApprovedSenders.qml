import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui

// Settings → Approved senders: senders Dave has approved for bundling across senders (Q-019).
// Hidden when the engine has no such list. Names come from the mail, so they stay plain text.
Column {
  id: root
  required property var service
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily
  property var senders: []
  readonly property bool ready: !!service && !!service.inboxTools && !!service.inboxTools.bundles && service.inboxTools.bundles.supported === true
  visible: ready
  spacing: MailStyle.space(6)

  function load() {
    if (!ready) return
    service.backend.call("inbox.approvedSenders", {}, function(result, failure) {
      if (failure || !result) { console.warn("Magpie bundles: could not read approved senders:", failure ? String(failure.message || failure) : "bad answer"); return }
      root.senders = Array.isArray(result.senders) ? result.senders : []
    })
  }
  function remove(entry) {
    service.backend.call("inbox.removeApprovedSender", {email: String(entry.email), name: String(entry.name || "")}, function(result, failure) {
      if (failure || !result) { console.warn("Magpie bundles: could not remove an approved sender:", failure ? String(failure.message || failure) : "bad answer"); root.load(); return }
      root.senders = Array.isArray(result.senders) ? result.senders : []
    })
  }
  onReadyChanged: load()
  Component.onCompleted: load()
  Connections {
    target: root.service && root.service.inboxTools && root.service.inboxTools.bundles ? root.service.inboxTools.bundles : null
    function onApprovedRevisionChanged() { root.load() }
  }

  Text {
    width: parent.width
    text: "APPROVED SENDERS"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    textFormat: Text.PlainText
  }

  Text {
    objectName: "approved-senders-empty"
    visible: root.senders.length === 0
    width: parent.width
    text: "None yet."
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    textFormat: Text.PlainText
  }

  Repeater {
    model: root.senders
    delegate: Item {
      required property var modelData
      required property int index
      width: root.width
      implicitHeight: Math.max(info.implicitHeight, removeButton.implicitHeight) + MailStyle.space(6)

      Column {
        id: info
        anchors.left: parent.left
        anchors.right: removeButton.left
        anchors.rightMargin: MailStyle.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: MailStyle.space(2)
        Text {
          width: parent.width
          objectName: "approved-sender-name-" + index
          text: String(modelData.name || modelData.email || "")
          textFormat: Text.PlainText
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: String(modelData.email || "")
          textFormat: Text.PlainText
          visible: !!modelData.name
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          elide: Text.ElideRight
        }
      }

      Widgets.Button {
        id: removeButton
        objectName: "approved-sender-remove-" + index
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Remove"
        foreground: root.textColor
        accent: root.accentColor
        fontFamily: root.panelFontFamily
        fontSize: MailStyle.caption
        onClicked: root.remove(modelData)
      }
    }
  }
}

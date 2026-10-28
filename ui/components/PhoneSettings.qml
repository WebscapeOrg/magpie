import QtQuick
import "../controls" as Widgets
import "../settings"

Column {
  id: root
  required property var service
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily
  property string code: ""
  property string error: ""
  property bool busy: false
  property var devices: []
  readonly property bool available: !!service && !!service.backend && service.backend.ready
    && service.backend.apiVersion >= 8 && service.backend.protocolInfo
    && Array.isArray(service.backend.protocolInfo.methods)
    && service.backend.protocolInfo.methods.indexOf("phone.pairBegin") >= 0
  spacing: MailStyle.space(8)
  function refresh() {
    if (!available) return
    service.backend.call("phone.devices", {}, function(result, failure) {
      if (!failure && result) devices = result.devices || []
    })
  }
  onAvailableChanged: refresh()
  Component.onCompleted: refresh()
  Timer { id: expiry; interval: 300000; onTriggered: { root.code = ""; root.refresh() } }
  Text {
    text: "iPhone"
    textFormat: Text.PlainText
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
  }
  Widgets.Button {
    text: root.busy ? "Preparing code" : "Pair iPhone..."
    enabled: root.available && !root.busy
    focusable: true
    bordered: true
    foreground: root.textColor
    accent: root.accentColor
    fontFamily: root.panelFontFamily
    onClicked: {
      root.busy = true
      root.error = ""
      root.service.backend.call("phone.pairBegin", {}, function(result, failure) {
        root.busy = false
        if (failure) { root.error = "The iPhone service is unavailable. Check that Enterprise’s mail service is running."; return }
        root.code = String(result.code || "")
        expiry.restart()
      })
    }
  }
  Text {
    width: parent.width
    visible: text !== ""
    text: root.code ? root.code + " — enter this in Magpie’s Enterprise settings on your iPhone. It expires in 5 minutes." : root.error
    textFormat: Text.PlainText
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.body
    wrapMode: Text.WordWrap
  }
  Repeater {
    model: root.devices
    Row {
      required property var modelData
      spacing: MailStyle.space(12)
      Text {
        text: String(modelData.name || "iPhone")
        textFormat: Text.PlainText
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
      Widgets.Button {
        text: "Disconnect"
        focusable: true
        foreground: root.textColor
        accent: root.accentColor
        fontFamily: root.panelFontFamily
        onClicked: root.service.backend.call("phone.revoke", {id:String(modelData.id || "")}, function(result, failure) {
          if (failure) { root.error = "The iPhone could not be disconnected. Try again."; return }
          root.refresh()
        })
      }
    }
  }
}

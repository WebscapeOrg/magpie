import QtQuick
import "../controls" as Widgets
import qs.Commons
import qs.Ui

Widgets.TextField {
  id: root

  property var service: null
  readonly property bool available: !!service && !!service.backendCanNameSender

  objectName: "sender-name-field"
  visible: available
  placeholderText: "Your name (optional) — shown to recipients as the sender"

  function syncFromStore() { text = service ? String(service.accountSenderName || "") : "" }
  function value() { return available ? String(text || "").trim() : undefined }

  Component.onCompleted: syncFromStore()
}

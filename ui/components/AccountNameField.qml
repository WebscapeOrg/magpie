import QtQuick
import "../controls" as Widgets
import qs.Commons
import qs.Ui

Widgets.TextField {
  id: root

  property var service: null

  objectName: "account-name-field"
  placeholderText: "Mailbox name (optional) — how it is listed in Magpie, e.g. Work"

  function syncFromStore() { text = service ? String(service.accountName || "") : "" }
  function value() { return String(text || "").trim() }

  Component.onCompleted: syncFromStore()
}

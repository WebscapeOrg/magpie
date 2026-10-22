import QtQuick
import Quickshell

QtObject {
  id: bridge

  signal notification(string method, var params)
  property bool ready: true
  property int serial: 0
  property var pending: []
  property string endpoint: Quickshell.env("OMAMAIL_TEST_BACKEND_URL")

  function call(method, parameters, callback) {
    if (method !== "providers.resolve" && method !== "model.intent"
        && method !== "model.apply" && method !== "model.unified"
        && method !== "agent.jobsProjection") {
      Qt.callLater(function() { callback(null, "unsupported_test_method") })
      return
    }
    if (!endpoint) throw new Error("Run this suite through tests/run_qml_native.py")

    var request = new XMLHttpRequest()
    pending = pending.concat([request])
    request.open("POST", endpoint)
    request.onreadystatechange = function() {
      if (request.readyState !== XMLHttpRequest.DONE || !bridge) return
      bridge.pending = bridge.pending.filter(function(entry) { return entry !== request })
      if (request.status !== 200) {
        callback(null, "native_test_bridge_failed")
        return
      }
      var reply = JSON.parse(request.responseText)
      callback(reply.result, reply.error || "")
    }
    request.send(JSON.stringify({ jsonrpc: "2.0", id: ++serial, method: method, params: parameters }))
  }
}

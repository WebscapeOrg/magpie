.pragma library
.import QtQml 2.15 as Qml
.import "BackendFixture.js" as BackendFixture

// Invariant: the loopback bridge admits only pure model RPC methods.
function backend(parent) {
  var component = Qt.createComponent(Qt.resolvedUrl("NativeIntentBridge.qml"))
  if (component.status !== Qml.Component.Ready) throw new Error(component.errorString())
  return component.createObject(parent)
}

function install(service) {
  var native = backend(service)
  var pipe = BackendFixture.findPipe(service.backend)
  if (!pipe) throw new Error("No backend fixture pipe")
  var listener = Qt.createQmlObject('import QtQuick; Connections { target:null; property var handler; function onWrittenChanged() {handler(target.written)} }', service)
  var offset = pipe.written.length
  listener.handler = function(written) {
    var lines = written.slice(offset).split("\n")
    offset = written.length - lines[lines.length - 1].length
    for (var lineIndex = 0; lineIndex < lines.length - 1; lineIndex++) {
      var request = JSON.parse(lines[lineIndex])
      if (request.method !== "model.intent") continue
      forward(request)
    }
  }
  function forward(request) {
    native.call(request.method, request.params, function(result, error) {
      BackendFixture.respond(service, request, result, error)
    })
  }
  listener.target = pipe
  return native
}

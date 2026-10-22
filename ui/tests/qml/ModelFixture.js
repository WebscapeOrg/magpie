.pragma library
.import "../../account/Unified.js" as Unified
.import "BackendFixture.js" as BackendFixture

// Invariant: The independent JS oracle models Service wiring; native parity tests separately verify Rust behavior.
function unified(parameters) {
  var capabilities = {}
  var names = ["archive", "spam", "star", "labels", "web", "move", "conversations"]
  for (var capabilityIndex = 0; capabilityIndex < names.length; capabilityIndex++)
    capabilities[names[capabilityIndex]] = Unified.everyMailboxCan(parameters.abilities, names[capabilityIndex])
  return {
    messages: Unified.mergeMessages(parameters.sources),
    totalUnread: Unified.totalUnread(parameters.summaries),
    mailboxes: Unified.sharedMailboxRows(parameters.abilities),
    capabilities: capabilities,
    loading: Unified.anyLoading(parameters.states),
    loaded: Unified.allLoaded(parameters.states),
    hasMore: Unified.anyHasMore(parameters.states),
    serverSearchLoading: Unified.anyServerSearchLoading(parameters.states),
    error: Unified.firstError(parameters.states)
  }
}

function install(service) {
  var pipe = BackendFixture.findPipe(service.backend)
  if (!pipe) throw new Error("No backend pipe")
  var offset = pipe.written.length
  var listener = Qt.createQmlObject('import QtQuick; Connections { target: null; property var handler; function onWrittenChanged() { handler(target.written) } }', service)
  listener.handler = function(written) {
    var lines = written.slice(offset).split("\n")
    offset = written.length - lines[lines.length - 1].length
    for (var lineIndex = 0; lineIndex < lines.length - 1; lineIndex++) {
      var request = JSON.parse(lines[lineIndex])
      if (request.method === "model.unified")
        service.backend.receive(JSON.stringify({jsonrpc:"2.0",id:request.id,result:unified(request.params)}))
    }
  }
  listener.target = pipe
  BackendFixture.markReady(service)
}

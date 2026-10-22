import QtQuick
import Quickshell.Io
import "Wire.js" as Wire
import "Upload.js" as Upload
import "Chunks.js" as Chunks
import "Compatibility.js" as Compatibility

Item {
  id: root
  required property string executable
  required property string expectedVersion
  property int expectedApiVersion: 0
  // Invariant: Unsupported unreleased methods fail locally before the pinned backend can interpret them.
  property int latestApiVersion: 0
  property var unreleasedMethods: []
  property string expectedContractHash: ""
  readonly property int apiVersion: Compatibility.usableApiVersion(protocolInfo,
    expectedApiVersion, latestApiVersion, expectedContractHash)
  readonly property bool needsUpdate: ready && apiVersion < latestApiVersion
  property bool launchEnabled: true
  onLaunchEnabledChanged: Qt.callLater(reconcileProcess)
  onExecutableChanged: Qt.callLater(reconcileProcess)

  function reconcileProcess() {
    if (!launchEnabled || executable === "") {
      failPending("Backend unavailable")
      child.running = false
    } else if (!child.running && !stopping) {
      failure = ""
      child.running = true
    }
  }
  readonly property bool ready: launchEnabled && connected && protocolInfo !== null && !stopping
  readonly property bool stopping: shutdownStarted
  property bool connected: false
  property var protocolInfo: null
  property var pending: ({})
  property var queued: []
  property bool draining: false
  property var uploadQueue: Upload.makeQueue(function() {
    root.stopForFailure("Backend upload cleanup failed")
  })
  property int sequence: 0
  property string failure: ""
  property var responseTransfer: null
  property bool shutdownStarted: false
  property bool shutdownFinished: false
  property bool quitRequested: false
  property var shutdownCallbacks: []
  property var shutdownError: null
  property var shutdownFailure: null
  property bool processExitConfirmed: true
  property bool restarting: false
  property var restartCallback: null
  property string restartExecutable: ""
  property int restartSequence: 0

  signal shutdownComplete(var error)
  signal notification(string method, var params)
  signal requestFailed(string method, var error)

  function parseMessage(raw, callback) {
    return Upload.parse(raw, function(method, parameters, done) {
      return root.call(method, parameters, done)
    }, function() { return root.ready }, callback, uploadQueue)
  }

  function putBodyCache(accountId, id, body, callback) {
    return Upload.putBody(accountId, id, body, function(method, parameters, done) {
      return root.call(method, parameters, done)
    }, function() { return root.ready }, callback, uploadQueue)
  }

  function call(method, parameters, callback) {
    if (operationRefusal(method, parameters) !== null)
      return request(method, parameters, callback, false)
    // Invariant: Physical frames remain bounded even when Unicode makes serialized MIME expand.
    if (JSON.stringify(parameters).length > 200000) {
      return Upload.request(method, parameters, function(nextMethod, nextParams, done) {
        return root.request(nextMethod, nextParams, done, false)
      }, function() { return root.ready }, callback, uploadQueue)
    }
    return request(method, parameters, callback, false)
  }

  function operationRefusal(method, parameters) {
    var operation = method === "request.upload" && parameters ? parameters.method : method
    return Compatibility.unreleasedRefusal(operation, unreleasedMethods, needsUpdate)
      || Compatibility.methodRefusal(protocolInfo, operation)
  }

  function request(method, parameters, callback, internal) {
    var operation = method === "request.upload" && parameters ? parameters.method : method
    var done = function(result, error) {
      if (error) root.requestFailed(operation, error)
      if (typeof callback === "function") callback(result, error)
    }
    var message = Compatibility.dispatchError(
      connected, ready, stopping, method, internal)
    if (message !== null) {
      done(null, { code: -32010, message: message })
      return
    }
    var refusal = operationRefusal(method, parameters)
    if (refusal !== null) {
      done(null, refusal)
      return
    }
    var id = "qml-" + (++sequence)
    // Invariant: Capture request parameters before queueing; callers may mutate their model while the request waits.
    var entry = { id: id, frame: Wire.request(id, method, parameters),
      callback: done, operation: operation, cancelled: false }
    queued.push(entry)
    drainRequests()
    var handle = { withdraw: function() {
      var index = root.queued.indexOf(entry)
      if (index < 0) return false
      entry.cancelled = true
      root.queued.splice(index, 1)
      entry.frame = null
      root.maybeRequestQuit()
      return true
    } }
    handle.cancel = function() { handle.withdraw(); entry.cancelled = true }
    return handle
  }

  // Invariant: Only dispatched frames consume slots or deadlines; callback-submitted work joins the FIFO tail.
  function drainRequests() {
    if (draining || !connected) return
    draining = true
    try {
      while (queued.length > 0 && Object.keys(pending).length < 64 && connected) {
        var entry = queued.shift()
        var next = Object.assign({}, pending)
        var timeout = entry.operation === "agent.context" || entry.operation === "inbox.avatar" || entry.operation === "inbox.snooze" || entry.operation === "inbox.tick" || entry.operation === "inbox.wake" ? 65000 : 30000
        // Invariant: IMAP deadlines exceed the backend call budget because one frame may perform many sequential server commands.
        if (entry.operation.indexOf("imap.") === 0) timeout = 180000
        entry.deadline = Date.now() + timeout
        next[entry.id] = entry
        pending = next
        child.write(entry.frame)
        entry.frame = null
      }
    } finally { draining = false }
  }

  function restart(callback) {
    if (restarting) {
      if (typeof callback === "function")
        callback({ code: -32010, message: "Backend restart is already in progress" })
      return
    }
    if (!launchEnabled || executable === "" || (shutdownStarted && !shutdownFinished)) {
      if (typeof callback === "function")
        callback({ code: -32010, message: "Backend cannot restart yet" })
      return
    }
    restarting = true
    var sequence = ++restartSequence
    restartCallback = callback
    restartExecutable = executable
    if (shutdownFinished) {
      startAfterShutdown()
      return
    }
    shutdown(function(error) {
      if (!root.restarting) return
      if (error) root.finishRestart(error)
      else Qt.callLater(function() {
        if (root.restartSequence === sequence) root.startAfterShutdown()
      })
    }, true)
  }

  function startAfterShutdown() {
    if (!restarting) return
    if (!shutdownFinished || !processExitConfirmed || child.running) {
      finishRestart({ code: -32010, message: "Backend stop was not confirmed" })
      return
    }
    if (!launchEnabled || executable === "" || executable !== restartExecutable) {
      finishRestart({ code: -32010, message: "Backend changed during restart" })
      return
    }
    shutdownStarted = false
    shutdownFinished = false
    shutdownError = null
    shutdownFailure = null
    quitRequested = false
    failure = ""
    restartDeadline.restart()
    child.running = true
  }

  function finishRestart(error) {
    if (!restarting) return
    restartDeadline.stop()
    var callback = restartCallback
    restartCallback = null
    restartExecutable = ""
    restarting = false
    if (typeof callback === "function") callback(error || null)
  }

  function shutdown(callback, forRestart) {
    if (restarting && !forRestart)
      finishRestart({ code: -32010, message: "Backend restart was cancelled" })
    if (typeof callback === "function") {
      if (shutdownFinished) {
        callback(shutdownError)
        return
      }
      var callbacks = shutdownCallbacks.slice()
      callbacks.push(callback)
      shutdownCallbacks = callbacks
    }
    if (shutdownStarted) return
    shutdownStarted = true
    shutdownDeadline.restart()
    uploadQueue.fail({ code: -32010, message: "Backend is shutting down" })
    if (!connected) {
      // Invariant: A process starting during shutdown must still enter the bounded quit path.
      if (child.running || !processExitConfirmed) return
      finishShutdown(null)
      return
    }
    maybeRequestQuit()
  }

  function maybeRequestQuit() {
    var count = Object.keys(pending).length + queued.length
    if (!Compatibility.shouldRequestQuit(stopping, count, quitRequested)) return
    // Invariant: A disconnect during a response callback cannot be reclassified as a clean shutdown by the drain tail.
    if (!connected) return
    quitRequested = true
    request("system.quit", {}, function(result, error) {
      if (error || !result || result.quitReady !== true) {
        stopForFailure("Backend shutdown failed")
      }
    }, true)
  }

  function finishShutdown(error) {
    if (shutdownFinished) return
    shutdownDeadline.stop()
    stopConfirmationDeadline.stop()
    shutdownError = error || null
    shutdownFinished = true
    connected = false
    protocolInfo = null
    responseTransfer = null
    var callbacks = shutdownCallbacks
    shutdownCallbacks = []
    for (var callbackIndex = 0; callbackIndex < callbacks.length; callbackIndex++) callbacks[callbackIndex](shutdownError)
    shutdownComplete(shutdownError)
  }

  function stopForFailure(message) {
    if (shutdownStarted) {
      if (shutdownFailure === null)
        shutdownFailure = { code: -32010, message: message }
      stopConfirmationDeadline.restart()
    }
    failPending(message)
    child.running = false
    if (!shutdownStarted)
      finishRestart({ code: -32010, message: message })
  }

  function failPending(message) {
    responseTransfer = null
    var previous = pending
    var waiting = queued
    pending = ({})
    queued = []
    connected = false
    protocolInfo = null
    failure = message
    var error = { code: -32010, message: message }
    uploadQueue.fail(error)
    for (var id in previous)
      failEntry(previous[id], error)
    for (var requestIndex = 0; requestIndex < waiting.length; requestIndex++)
      failEntry(waiting[requestIndex], error)
  }

  // Invariant: A failed or destroyed receiver cannot strand the remaining callbacks or prevent process shutdown.
  function failEntry(entry, error) {
    if (entry.cancelled) return
    try { entry.callback(null, error) }
    catch (failure) { console.warn("Backend request callback failed") }
  }

  function receive(line) {
    var decoded = Chunks.decode(responseTransfer, line)
    responseTransfer = decoded.state
    if (!decoded.error && decoded.line === null) return
    var event = decoded.error ? null : Wire.notificationValue(decoded.value)
    if (event) {
      if (ready && !stopping) notification(event.method, event.params)
      return
    }
    var reply = decoded.error ? null : Wire.responseValue(decoded.value)
    if (!reply) {
      stopForFailure("Invalid backend response")
      return
    }
    if (!Object.prototype.hasOwnProperty.call(pending, reply.id)) return
    var entry = pending[reply.id]
    if (!entry) return
    var next = Object.assign({}, pending)
    delete next[reply.id]
    pending = next
    try {
      if (!entry.cancelled) entry.callback(reply.result, reply.error || null)
    } finally {
      drainRequests()
      maybeRequestQuit()
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.connected
    onTriggered: {
      var now = Date.now()
      if (root.responseTransfer && now - root.responseTransfer.started >= 30000) {
        root.stopForFailure("Backend response timed out")
        return
      }
      for (var id in root.pending) {
        if (root.pending[id].deadline <= now) {
          root.stopForFailure("Backend request timed out")
          return
        }
      }
    }
  }

  Timer {
    id: restartDeadline
    interval: 10000
    repeat: false
    onTriggered: root.stopForFailure("Backend restart timed out")
  }

  Timer {
    id: shutdownDeadline
    interval: 5000
    repeat: false
    onTriggered: root.stopForFailure("Backend shutdown timed out")
  }

  Timer {
    id: stopConfirmationDeadline
    interval: 1000
    repeat: false
    onTriggered: {
      root.failure = "Backend stop was not confirmed"
      root.finishShutdown({ code: -32010, message: root.failure })
    }
  }

  Process {
    id: child
    command: [root.executable, "serve"]
    running: root.launchEnabled && root.executable !== ""
    stdinEnabled: true
    stdout: SplitParser { onRead: data => root.receive(data) }
    onRunningChanged: { if (running) root.processExitConfirmed = false }
    onStarted: {
      root.processExitConfirmed = false
      if (!root.launchEnabled) {
        root.stopForFailure("Backend unavailable")
        return
      }
      root.connected = true
      if (root.stopping) {
        root.maybeRequestQuit()
        return
      }
      root.failure = ""
      root.request("system.info", {}, function(info, error) {
        if (error)
          root.stopForFailure(root.failure || "Backend handshake failed")
        else if (!Compatibility.accepts(info, root.expectedVersion, root.expectedApiVersion, root.latestApiVersion))
          root.stopForFailure("Incompatible backend")
        else {
          root.protocolInfo = info
          root.finishRestart(null)
        }
      }, true)
    }
    onExited: function(exitCode) {
      root.processExitConfirmed = true
      var clean = Compatibility.isCleanShutdown(
        root.stopping, root.quitRequested, Object.keys(root.pending).length + root.queued.length,
        root.shutdownFailure !== null, exitCode)
      child.running = false
      if (clean) {
        root.connected = false
        root.protocolInfo = null
        root.responseTransfer = null
        root.finishShutdown(null)
        return
      }
      var message = root.failure || "Backend stopped"
      root.failPending(message)
      if (root.stopping)
        root.finishShutdown(root.shutdownFailure
          || { code: -32010, message: message })
      else root.finishRestart({ code: -32010, message: message })
    }
  }
}

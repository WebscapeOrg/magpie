.pragma library
.import "../message/Message.js" as Message

var MAX_MESSAGE = 16 * 1024 * 1024
var MAX_REQUEST = 64 * 1024 * 1024
var MAX_CHUNK = 64 * 1024

// Invariant: RFC822 input is a byte string; UTF-8 encoding would alter binary attachments and legacy charsets.
function chunk(raw, offset, size) {
  var bytes = []
  var end = Math.min(raw.length, offset + size)
  for (var byteIndex = offset; byteIndex < end; byteIndex++) {
    var byte = raw.charCodeAt(byteIndex)
    if (byte > 255) return null
    bytes.push(byte)
  }
  return { data: Message.bytesToBase64(bytes, true), offset: end }
}

function parse(raw, call, connected, callback, queue) {
  return transfer(raw, call, connected, function(upload, done) {
    return call("message.parseUpload", { upload: upload }, done)
  }, callback, MAX_MESSAGE, queue)
}

function request(method, parameters, call, connected, callback, queue) {
  var raw
  try { raw = Message.bytesToLatin1(Message.utf8Bytes(JSON.stringify(parameters))) }
  catch (error) { callback(null, {code:-32602,message:"Invalid upload params"}); return }
  return transfer(raw, call, connected, function(upload, done) {
    return call("request.upload", {method:method, upload:upload}, done)
  }, callback, MAX_REQUEST, queue)
}

function putBody(accountId, id, body, call, connected, callback, queue) {
  var raw = Message.bytesToLatin1(Message.utf8Bytes(JSON.stringify(body)))
  return transfer(raw, call, connected, function(upload, done) {
    return call("cache.bodyPutUpload", { accountId: accountId, id: id, upload: upload }, done)
  }, callback, MAX_MESSAGE, queue)
}

// Invariant: Reserve both upload slots and declared bytes per Backend instance; individually valid uploads can exceed aggregate storage.
function makeQueue(cleanupFailed) {
  var queue = { waiting: [], active: [], bytes: 0, pumping: false }
  queue.pump = function() {
    if (queue.pumping) return
    queue.pumping = true
    try {
      while (queue.waiting.length && queue.active.length < 8) {
        var task = queue.waiting[0]
        if (queue.bytes + task.size > 2 * MAX_REQUEST) break
        queue.waiting.shift()
        queue.active.push(task)
        queue.bytes += task.size
        task.start()
      }
    } finally { queue.pumping = false }
  }
  queue.add = function(task) { queue.waiting.push(task); queue.pump() }
  queue.remove = function(task) {
    var index = queue.waiting.indexOf(task)
    if (index >= 0) queue.waiting.splice(index, 1)
    index = queue.active.indexOf(task)
    if (index >= 0) {
      queue.active.splice(index, 1)
      queue.bytes -= task.size
    }
    queue.pump()
  }
  queue.fail = function(error) {
    var tasks = queue.waiting.concat(queue.active)
    queue.waiting = []
    queue.active = []
    queue.bytes = 0
    for (var taskIndex = 0; taskIndex < tasks.length; taskIndex++) {
      try { tasks[taskIndex].fail(error) }
      catch (failure) { console.warn("Backend upload callback failed") }
    }
  }
  queue.cleanupFailed = cleanupFailed
  return queue
}

function transfer(raw, call, connected, complete, callback, maximum, queue) {
  var upload = ""
  var finished = false
  var cancelled = false
  var started = false
  var current = null
  var chunkSize = 0
  var task = { size: typeof raw === "string" ? raw.length : 0 }
  function finish(result, error) {
    if (finished) return
    finished = true
    raw = ""
    function settled() {
      if (queue) queue.remove(task)
      if (!cancelled && typeof callback === "function") callback(result, error)
    }
    if (error && upload && connected()) {
      // Invariant: Keep upload reservations until cleanup answers, even while the RPC queue is saturated.
      call("upload.discard", { upload: upload }, function(reply, failure) {
        if (failure && connected() && failure.message !== "upload_not_found" && queue
            && typeof queue.cleanupFailed === "function") queue.cleanupFailed()
        settled()
      })
    } else settled()
  }
  task.fail = function(error) {
    if (current && current.withdraw) current.withdraw()
    finish(null, error)
  }
  function stopped() {
    if (finished) return true
    if (!cancelled) return false
    finish(null, { code: -32010, message: "Request cancelled" })
    return true
  }
  function invalid() {
    finish(null, { code: -32602, message: "Invalid message upload" })
  }
  if (typeof raw !== "string" || raw.length > (maximum || MAX_MESSAGE)) {
    invalid()
    return
  }
  function append(offset) {
    if (stopped()) return
    if (offset === raw.length) {
      current = complete(upload, function(payload, failure) {
        if (finished) return
        finish(payload, failure)
      })
      return
    }
    var part = chunk(raw, offset, chunkSize)
    if (!part) { invalid(); return }
    current = call("upload.append", { upload: upload, offset: offset, data: part.data }, function(reply, failure) {
      if (stopped()) return
      if (failure) { finish(null, failure); return }
      if (!reply || reply.offset !== part.offset) { invalid(); return }
      append(part.offset)
    })
  }
  function begun(result, error) {
    if (finished) return
    if (result && typeof result.upload === "string") upload = result.upload
    if (stopped()) return
    if (error) { finish(null, error); return }
    if (!upload || !result || typeof result.chunkSize !== "number"
        || !isFinite(result.chunkSize) || result.chunkSize < 1
        || Math.floor(result.chunkSize) !== result.chunkSize) {
      invalid()
      return
    }
    chunkSize = Math.min(MAX_CHUNK, result.chunkSize)
    append(0)
  }
  task.start = function() {
    started = true
    current = call("upload.begin", { size: raw.length }, begun)
  }
  if (queue) queue.add(task)
  else task.start()
  return { cancel: function() {
    if (finished || cancelled) return
    cancelled = true
    if (!started || (current && current.withdraw && current.withdraw()))
      finish(null, { code: -32010, message: "Request cancelled" })
    // Invariant: An in-flight begin still owns its eventual upload id and reservation; its callback must remain available for cleanup.
  } }
}

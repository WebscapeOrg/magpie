import QtQuick

import "GmailApi.js" as Api

// Invariant: Authenticated transport. It holds no state about the mailbox — only about
// requests in flight — so the service can cancel a page load without having to
// know anything about how it was issued.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  required property var auth
  property var backend: null
  property int backendEpoch: 0
  property string backendAccount: ""
  readonly property string backendIdentity: auth ? String(auth.accountId || "") : ""
  onBackendIdentityChanged: invalidateBackend()
  onAuthChanged: invalidateBackend()
  Connections {
    target: root.auth
    function onLoggedOut() { root.invalidateBackend() }
    function onLoggedInChanged() {
      if (!root.auth || !root.auth.loggedIn) root.invalidateBackend()
    }
  }
  Component.onDestruction: invalidateBackend()

  // Performance: Gmail returns IDs separately from message resources. A bounded group of
  // reads keeps queued work inside each request's deadline while rows arrive.
  property int inFlight: 0
  readonly property bool busy: inFlight > 0

  function newHandle() {
    return { aborted: false, children: [] }
  }

  function usesBackend() {
    return backend && String(backend.executable || "") !== ""
  }

  function invalidateBackend() {
    backendEpoch++
    var old = backendAccount
    backendAccount = ""
    // Invariant: Cache eviction only: queued requests and external keyring credentials
    // are not revoked by this message. Epochs suppress stale UI delivery.
    if (old !== "" && usesBackend())
      backend.call("gmail.invalidate", { accountId: old }, function() {})
  }

  function backendError(error, method) {
    var code = String(error && error.message || "")
    if (code === "backend_needs_update") return Api.localEditError(error)
    if (code === "gmail_timeout" || code === "request_timed_out")
      return /^(gmail\.(modify|batchModify|createLabel|renameLabel|deleteLabel|trash|untrash|send|saveDraft|updateDraft|deleteDraft))$/.test(method)
        ? "Gmail did not answer in time. The submitted change may have completed."
        : "Gmail did not answer in time"
    if (code === "gmail_unauthorized" || code === "gmail_invalid_token")
      return "Gmail authorization expired. Sign in again."
    if (code === "gmail_forbidden") return "Gmail refused this request (HTTP 403). Check account permissions."
    if (code === "gmail_length_required") return "Gmail rejected the request format (HTTP 411)."
    if (code === "gmail_rate_limited") return "Gmail requests are temporarily limited. Try again later."
    if (code === "gmail_queue_full") return "Too many changes are still waiting for Gmail. Wait a moment, then try again."
    if (code === "gmail_queue_lost") return "The change was not sent before the mail backend stopped"
    if (code === "gmail_draft_missing") return "That draft is no longer in the mailbox"
    return "Gmail backend could not complete this request"
  }

  function backendRequest(method, parameters, callback) {
    var handle = newHandle()
    var account = auth ? String(auth.accountId || "") : ""
    if (!usesBackend() || !auth || !auth.loggedIn || account === "") {
      Qt.callLater(function() {
        if (!handle.aborted && typeof callback === "function")
          callback(null, !usesBackend() ? "Mail backend is unavailable" : "Sign in to the configured Gmail account first")
      })
      return handle
    }
    backendAccount = account
    var epoch = backendEpoch
    var session = auth
    parameters.accountId = account
    root.inFlight++
    var settled = false
    function deliver(result, error) {
      if (!root || settled) return
      settled = true
      root.inFlight = Math.max(0, root.inFlight - 1)
      if (handle.aborted || epoch !== root.backendEpoch || auth !== session
          || !auth.loggedIn || String(auth.accountId || "") !== account) return
      if (typeof callback === "function")
        callback(error ? null : result, error ? backendError(error, method) : "")
    }
    var pending = backend.call(method, parameters, function(result, error) {
      if (!error && result && result.queued === true && String(result.ticket || "") !== "") {
        root.park(String(result.ticket), method, deliver)
        return
      }
      deliver(result, error)
    })
    handle.withdraw = function() {
      if (!settled && pending && typeof pending.withdraw === "function" && pending.withdraw())
        deliver(null, null)
    }
    return handle
  }

  // Invariant: A message mutation answers with a ticket: the backend sends it from a
  // per-account queue, paced and retried, and announces the outcome as a
  // `gmail.settled` notification. The request stays in flight until then.
  property var parked: ({})

  function park(ticket, method, deliver) {
    var watchdog = progressTimerComponent.createObject(root, { interval: 180000 })
    watchdog.triggered.connect(function() { root.settle({ ticket: ticket, ok: false, error: "gmail_queue_lost" }) })
    watchdog.start()
    var next = Object.assign({}, parked)
    next[ticket] = { method: method, deliver: deliver, watchdog: watchdog }
    parked = next
  }

  function settle(parameters) {
    var ticket = String(parameters && parameters.ticket || "")
    var entry = parked[ticket]
    if (!entry) return
    var next = Object.assign({}, parked)
    delete next[ticket]
    parked = next
    entry.watchdog.stop()
    entry.watchdog.destroy()
    if (parameters.ok === true) entry.deliver({}, null)
    else entry.deliver(null, { message: String(parameters.error || "gmail_queue_lost") })
  }

  function settleAll(error) {
    var tickets = Object.keys(parked)
    for (var itemIndex = 0; itemIndex < tickets.length; itemIndex++) settle({ ticket: tickets[itemIndex], ok: false, error: error })
  }

  Connections {
    target: root.backend
    function onNotification(method, parameters) { if (method === "gmail.settled") root.settle(parameters) }
    function onReadyChanged() { if (!root.backend.ready) root.settleAll("gmail_queue_lost") }
  }

  function abortRequest(handle) {
    if (!handle) return
    handle.aborted = true
    if (typeof handle.withdraw === "function") handle.withdraw()
    var children = handle.children || []
    for (var itemIndex = 0; itemIndex < children.length; itemIndex++) abortRequest(children[itemIndex])
    handle.children = []
  }

  function listMessages(query, maxResults, pageToken, callback, progress) {
    return backendRequest("gmail.list", {
      query: String(query || ""), pageToken: String(pageToken || ""),
      pageSize: Math.max(1, Math.min(100, Math.floor(Number(maxResults) || 25)))
    }, callback)

  }

  function getMessage(id, full, callback) {
    return backendRequest("gmail.read", {
      id: String(id || ""), full: !!full
    }, callback)

  }

  /** The octets of a part Gmail described but did not send. Every part the
   * sender named comes back that way — an id, a type and a size — and the
   * reader asks for one of them: the invitation, whose file has to be read
   * before a meeting can be drawn or answered.
   */
  function getAttachment(messageId, attachmentId, callback) {
    return backendRequest("gmail.attachment", {
      messageId: String(messageId || ""), attachmentId: String(attachmentId || "")
    }, function(payload, error) {
      if (typeof callback === "function")
        callback(error || !payload ? "" : String(payload.data || ""), error)
    })

  }

  /** The counted members of a conversation, for the reader's conversation rail.
   *
   * Always empty, and Gmail is never asked: it declares `threads` — a
   * server-side thread id exists — but not `conversations`, so its listing is
   * one row per message and no row here carries member ids for a rail to draw.
   *
   * Deferred rather than answered on the spot even though the answer is in
   * hand: every caller in this interface is written against a callback that
   * arrives later, and running one partway through the function that started it
   * is a re-entry no other read produces.
   */
  function getSummaries(ids, callback) {
    var handle = newHandle()
    Qt.callLater(function() {
      if (!root || handle.aborted || typeof callback !== "function") return
      callback([], "")
    })
    return handle
  }

  /** Fetches up to four IDs at a time and calls back once, with results in the
   * order the ids were given rather than the order Google answered in. A list
   * search may also take `progress`, which receives the payloads as Google
   * answers so cached rows can be filled in without waiting for the slowest
   * request on the page. Answers close enough to share a frame are batched:
   * repainting and sorting the whole list once per reply
   * costs far more than the few milliseconds of extra latency reveal.
   */
  function getMessages(ids, full, callback, existingHandle, progress) {
    var handle = existingHandle || newHandle()
    var list = Array.isArray(ids) ? ids : []
    var results = new Array(list.length)
    var remaining = list.length
    var firstError = ""
    var pendingProgress = []
    var progressTimer = null

    if (remaining === 0) {
      if (typeof callback === "function") callback([], "")
      return handle
    }

    function flushProgress() {
      if (progressTimer) {
        progressTimer.stop()
        progressTimer.destroy()
        progressTimer = null
      }
      if (handle.aborted || pendingProgress.length === 0) return
      var ready = pendingProgress
      pendingProgress = []
      if (typeof progress === "function") progress(ready)
    }

    function queueProgress(payload) {
      if (!payload || typeof progress !== "function") return
      pendingProgress.push(payload)
      if (progressTimer) return
      progressTimer = progressTimerComponent.createObject(root, { interval: 16 })
      if (!progressTimer) {
        flushProgress()
        return
      }
      progressTimer.triggered.connect(flushProgress)
      progressTimer.start()
    }

    function finish() {
      if (handle.aborted) return
      if (typeof callback !== "function") return
      flushProgress()
      var ordered = []
      for (var itemIndex = 0; itemIndex < results.length; itemIndex++) {
        if (results[itemIndex]) ordered.push(results[itemIndex])
      }
      // Invariant: A partial page is still a failed page: hiding one failed request just
      // because another answered would let the caller keep a continuation
      // token beyond the missing row.
      callback(ordered, firstError)
    }

    var nextIndex = 0
    var active = 0
    function start(index) {
      active++
      var child = root.getMessage(list[index], full, function(payload, error) {
        active--
        if (handle.aborted) return
        if (error && !firstError) firstError = error
        results[index] = payload
        queueProgress(payload)
        remaining--
        if (remaining === 0) finish()
        else pump()
      })
      handle.children.push(child)
    }
    function pump() {
      while (!handle.aborted && active < 4 && nextIndex < list.length)
        start(nextIndex++)
    }
    pump()
    return handle
  }

  function localRequest(method,parameters,callback) {
    var identity=backendIdentity
    var handle=newHandle()
    parameters.accountId=identity
    backend.call(method,parameters,function(result,error) {
      if (handle.aborted || identity!==root.backendIdentity) return
      callback(result,error ? "Could not read saved mailbox information" : "")
    })
    return handle
  }
  function getLabels(callback) {
    return backendRequest("gmail.labels", {}, function(result, error) {
      if (typeof callback === "function") callback(error ? [] : result, error)
    })

  }

  function getLabelCounts(labelId, callback) {
    if (backend && backend.ready && Number(backend.apiVersion)>=8 && backendIdentity)
      return localRequest("local.labelCounts",{id:String(labelId || "")},callback)
    return backendRequest("gmail.labelCounts", { id: String(labelId || "") }, callback)

  }

  function getProfile(callback) {
    // Invariant: The native sign-in already verified this identity before storing its
    // grant. A new account has no registry ID until this callback identifies it.
    if (auth && auth.loggedIn && auth.signedInProfile) {
      var handle = newHandle()
      var session = auth
      var profile = Api.parseProfile(auth.signedInProfile)
      Qt.callLater(function() {
        if (!handle.aborted && root.auth === session && session.loggedIn)
          callback(profile, "")
      })
      return handle
    }
    if (backend && backend.ready && Number(backend.apiVersion)>=8 && backendIdentity)
      return localRequest("local.overview",{},function(result,error){callback(error ? null : result.profile || {email:root.backendIdentity},error)})
    return backendRequest("gmail.profile", {}, callback)

  }

  function getSendAs(callback) {
    return backendRequest("gmail.sendAs", {}, function(result, error) {
      if (typeof callback === "function") callback(error ? [] : result, error)
    })

  }

  function modifyMessage(id, addLabelIds, removeLabelIds, callback) {
    if (backend && backend.ready && Number(backend.apiVersion) >= 8)
      return localEdit([String(id || "")],addLabelIds || [],removeLabelIds || [],callback)
    return backendRequest("gmail.modify", { id: String(id || ""), addLabelIds: addLabelIds || [], removeLabelIds: removeLabelIds || [] }, callback)
  }
  function batchModify(ids, addLabelIds, removeLabelIds, callback) {
    if (backend && backend.ready && Number(backend.apiVersion) >= 8)
      return localEdit(ids || [],addLabelIds || [],removeLabelIds || [],callback)
    return backendRequest("gmail.batchModify", { ids: ids || [], addLabelIds: addLabelIds || [], removeLabelIds: removeLabelIds || [] }, callback)
  }
  function createLabel(name, callback) {
    return backendRequest("gmail.createLabel", { name: String(name || "") }, callback)
  }
  function renameLabel(id, name, callback) {
    return backendRequest("gmail.renameLabel", { id: String(id || ""), name: String(name || "") }, callback)
  }
  function deleteLabel(id, callback) {
    return backendRequest("gmail.deleteLabel", { id: String(id || "") }, callback)
  }
  function trashMessage(id, callback) { return trashEach("gmail.trash", id, callback) }
  function untrashMessage(id, callback) { return trashEach("gmail.untrash", id, callback) }
  function trashEach(method, id, callback) {
    var list = Array.isArray(id) ? id : [id]
    if (backend && backend.ready && Number(backend.apiVersion) >= 8)
      return localEdit(list,method === "gmail.trash" ? ["TRASH"] : ["INBOX"],
        method === "gmail.trash" ? ["INBOX"] : ["TRASH"],callback)
    var handle = newHandle()
    var remaining = list.length
    var firstError = ""
    if (!remaining) {
      Qt.callLater(function() { if (!handle.aborted && typeof callback === "function") callback(null, "") })
      return handle
    }
    for (var itemIndex = 0; itemIndex < list.length; itemIndex++) {
      handle.children.push(backendRequest(method, { id: String(list[itemIndex] || "") }, function(payload, error) {
        if (handle.aborted) return
        if (error && !firstError) firstError = error
        remaining--
        if (!remaining && typeof callback === "function") callback(payload, firstError)
      }))
    }
    return handle
  }
  function localEdit(ids, additions, removals, callback) {
    var handle = newHandle()
    var identity = String(auth ? auth.accountId || "" : "")
    var ticket = "edit-" + Date.now() + "-" + Math.random().toString(36).slice(2)
    backend.call("local.edit", {accountId:identity,ticket:ticket,ids:ids,
      addLabelIds:additions,removeLabelIds:removals}, function(result,error) {
      if (handle.aborted || identity !== String(root.auth ? root.auth.accountId || "" : "")) return
      if (typeof callback === "function") callback(error ? null : result,Api.localEditError(error))
    })
    return handle
  }
  Component {
    id: progressTimerComponent
    Timer { repeat: false }
  }
  function sendMessage(payload, callback) {
    return backendRequest("gmail.send", Api.sendBody(payload), callback)
  }
  function saveDraft(payload, callback) {
    var id = payload ? String(payload.draftId || "") : ""
    if (id !== "") return updateDraft(id, payload, callback)
    return backendRequest("gmail.saveDraft", Api.sendBody(payload), callback)
  }
  function updateDraft(messageId, payload, callback) {
    var parameters = Api.sendBody(payload)
    parameters.id = String(messageId || "")
    return backendRequest("gmail.updateDraft", parameters, callback)
  }
  function deleteDraft(messageId, callback) {
    return backendRequest("gmail.deleteDraft", { id: String(messageId || "") }, callback)
  }
}

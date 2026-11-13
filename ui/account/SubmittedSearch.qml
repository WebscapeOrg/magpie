import QtQuick
import "SearchState.js" as SearchState
import "Model.js" as Model

Item {
  id: root
  required property var account
  readonly property var backend: account.backend
  readonly property bool available: !!backend
    && backend.ready && Number(backend.apiVersion) >= 8
  property string query: ""
  property string requestedQuery: ""
  property bool savedAvailable: false
  property bool preparationStopped: false
  readonly property bool active: query !== ""
  property int generation: 0
  property double asOf: 0
  property string phase: ""
  property string error: ""
  property string errorCode: ""
  property string localCursor: ""
  property string serverCursor: ""
  property var confirmed: []
  property var overlays: Object.create(null)
  property var handles: []
  property bool savedBusy: false
  property bool savedAgain: false
  readonly property var status: {
    var result = SearchState.status(phase, error, errorCode, SearchState.pendingCount(overlays))
    if (phase === "checking" && !savedAvailable) result.text = "Checking Gmail…" + SearchState.pendingText(result.pendingCount)
    result.savedAvailable = savedAvailable
    return result
  }

  function current(serial, identity) {
    return active && generation === serial && identity === account.accountId
      && account.searchQuery !== "" && account.effectiveQuery === query && available
  }

  function cancelRequests() {
    generation++
    var old = handles
    handles = []
    for (var index = 0; index < old.length; index++) {
      var handle = old[index]
      if (handle && typeof handle.withdraw === "function") handle.withdraw()
      account.abortRequest(handle)
    }
    savedBusy = false
    savedAgain = false
  }

  function hold(handle) {
    if (handle && handles.indexOf(handle) < 0) handles = handles.concat([handle])
    return handle
  }

  function release(handle) {
    var index = handles.indexOf(handle)
    if (index < 0) return
    var next = handles.slice()
    next.splice(index, 1)
    handles = next
  }

  function call(method, parameters, callback) {
    var handle = null
    var completed = false
    handle = backend.call(method, parameters, function(result, failure) {
      completed = true
      if (!root) return
      root.release(handle)
      callback(result, failure)
    })
    if (!completed) hold(handle)
    return handle
  }

  function clear() {
    if (phase !== "") account.listLoading = false
    cancelRequests()
    query = ""
    requestedQuery = ""
    savedAvailable = false
    preparationStopped = false
    phase = ""
    error = ""
    errorCode = ""
    localCursor = ""
    serverCursor = ""
    confirmed = []
    overlays = Object.create(null)
  }

  function reject(message) {
    cancelRequests()
    phase = "invalid"
    error = String(message || "Check the search query and try again.")
    errorCode = "local_search_invalid"
    account.listLoading = false
  }

  function prepare(value, reference) {
    cancelRequests()
    requestedQuery = String(value || "")
    preparationStopped = false
    account.listSerial++
    account.abortRequest(account.listHandle)
    account.listHandle = null
    account.listLoading = true
    phase = "preparing"
    error = ""
    errorCode = ""
  }

  function publish(rows) {
    account.listLiveSerial++
    var next = account.hydrateSummaries(SearchState.merge(rows, overlays))
    var changed = !Model.sameSummaries(account.messages, next)
    if (changed) account.messages = next
    account.loadedDepth = account.messages.length
    account.listLoaded = true
    account.lastError = ""
    if (changed) account.listRefreshed()
  }

  function start(value, reference) {
    cancelRequests()
    query = String(value || "")
    requestedQuery = query
    preparationStopped = false
    savedAvailable = false
    asOf = Number(reference) || Date.now()
    localCursor = ""
    serverCursor = ""
    confirmed = []
    overlays = Object.create(null)
    phase = "local"
    error = ""
    errorCode = ""
    account.listSerial++
    account.abortRequest(account.listHandle)
    account.listHandle = null
    account.listLoading = true
    account.nextPageToken = ""
    var serial = generation
    var identity = account.accountId
    call("local.list", {accountId:identity,query:query,asOf:asOf,
      limit:account.maxMessages,pageToken:""}, function(result, failure) {
      if (!root || !root.current(serial, identity)) return
      if (!failure && result) {
        root.localCursor = String(result.nextPageToken || "")
        root.account.local.status = result.coverage || ({})
        var rows = result.summaries || []
        root.savedAvailable = rows.length > 0
        root.overlays = SearchState.overlay(root.overlays, rows)
        root.account.resultEstimate = rows.length
        root.publish(rows)
      }
      root.remote(false)
    })
  }

  function stop() {
    if (!active && phase !== "preparing") return
    var completed = phase === "complete"
    preparationStopped = phase === "preparing"
    cancelRequests()
    if (completed) return
    phase = "stopped"
    account.providerQuerySerial++
    account.listLoading = false
    account.nextPageToken = localCursor
  }

  function retry() {
    if (preparationStopped && requestedQuery && available) { account.search(requestedQuery); return }
    if (!active || !available || phase === "checking" || phase === "local") return
    cancelRequests()
    serverCursor = ""
    confirmed = []
    remote(false)
  }

  function fail(message, code) {
    phase = "failed"
    error = String(message || "Try Gmail search again when the connection is available.")
    errorCode = String(code || "")
    account.listLoading = false
    account.nextPageToken = localCursor
  }

  function remote(append) {
    if (!active || !available) return
    phase = "checking"
    error = ""
    errorCode = ""
    account.listLoading = true
    account.nextPageToken = ""
    var serial = generation
    var identity = account.accountId
    var base = append ? confirmed.slice() : []
    var preview = account.messages.slice()
    var remoteHandle = account.api.listMessages(query, account.maxMessages,
      append ? serverCursor : "", function(page, failure, detail) {
      if (!root || !root.current(serial, identity)) return
      if (failure || !page) {
        root.release(remoteHandle)
        root.fail(failure || "Gmail returned no search response.", detail && detail.code)
        return
      }
      var ids = page.ids || []
      root.readSaved(ids, serial, identity, function(saved, missing) {
        if (!root || !root.current(serial, identity)) return
        var live = SearchState.combine(base, saved)
        root.overlays = SearchState.overlay(root.overlays, saved)
        if (saved.length) root.publish(SearchState.combine(preview, live))
        function finish(rows, readError, readDetail) {
          if (!root || !root.current(serial, identity)) return
          root.release(remoteHandle)
          var byId = Object.create(null)
          var all = SearchState.combine(saved, rows)
          for (var index = 0; index < all.length; index++) byId[String(all[index].id)] = all[index]
          var settled = base.slice()
          var missingCount = 0
          for (var idIndex = 0; idIndex < ids.length; idIndex++) {
            if (byId[String(ids[idIndex])]) settled.push(byId[String(ids[idIndex])])
            else missingCount++
          }
          if (readError || missingCount) {
            root.publish(SearchState.combine(preview, settled))
            root.fail(readError || "Some results could not be read. Try Gmail search again.", readDetail && readDetail.code)
            return
          }
          root.confirmed = SearchState.combine([], settled)
          root.serverCursor = String(page.nextPageToken || "")
          root.account.resultEstimate = Number(page.estimate || root.confirmed.length)
          root.phase = "complete"
          root.account.listLoading = false
          root.account.nextPageToken = root.serverCursor
          root.publish(root.confirmed)
          root.refreshSaved()
        }
        if (!missing.length) { finish([], "", null); return }
        root.account.api.getMessages(missing, false, function(payloads, readError, readDetail) {
          if (!root || !root.current(serial, identity)) return
          root.account.summarizeResources(payloads, function(prepared, summaryError) {
            if (!root || !root.current(serial, identity)) return
            var summaries = []
            for (var index = 0; index < prepared.length; index++) summaries.push(prepared[index].nativeSummary)
            finish(summaries, summaryError || readError, readDetail)
          })
        }, remoteHandle)
      })
    })
    hold(remoteHandle)
  }

  function readSaved(ids, serial, identity, callback) {
    var rows = [], missing = [], offset = 0
    function next() {
      if (!root || !root.current(serial, identity)) return
      if (offset >= ids.length) { callback(rows, missing); return }
      var wanted = ids.slice(offset, offset + 100)
      offset += wanted.length
      root.call("local.summaries", {accountId:identity,ids:wanted,
        query:root.query,asOf:root.asOf}, function(result, failure) {
        if (!root || !root.current(serial, identity)) return
        if (failure || !result) missing = missing.concat(wanted)
        else {
          rows = rows.concat(result.summaries || [])
          missing = missing.concat(result.missingIds || [])
        }
        next()
      })
    }
    next()
  }

  function refreshSaved() {
    if (!active || !available || phase === "local" || phase === "preparing" || phase === "invalid") return
    if (savedBusy) { savedAgain = true; return }
    savedBusy = true
    var serial = generation
    var identity = account.accountId
    var ids = []
    var seen = Object.create(null)
    var rows = account.messages.concat(confirmed)
    for (var index = 0; index < rows.length; index++) {
      var id = String(rows[index].id || "")
      if (id && !seen[id]) { ids.push(id); seen[id] = true }
    }
    for (var key in overlays) if (SearchState.hasOwn(overlays, key) && !seen[key]) { ids.push(key); seen[key] = true }
    readSaved(ids, serial, identity, function(fresh) {
      if (!root || !root.current(serial, identity)) return
      var updates = fresh
      function pendingPage(token) {
        root.call("local.summaries", {accountId:identity,ids:[],query:root.query,
          asOf:root.asOf,includePending:true,pendingPageToken:token}, function(result, failure) {
          if (!root || !root.current(serial, identity)) return
          if (!failure && result) updates = updates.concat(result.summaries || [])
          var next = !failure && result ? String(result.pendingNextPageToken || "") : ""
          if (next && next !== token) { pendingPage(next); return }
          root.overlays = SearchState.overlay(root.overlays, updates)
          var freshById = Object.create(null)
          for (var updateIndex = 0; updateIndex < updates.length; updateIndex++) freshById[String(updates[updateIndex].id)] = updates[updateIndex]
          var source = root.phase === "complete" ? root.confirmed : root.account.messages
          var refreshed = []
          for (var rowIndex = 0; rowIndex < source.length; rowIndex++) refreshed.push(freshById[String(source[rowIndex].id)] || source[rowIndex])
          if (root.phase === "complete") root.confirmed = refreshed
          root.publish(refreshed)
          root.savedBusy = false
          if (root.savedAgain) { root.savedAgain = false; root.refreshSaved() }
        })
      }
      pendingPage("")
    })
  }

  function loadMore() {
    if (!active || account.listLoading) return
    if (phase === "complete") { if (serverCursor) remote(true); return }
    if (!localCursor) return
    var serial = generation
    var identity = account.accountId
    account.listLoading = true
    call("local.list", {accountId:identity,query:query,asOf:asOf,
      limit:account.maxMessages,pageToken:localCursor}, function(result, failure) {
      if (!root || !root.current(serial, identity)) return
      root.account.listLoading = false
      if (failure || !result) { root.localCursor = ""; root.account.nextPageToken = ""; return }
      root.localCursor = String(result.nextPageToken || "")
      root.account.nextPageToken = root.localCursor
      root.overlays = SearchState.overlay(root.overlays, result.summaries || [])
      root.publish(SearchState.combine(root.account.messages, result.summaries || []))
    })
  }

  Connections {
    target: root.account
    function onAccountIdChanged() { root.clear() }
    function onReadyChanged() { if (!root.account.ready && (root.active || root.phase === "preparing")) root.stop() }
    function onActiveChanged() { if (!root.account.active && (root.active || root.phase === "preparing")) root.stop() }
  }
  Connections {
    target: root.account.auth
    ignoreUnknownSignals: true
    function onLoggedInChanged() { if (root.account.auth && !root.account.auth.loggedIn && (root.active || root.phase === "preparing")) root.stop() }
    function onLoggedOut() { if (root.active || root.phase === "preparing") root.stop() }
  }
  onAvailableChanged: if (!available && (active || phase === "preparing")) stop()
  Component.onDestruction: cancelRequests()
}

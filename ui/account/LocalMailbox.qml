import QtQuick

Item {
  id: root
  required property var account
  readonly property var backend: account.backend
  readonly property bool available: account.providerId === "gmail" && !!backend
    && backend.ready && Number(backend.apiVersion) >= 8
  property var status: ({})
  property bool onlineSearch: false
  property string onlineQuery: ""
  readonly property bool hasMail: Number(status.stored || 0) > 0
  property bool refreshing: false
  property string error: ""
  property var edits: []
  property string watched: ""
  property bool overviewBusy: false
  function refreshOverview(check) {
    if (!available || overviewBusy) return
    var identity=account.accountId
    overviewBusy=true
    var method=watched!==identity ? "local.watch" : check ? "local.refresh" : "local.overview"
    backend.call(method,{accountId:identity},function(result,failure) {
      if (identity!==root.account.accountId) return
      root.overviewBusy=false
      if (failure) return
      root.watched=identity
      root.status=result.coverage || ({})
      var before=root.account.inboxUnread
      var first=!root.account.countPrimed
      root.account.countPrimed=true
      root.account.inboxUnread=Number(result.unread || 0)
      root.account.previewMessages=result.summaries || []
      var labels=result.labels || []
      var oldLabels=root.account.labels || []
      var oldById=({})
      for (var oldLabelIndex=0;oldLabelIndex<oldLabels.length;oldLabelIndex++) oldById[String(oldLabels[oldLabelIndex].id)]=oldLabels[oldLabelIndex]
      for (var labelIndex=0;labelIndex<labels.length;labelIndex++) {
        var previous=oldById[String(labels[labelIndex].id)]
        if (previous) {labels[labelIndex].total=previous.total;labels[labelIndex].unread=previous.unread}
      }
      root.account.labels=labels
      if (result.profile && result.profile.email) root.account.profile=result.profile
      if (!root.account.listLoading && (first || root.account.inboxUnread>before || (root.account.active && !root.account.listLoaded))) root.account.loadMessages(false,true)
    })
  }
  function stopWatch() {
    if (watched && backend && backend.ready) backend.call("local.unwatch",{accountId:watched},function(){})
    watched=""
  }
  function dismissConflict(ticket) {
    var identity=account.accountId
    backend.call("local.dismissConflict",{accountId:identity,ticket:ticket},function(result,failure){
      if (identity!==root.account.accountId) return
      if (failure) {root.error="Could not dismiss this notice. Try again.";return}
      root.refreshStatus();root.refreshEdits()
    })
  }

  function refreshStatus() {
    if (!available || refreshing) return
    refreshing = true
    var identity = account.accountId
    backend.call("local.status", {accountId:identity}, function(result, failure) {
      root.refreshing = false
      if (identity !== root.account.accountId) return
      if (failure) { root.error = "Offline mail is unavailable. Your saved messages have been kept."; return }
      root.status = result || ({})
      root.error = ""
    })
  }
  function setPaused(paused) {
    if (!available) return
    var identity = account.accountId
    backend.call("local.pause", {accountId:identity,paused:paused}, function(result,failure) {
      if (identity !== root.account.accountId) return
      if (failure) { root.error = "Could not change the download setting. Try again."; return }
      root.status = result || ({})
    })
  }
  function searchOnline() {
    if (account.submittedSearch.active) { account.retrySearch(); return }
    onlineSearch = true
    onlineQuery = account.effectiveQuery
    account.loadMessages(false,true)
  }
  function load(append, limit, serial) {
    if (!available) return false
    if (onlineSearch && onlineQuery === account.effectiveQuery) return false
    onlineSearch = false
    var identity = account.accountId
    backend.call("local.list", {accountId:identity,query:account.effectiveQuery,
      limit:Math.min(100000,limit),pageToken:append ? account.nextPageToken : ""}, function(result,failure) {
      if (identity !== root.account.accountId || serial !== root.account.listSerial) return
      root.account.listLoading = false
      if (failure) {
        root.error = String(failure.message || "") === "local_search_unsupported"
          ? "This search needs Gmail. Choose Search online to continue."
          : "Could not read offline mail. Your saved messages have been kept."
        root.account.nextPageToken = ""
        return
      }
      root.error = ""
      root.status = result.coverage || ({})
      var summaries = result.summaries || []
      for (var summaryIndex=0;summaryIndex<summaries.length;summaryIndex++) summaries[summaryIndex] = root.account.hydrateSummary(summaries[summaryIndex])
      root.account.nextPageToken = String(result.nextPageToken || "")
      root.account.resultEstimate = (append ? root.account.messages.length : 0)+summaries.length
      root.account.applySummaries(summaries,append,
        root.account.searchQuery !== "" || !root.status.inventoryComplete,root.status.error === "")
    })
    return true
  }
  function refreshEdits() {
    if (!available) return
    var identity = account.accountId
    backend.call("local.edits", {accountId:identity}, function(result,failure) {
      if (identity !== root.account.accountId) return
      if (!failure) root.edits = result || []
    })
  }
  function undo(ticket) {
    var identity = account.accountId
    backend.call("local.cancelEdit", {accountId:identity,ticket:ticket}, function(result,failure) {
      if (identity !== root.account.accountId) return
      if (failure) { root.error = "This change has started syncing. Use the opposite mailbox action to reverse it."; return }
      root.refreshEdits()
      root.account.loadMessages(false,true)
    })
  }
  onAvailableChanged: {
    if (available) {refreshStatus();refreshOverview(false);refreshEdits()}
    else stopWatch()
  }
  Component.onCompleted: if (available) {refreshStatus();refreshOverview(false);refreshEdits()}
  Component.onDestruction: stopWatch()
  Timer {interval: 5000; repeat: true; running: root.available && root.watched === ""; onTriggered: root.refreshOverview(false)}
  Connections {
    target: root.account
    function onAccountIdChanged() {
      root.status = ({}); root.edits = []; root.error = ""; root.refreshing = false
      root.onlineSearch = false; root.stopWatch(); root.overviewBusy=false; refreshList.stop(); root.refreshStatus(); root.refreshOverview(false)
    }
  }
  Connections {
    target: root.backend
    ignoreUnknownSignals: true
    function onNotification(method, parameters) {
      if (method !== "local.changed" || parameters.accountId !== root.account.accountId) return
      var previous = root.status
      root.status = parameters.status || ({})
      if (parameters.changed) root.refreshOverview(false)
      if (previous.pendingEdits !== root.status.pendingEdits) root.refreshEdits()
      if (root.account.active && root.account.windowOpen && (!root.account.listLoading || root.account.submittedSearch.active)
          && (previous.stored !== root.status.stored || previous.pendingEdits !== root.status.pendingEdits
            || parameters.changed === true)) refreshList.start()
    }
  }
  Timer { id: refreshList; interval: 150; onTriggered: {
    if (root.account.submittedSearch.active) root.account.submittedSearch.refreshSaved()
    else root.account.loadMessages(false,true)
  } }
}

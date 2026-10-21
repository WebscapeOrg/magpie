import QtQuick
Item {
  id: root
  required property var service
  property var visibleRows: []
  readonly property bool browsing: !!service && service.windowOpen === true
  property var overviews: ({})
  property var avatars: ({})
  property string avatarRefreshId: ""
  property int avatarEpoch: 0
  function refreshAvatars() { avatarEpoch++; avatarRefreshId = "images-" + Date.now(); avatars = ({}); avatarPending = ({}); drain() }
  property var avatarPending: ({})
  property var snapshotsPending: ({})
  property bool paused: false
  function setPaused(value) { paused = !!value; if (service && typeof service.saveWindowPrefs === "function") service.saveWindowPrefs() }
  onPausedChanged: if (!paused) refresh()
  property bool requesting: false
  property bool ticking: false
  property bool retryFailed: false
  property string error: ""
  property string notice: ""
  property var snoozes: []
  property var lastSnoozed: null
  readonly property bool available: service && service.backend && service.backend.ready && Number(service.backend.apiVersion) >= 8
  function key(account,id) { return String(account) + "\n" + String(id) }
  function owner(row) { return service.hostForId(row.id) }
  function id(row) { return String(row.sourceId || row.id || "") }
  function overviewFor(row) { var host = owner(row); return host ? overviews[key(host.accountId,id(row))] || ({}) : ({}) }
  function avatarFor(row) { var host = owner(row); return host ? String(avatars[key(host.accountId,row.from ? row.from.email : "")] || "") : "" }
  function snapshot(account) {
    if (!available || snapshotsPending[account]) return
    snapshotsPending[account] = true
    service.backend.call("inbox.snapshot", {accountId:account}, function(result,failure) {
      delete root.snapshotsPending[account]
      if (failure || !result) return
      var next = Object.assign({},root.overviews)
      var values = result.overviews || ({})
      for (var message in values) next[root.key(account,message)] = values[message]
      root.overviews = next
      var kept = root.snoozes.filter(function(snooze) { return snooze.accountId !== account })
      root.snoozes = kept.concat(result.snoozes || [])
      root.drain()
    })
  }
  function refresh() {
    if (!available) return
    var rows = service.accountSummaries || []
    for (var rowIndex=0;rowIndex<rows.length;rowIndex++) snapshot(rows[rowIndex].id)
    drain()
  }
  onBrowsingChanged: if (browsing) refresh()
  onVisibleRowsChanged: refreshSoon.restart()
  function retry() { retryFailed = true; error = ""; refresh() }
  function drain() {
    if (!available || !browsing) return
    var rows = visibleRows
    var chosen = []; var account = ""
    if (!requesting && !paused && service.windowPrefsLoaded !== false) {
    for (var rowIndex=0;rowIndex<rows.length;rowIndex++) {
      var row = rows[rowIndex]; var host = owner(row)
      if (!host || host.providerId !== "gmail") continue
      var old = overviewFor(row)
      if (old.text || (old.state === "failed" && !retryFailed && Date.now()-Number(old.updated || 0)<900000)) continue
      if (account !== "" && account !== host.accountId) continue
      account = host.accountId; chosen.push(id(row))
      if (chosen.length>=4) break
    }
    if (chosen.length) {
      requesting = true
      service.backend.call("inbox.overviews", {accountId:account,ids:chosen,retry:retryFailed}, function(result,failure) {
        root.requesting = false
        if (failure) {
          root.error = "AI overviews could not start. Check the Claude login, then choose Menu → Retry AI overviews."
          var next = Object.assign({},root.overviews)
          for (var chosenIndex=0;chosenIndex<chosen.length;chosenIndex++) next[root.key(account,chosen[chosenIndex])] = {state:"failed",reason:"AI request could not start; retry from Menu",updated:Date.now()}
          root.overviews = next
        }
        root.retryFailed = false
      })
    }
    }
    for (var avatarIndex=0;avatarIndex<Math.min(rows.length,100);avatarIndex++) avatar(rows[avatarIndex])
  }
  function avatar(row) {
    var host = owner(row)
    var email = String(row.from ? row.from.email || "" : "")
    if (!host || host.providerId !== "gmail" || email === "") return
    var cacheKey = key(host.accountId,email)
    if (avatars[cacheKey] !== undefined || avatarPending[cacheKey]) return
    if (Object.keys(avatarPending).length >= 3) return
    avatarPending[cacheKey] = true
    var epoch = avatarEpoch
    service.backend.call("inbox.avatar", {accountId:host.accountId,email:email,refreshId:avatarRefreshId}, function(result,failure) {
      if (epoch !== root.avatarEpoch) return
      delete root.avatarPending[cacheKey]
      var next = Object.assign({},root.avatars); next[cacheKey] = !failure && result ? String(result.data || "") : ""; root.avatars = next
      root.drain()
    })
  }
  function snooze(rowId, until) {
    if (!available) { error = "Update the Magpie backend to use Snooze."; return false }
    var host = service.hostForId(rowId)
    if (!host || host.providerId !== "gmail") { error = "Snooze needs a Gmail mailbox."; return false }
    notice = "Snoozing"; error = ""
    var request = {accountId:host.accountId,id:service.sourceIdFor(rowId),until:until}
    service.backend.call("inbox.snooze",request,function(result,failure) {
      if (failure) { root.notice = ""; root.error = "Snooze could not finish. The schedule is saved if Gmail's response was interrupted; Magpie will retry."; return }
      root.lastSnoozed = request
      root.notice = "Snoozed until " + new Date(until).toLocaleString(Qt.locale(),"ddd, d MMM, HH:mm")
      host.refresh(); root.refresh()
    })
    return true
  }
  function wake(entry) {
    notice = "Returning to Inbox"; error = ""
    service.backend.call("inbox.wake",{accountId:entry.accountId,id:entry.id},function(result,failure) {
      if (failure) { root.notice = ""; root.error = "Could not return this message. Check your connection and try again."; return }
      root.lastSnoozed = null; root.notice = "Returned to Inbox"; service.refresh(); root.refresh()
    })
  }
  function tick() {
    if (!available || ticking) return
    ticking = true
    service.backend.call("inbox.tick",{},function(result,failure) {
      root.ticking = false
      if (failure || (result && result.failures>0)) root.error = "Some snoozed messages could not return yet. Magpie will retry; you can also use Menu → Snoozed mail."
      else {
        if (root.error.indexOf("Some snoozed messages") === 0) root.error = ""
        if (result && result.woke>0) { service.refresh(); root.refresh() }
      }
    })
  }
  onAvailableChanged: if (available) { refresh(); tick() }
  Connections {
    target: root.service
    function onMessagesChanged() { refreshSoon.restart() }
  }
  Timer { id: refreshSoon; interval: 300; onTriggered: root.refresh() }
  Timer { interval: 5000; repeat: true; running: root.available && root.browsing; onTriggered: root.refresh() }
  Timer { interval: 30000; repeat: true; running: root.available; onTriggered: root.tick() }
  Timer { interval: 8000; running: root.notice !== "" && root.notice !== "Snoozing"; onTriggered: root.notice = "" }
  Component.onCompleted: if (available) { refresh(); tick() }
}

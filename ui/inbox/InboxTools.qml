import QtQuick
import "Readiness.js" as Readiness
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
  property bool descriptionsEnabled: true
  function setDescriptionsEnabled(value) { descriptionsEnabled = !!value; if (service && typeof service.saveWindowPrefs === "function") service.saveWindowPrefs(); if (descriptionsEnabled) refresh() }
  property bool paused: false
  property int preferenceWrites: 0
  property int preferenceRevision: 0
  property var preparationSettings: ({})
  property var preparationFailures: ({})
  property var preferenceQueue: ({})
  function preparationResult(account, operation, failed) {
    var next = Object.assign({},preparationFailures); var name = key(account,operation)
    if (failed) { if (!next[name] || next[name] > Date.now()) next[name] = Date.now() }
    else delete next[name]
    if (JSON.stringify(next) === JSON.stringify(preparationFailures)) return
    preparationFailures = next
    if (service && typeof service.saveWindowPrefs === "function") service.saveWindowPrefs()
  }
  function restorePreparation(saved) {
    var queue = ({}); var failures = ({})
    var input = saved.preparationQueue
    if (input && typeof input === "object" && !Array.isArray(input)) {
      for (var account in input) {
        var row = input[account]
        if (!row || typeof row !== "object" || Array.isArray(row)) continue
        var own = ({})
        for (var field in row) if ((field === "paused" || field === "allowRemoteImages") && typeof row[field] === "boolean") own[field] = row[field]
        if (Object.keys(own).length) queue[account] = own
      }
    }
    input = saved.preparationFailures
    if (input && typeof input === "object" && !Array.isArray(input)) {
      for (var name in input) if (typeof input[name] === "number" && isFinite(input[name]) && input[name] > 0 && input[name] <= Date.now()) failures[name] = input[name]
    }
    preferenceQueue = queue; preparationFailures = failures
  }
  function retainAccounts() {
    if (service.accountsLoaded === false) return
    var oldQueue = JSON.stringify(preferenceQueue); var oldFailures = JSON.stringify(preparationFailures)
    var accounts = service.accountSummaries || []; var owners = ({})
    for (var i=0;i<accounts.length;i++) owners[accounts[i].id] = true
    var notifications = ({}); var prefs = ({}); var failures = ({}); var values = ({})
    for (var account in notificationRows) if (owners[account]) notifications[account] = notificationRows[account]
    for (var account in preferenceQueue) if (owners[account]) prefs[account] = preferenceQueue[account]
    for (var name in preparationFailures) if (owners[name.split("\n")[0]]) failures[name] = preparationFailures[name]
    for (var name in overviews) if (owners[name.split("\n")[0]]) values[name] = overviews[name]
    notificationRows = notifications; preferenceQueue = prefs; preparationFailures = failures; overviews = values
    if ((oldQueue !== JSON.stringify(prefs) || oldFailures !== JSON.stringify(failures)) && typeof service.saveWindowPrefs === "function") service.saveWindowPrefs()
  }
  function setPaused(value) { paused = !!value; if (service && typeof service.saveWindowPrefs === "function") service.saveWindowPrefs(); savePreparationPreferences("paused",paused) }
  onPausedChanged: if (!paused) refresh()
  property bool requesting: false
  property bool ticking: false
  readonly property bool sharedScheduler: !!service && !!service.backend && service.backend.apiVersion >= 8
    && !!service.backend.protocolInfo && service.backend.protocolInfo.engineService === true
  property bool retryFailed: false
  property string error: ""
  readonly property string preparationProblem: {
    if (!service || !service.preparingInbox) return ""
    if (paused) return "New Inbox messages are paused. Resume AI descriptions from Menu, or open All mail."
    var rows = service.rawMessages || []
    for (var name in preparationFailures) if (overviewClock - preparationFailures[name] >= 900000) return "Inbox preparation has been unavailable for a while. Choose Menu → Retry AI descriptions, or read these messages in All mail."
    for (var i=0;i<rows.length;i++) {
      var value = overviewFor(rows[i]); var since = Number(value.pendingSince || value.updated || 0)
      if (!value.text && since > 0 && overviewClock-since >= 900000) return "Some Inbox messages are taking longer to prepare. Choose Menu → Retry AI descriptions, or read them in All mail."
    }
    return ""
  }
  property string notice: ""
  property var snoozes: []
  property var lastSnoozed: null
  readonly property bool available: service && service.backend && service.backend.ready && Number(service.backend.apiVersion) >= 8
  function key(account,id) { return String(account) + "\n" + String(id) }
  function owner(row) { return service.hostForId(row.id) }
  function id(row) { return String(row.sourceId || row.id || "") }
  property double overviewClock: Date.now()
  function overviewFor(row) {
    var host = owner(row)
    var value = host ? overviews[key(host.accountId,id(row))] || ({}) : ({})
    if (value.text !== undefined && !Readiness.ready(value, overviewClock))
      return Object.assign({}, value, {text:"",state:value.state === "ready" ? "stale" : value.state})
    return value
  }
  function admitted(account, rows) {
    var values = overviews; var at = overviewClock
    return rows.filter(function(row) { return Readiness.ready(values[key(account, id(row))], at) })
  }
  function inboxRows(rows) {
    return rows.filter(function(row) { var host = owner(row); return host && Readiness.ready(overviews[key(host.accountId,id(row))], overviewClock) })
  }
  function savePreparationPreferences(field,value) {
    if (service.windowPrefsLoaded === false) return
    var accounts = service.accountSummaries || []; var queue = Object.assign({},preferenceQueue)
    preferenceRevision++
    for (var i=0;i<accounts.length;i++) {
      var own = Object.assign({},queue[accounts[i].id] || {}); own[field] = value; queue[accounts[i].id] = own
    }
    preferenceQueue = queue
    if (typeof service.saveWindowPrefs === "function") service.saveWindowPrefs()
    flushPreparationPreferences()
  }
  function flushPreparationPreferences() {
    if (!available || preferenceWrites) return
    var accounts = Object.keys(preferenceQueue)
    if (!accounts.length) { if (error.indexOf("Enterprise has not received this setting yet") === 0) error = ""; return }
    var account = accounts[0]; var values = Object.assign({},preferenceQueue[account])
    preferenceWrites = 1
    service.backend.call("inbox.preferences",Object.assign({accountId:account},values),function(result,failure) {
      root.preferenceWrites = 0
      if (failure) { root.error = "Enterprise has not received this setting yet and may still use its previous setting. Magpie will retry."; return }
      var queue = Object.assign({},root.preferenceQueue); var own = Object.assign({},queue[account] || {})
      for (var field in values) if (own[field] === values[field]) delete own[field]
      if (Object.keys(own).length) queue[account] = own; else delete queue[account]
      root.preferenceQueue = queue
      if (typeof service.saveWindowPrefs === "function") service.saveWindowPrefs()
      root.flushPreparationPreferences()
    })
  }
  function avatarFor(row) { var host = owner(row); return host ? String(avatars[key(host.accountId,row.from ? row.from.email : "")] || "") : "" }
  function snapshot(account) {
    if (!available || snapshotsPending[account]) return
    snapshotsPending[account] = true
    var settingsRevision = preferenceRevision
    service.backend.call("inbox.snapshot", {accountId:account}, function(result,failure) {
      delete root.snapshotsPending[account]
      if (!(service.accountSummaries || []).some(function(row) { return row.id === account })) return
      root.preparationResult(account,"snapshot",!!failure || !result)
      if (failure || !result) return
      var next = Object.assign({},root.overviews)
      for (var oldKey in next) if (oldKey.indexOf(account + "\n") === 0) delete next[oldKey]
      if (result.preferences && settingsRevision === root.preferenceRevision && root.preferenceWrites === 0 && !root.preferenceQueue[account]) {
        var prefs = Object.assign({},root.preparationSettings); prefs[account] = result.preferences; root.preparationSettings = prefs
        root.paused = (service.accountSummaries || []).some(function(row) { return prefs[row.id] && prefs[row.id].paused === true })
      }
      var values = result.overviews || ({})
      for (var message in values) next[root.key(account,message)] = values[message]
      root.overviews = next
      var kept = root.snoozes.filter(function(snooze) { return snooze.accountId !== account })
      root.snoozes = kept.concat(result.snoozes || [])
      root.flushNotifications(account)
      root.drain()
    })
  }
  property var notificationRows: ({})
  property var notificationsPending: ({})
  property var notificationOffsets: ({})
  function queueNotifications(account, rows) {
    var next = Object.assign({}, notificationRows)
    var own = Object.assign({},next[account] || {})
    for (var i=0;i<rows.length;i++) own[String(rows[i].id)] = rows[i]
    next[account] = own; notificationRows = next
    snapshot(account)
  }
  function flushNotifications(account) {
    var pending = notificationRows[account] || ({})
    var ids = Object.keys(pending)
    if (!ids.length || notificationsPending[account]) return
    var ready = ids.filter(function(id) { return Readiness.ready(overviews[key(account,id)],overviewClock) })
    var offset = ready.length ? 0 : (notificationOffsets[account] || 0)
    if (ready.length) ids = ready
    if (offset >= ids.length) offset = 0
    ids = ids.slice(offset,offset+100)
    notificationOffsets[account] = offset+ids.length
    notificationsPending[account] = true
    service.backend.call("local.summaries",{accountId:account,query:"in:inbox is:unread",ids:ids},function(result,failure) {
      delete root.notificationsPending[account]
      if (failure || !result) return
      var host = service.findAccount(account)
      if (!host) { delete root.notificationRows[account]; return }
      var remaining = Object.assign({},root.notificationRows[account] || {})
      var current = ({})
      var rows = result.summaries || []
      for (var i=0;i<rows.length;i++) if (rows[i].matchesQuery === true) current[String(rows[i].id)] = rows[i]
      var admitted = []
      for (var n=0;n<ids.length;n++) {
        var id = ids[n]
        if (!current[id]) { delete remaining[id]; continue }
        if (Readiness.ready(root.overviews[root.key(account,id)],root.overviewClock)) {
          admitted.push(Object.assign({},current[id],{subject:root.overviews[root.key(account,id)].text,snippet:""})); delete remaining[id]
        }
      }
      var next = Object.assign({},root.notificationRows); next[account] = remaining; root.notificationRows = next
      if (service.notifyNewMail && admitted.length) host.deliverNotification(admitted)
    })
  }
  function refresh() {
    overviewClock = Date.now()
    retainAccounts()
    if (!available) return
    flushPreparationPreferences()
    var rows = service.accountSummaries || []
    for (var rowIndex=0;rowIndex<rows.length;rowIndex++) snapshot(rows[rowIndex].id)
    drain()
    if (browsing && service.curatedInbox && service.rawMessages.length && !service.messages.length && service.hasMore && !service.listLoading) service.loadMore()
  }
  onBrowsingChanged: if (browsing) refresh()
  onVisibleRowsChanged: refreshSoon.restart()
  function retry() { retryFailed = true; error = ""; refresh() }
  function drain() {
    if (!available || !browsing) return
    if (!requesting && !paused && service.windowPrefsLoaded !== false)
      requestOverviews(overviewBatch(service.curatedInbox ? service.rawMessages : visibleRows))
    for (var avatarIndex=0;avatarIndex<Math.min(visibleRows.length,100);avatarIndex++) avatar(visibleRows[avatarIndex])
  }
  function overviewBatch(rows) {
    var batch = {accountId: "", ids: []}
    for (var rowIndex=0;rowIndex<rows.length;rowIndex++) {
      var row = rows[rowIndex]; var host = owner(row)
      if (!host || host.providerId !== "gmail") continue
      var old = overviewFor(row)
      var age = Date.now() - Number(old.updated || 0)
      if (old.text || (age >= 0 && age < 900000 && (old.state === "running" || (old.state === "failed" && !retryFailed)))) continue
      if (batch.accountId !== "" && batch.accountId !== host.accountId) continue
      batch.accountId = host.accountId; batch.ids.push(id(row))
      if (batch.ids.length>=4) break
    }
    return batch
  }
  function requestOverviews(batch) {
    if (batch.ids.length === 0) return
    requesting = true
    service.backend.call("inbox.overviews", {accountId:batch.accountId,ids:batch.ids,retry:retryFailed,allowRemoteImages:service.alwaysShowImages === true}, function(result,failure) {
      root.requesting = false
      if (!(service.accountSummaries || []).some(function(row) { return row.id === batch.accountId })) return
      root.preparationResult(batch.accountId,"request",!!failure)
      if (failure) {
        root.error = "AI descriptions could not start. Check the AI connection, then choose Menu → Retry AI descriptions."
        var next = Object.assign({},root.overviews)
        for (var messageIndex=0;messageIndex<batch.ids.length;messageIndex++)
          next[root.key(batch.accountId,batch.ids[messageIndex])] = {state:"failed",reason:"AI request could not start; retry from Menu",updated:Date.now()}
        root.overviews = next
      }
      root.retryFailed = false
    })
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
    if (!available || sharedScheduler || ticking) return
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
    function onAccountSummariesChanged() { root.retainAccounts() }
    function onRawMessagesChanged() { refreshSoon.restart() }
    function onAlwaysShowImagesChanged() { root.savePreparationPreferences("allowRemoteImages",service.alwaysShowImages === true) }
  }
  Timer { id: refreshSoon; interval: 300; onTriggered: root.refresh() }
  Timer { interval: 5000; repeat: true; running: root.browsing || Object.keys(root.preferenceQueue).length > 0 || Object.keys(root.notificationRows).some(function(account) { return Object.keys(root.notificationRows[account]).length > 0 }); onTriggered: root.refresh() }
  Timer { interval: 30000; repeat: true; running: root.available && !root.sharedScheduler; onTriggered: root.tick() }
  Timer { interval: 8000; running: root.notice !== "" && root.notice !== "Snoozing"; onTriggered: root.notice = "" }
  Component.onCompleted: if (available) { refresh(); tick() }
}

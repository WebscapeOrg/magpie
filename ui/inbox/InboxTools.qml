import QtQuick
import "Readiness.js" as Readiness
import "PointArrivals.js" as Arrivals
Item {
  id: root
  required property var service
  property var visibleRows: []
  readonly property bool browsing: !!service && service.windowOpen === true
  readonly property bool preparesInbox: !!service && service.hasAgent !== false
  property var overviews: ({})
  property var avatars: ({})
  property string avatarRefreshId: ""
  property int avatarEpoch: 0
  function refreshAvatars() { avatarEpoch++; avatarRefreshId = "images-" + Date.now(); avatars = ({}); avatarPending = ({}); avatarChecked = ({}); drain() }
  property var avatarPending: ({})
  // Invariant: the engine's sender-picture revision; a change asks visible senders again, keeping
  // their current picture until the new one arrives. -1 until a snapshot reports one.
  property int pictureRevision: -1
  property var avatarChecked: ({})
  function notePictureRevision(revision) {
    if (typeof revision !== "number" || !isFinite(revision) || revision === pictureRevision) return
    if (pictureRevision === -1) {
      var checked = ({})
      for (var name in avatarChecked) checked[name] = revision
      avatarChecked = checked
    }
    pictureRevision = revision
  }
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
    var writing = ({})
    for (var account in writingIds) if (owners[account]) writing[account] = writingIds[account]
    writingIds = writing
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
  // Invariant: Points are written for this view only in the curated Inbox, with Show the Point on and
  // an engine that writes them; anywhere else every row shows its subject.
  readonly property bool writesPoints: !!service && preparesInbox && available && descriptionsEnabled && service.curatedInbox === true
  // When Claude or the AI worker stopped answering, cleared by the next Point written.
  property double unansweredSince: 0
  // The earliest silence still unbroken: Claude's, or the engine's own calls failing.
  readonly property double failingSince: {
    var since = unansweredSince
    for (var name in preparationFailures) if (!since || preparationFailures[name] < since) since = preparationFailures[name]
    return since
  }
  // Invariant: a lasting problem that stops every new Point, named in one line above the Inbox:
  // "paused", "subscriptions" (every Claude subscription out) or "unanswered" (no answer for 15
  // minutes while Points wait). Anything shorter shows as Points being written.
  readonly property string hold: {
    if (!writesPoints) return ""
    var rows = service.rawMessages || []
    var unfinished = false, writing = false, spent = 0, written = 0
    for (var i=0;i<rows.length;i++) {
      var value = overviewFor(rows[i]), updated = Number(value.updated || 0)
      if (Readiness.ready(value, overviewClock)) { written = Math.max(written, updated); continue }
      if (Readiness.previousPoint(value)) continue
      unfinished = true
      if (Readiness.problem(value) === Readiness.SUBSCRIPTIONS_OUT) spent = Math.max(spent, updated)
      if (Readiness.status(value, overviewClock, false) === "writing") writing = true
    }
    if (!unfinished) return ""
    if (paused) return "paused"
    // A Point written since the last refusal means a subscription is back.
    if (spent > written) return "subscriptions"
    return writing && failingSince > 0 && overviewClock - failingSince >= 900000 ? "unanswered" : ""
  }
  readonly property string holdText: hold === "paused" ? "New Points are paused."
    : hold === "subscriptions" ? "Your Claude subscriptions are all used up for now. Points continue when one resets."
    : hold === "unanswered" ? "Claude has not answered for " + Readiness.waited(overviewClock - failingSince) + ". Magpie keeps trying."
    : ""
  function status(row) {
    if (!writesPoints) return "plain"
    return Readiness.status(overviewFor(row), overviewClock, hold !== "")
  }
  // How many Inbox rows show moving lines while Magpie writes their Point.
  readonly property int writingCount: {
    if (!writesPoints || hold !== "") return 0
    var rows = service.rawMessages || [], count = 0
    for (var i=0;i<rows.length;i++) if (Readiness.status(overviewFor(rows[i]), overviewClock, false) === "writing") count++
    return count
  }
  property bool selecting: false
  property var writingIds: ({})
  property bool motionEnabled: true
  property var arrivalState: ({queued:[], delivered:[], scope:""})
  readonly property bool arrivalEnabled: writesPoints && hold === "" && !selecting
  readonly property string arrivalScope: JSON.stringify([service ? service.activeAccountId : "", service ? service.mailboxKey : "", service ? service.rawLabelId : "", service ? service.searchQuery : "", arrivalEnabled])
  function activePoint(row) {
    var host = owner(row)
    return !!host && (writingIds[host.accountId] || []).indexOf(id(row)) >= 0
  }
  readonly property string arrivalSignature: JSON.stringify((service ? service.rawMessages || [] : []).map(function(row) {
    return [row.id, Readiness.status(root.overviewFor(row), root.overviewClock, false), root.activePoint(row)]
  })) + arrivalScope
  onArrivalSignatureChanged: reconcileArrivals()
  function reconcileArrivals() {
    arrivalState = Arrivals.update(arrivalState, service ? service.rawMessages || [] : [], overviewFor, activePoint, overviewClock, arrivalEnabled, arrivalScope)
  }
  readonly property var stack: Arrivals.projection(arrivalState, service ? service.rawMessages || [] : [], arrivalEnabled)
  readonly property string readyArrivalId: {
    var rows = service ? service.rawMessages || [] : []
    var row = rows.find(function(row) { return row.id === root.arrivalState.queued[0] })
    return row && Readiness.ready(overviewFor(row), overviewClock) ? row.id : ""
  }
  property string departingId: ""
  onReadyArrivalIdChanged: {
    arrivalTimer.stop()
    departingId = readyArrivalId
    if (readyArrivalId !== "") arrivalTimer.restart()
  }
  Timer {
    id: arrivalTimer
    interval: root.motionEnabled ? 220 : 0
    onTriggered: {
      var id = root.departingId
      root.departingId = ""
      root.arrivalState = Arrivals.finish(root.arrivalState, id)
    }
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
    if (!preparesInbox) return rows
    var values = overviews; var at = overviewClock
    return rows.filter(function(row) { return Readiness.ready(values[key(account, id(row))], at) })
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
      var active = Object.assign({}, root.writingIds)
      active[account] = !failure && result && Array.isArray(result.writingIds) ? result.writingIds : []
      root.writingIds = active
      if (failure || !result) return
      var next = Object.assign({},root.overviews)
      for (var oldKey in next) if (oldKey.indexOf(account + "\n") === 0) delete next[oldKey]
      if (result.preferences && settingsRevision === root.preferenceRevision && root.preferenceWrites === 0 && !root.preferenceQueue[account]) {
        var prefs = Object.assign({},root.preparationSettings); prefs[account] = result.preferences; root.preparationSettings = prefs
        root.paused = (service.accountSummaries || []).some(function(row) { return prefs[row.id] && prefs[row.id].paused === true })
      }
      var values = result.overviews || ({})
      var written = false, silent = false
      for (var message in values) {
        var name = root.key(account,message), value = values[message]
        if (!Readiness.ready(root.overviews[name], root.overviewClock) && Readiness.ready(value, root.overviewClock)) written = true
        // Asked in the last two minutes and Claude or the worker did not answer.
        else if (value && value.state === "failed" && Readiness.UNANSWERED.indexOf(Readiness.problem(value)) >= 0
          && Date.now() - Number(value.updated || 0) < 120000) silent = true
        next[name] = value
      }
      if (written) root.unansweredSince = 0
      else if (silent && !root.unansweredSince) root.unansweredSince = Date.now()
      root.overviews = next
      var kept = root.snoozes.filter(function(snooze) { return snooze.accountId !== account })
      root.snoozes = kept.concat(result.snoozes || [])
      root.notePictureRevision(result.pictures)
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
    var ready = ids.filter(function(id) { return !root.preparesInbox || Readiness.ready(overviews[key(account,id)],overviewClock) })
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
        if (!root.preparesInbox || Readiness.ready(root.overviews[root.key(account,id)],root.overviewClock)) {
          admitted.push(root.preparesInbox ? Object.assign({},current[id],{subject:root.overviews[root.key(account,id)].text,snippet:""}) : current[id]); delete remaining[id]
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
  }
  // Invariant: Claude's silence counts only while the window is open and asking, so an opened window
  // never starts with an old one.
  onBrowsingChanged: { unansweredSince = 0; if (browsing) refresh() }
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
    if (!preparesInbox || batch.ids.length === 0) return
    requesting = true
    service.backend.call("inbox.overviews", {accountId:batch.accountId,ids:batch.ids,retry:retryFailed,allowRemoteImages:service.alwaysShowImages === true}, function(result,failure) {
      root.requesting = false
      if (!(service.accountSummaries || []).some(function(row) { return row.id === batch.accountId })) return
      root.preparationResult(batch.accountId,"request",!!failure)
      if (failure) {
        root.error = "Magpie could not start writing Points. Check the AI connection, then choose Menu → Retry Points."
        var next = Object.assign({},root.overviews)
        for (var messageIndex=0;messageIndex<batch.ids.length;messageIndex++)
          next[root.key(batch.accountId,batch.ids[messageIndex])] = {state:"failed",reason:"AI request could not start; retry from Menu",problem:"overview_start_failed",updated:Date.now()}
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
    var known = avatars[cacheKey] !== undefined
    if ((known && avatarChecked[cacheKey] === pictureRevision) || avatarPending[cacheKey]) return
    if (Object.keys(avatarPending).length >= 3) return
    avatarPending[cacheKey] = true
    var epoch = avatarEpoch
    var revision = pictureRevision
    service.backend.call("inbox.avatar", {accountId:host.accountId,email:email,refreshId:known ? "" : avatarRefreshId}, function(result,failure) {
      if (epoch !== root.avatarEpoch) return
      delete root.avatarPending[cacheKey]
      var next = Object.assign({},root.avatars)
      if (!failure && result) next[cacheKey] = String(result.data || "")
      else if (!known) next[cacheKey] = ""
      root.avatars = next
      var checked = Object.assign({},root.avatarChecked); checked[cacheKey] = revision; root.avatarChecked = checked
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

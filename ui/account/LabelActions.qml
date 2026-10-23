import QtQuick
import "Model.js" as Model

// Invariant: Reload labels after server mutation because the server assigns their identities.
QtObject {
  id: labelActions

  required property var account
  property bool retired: false

  // Performance: Bound simultaneous watched-label requests at every refresh.
  property bool monitoredLoading: false
  readonly property int monitorConcurrency: 3
  property var monitorHandles: []
  property var monitorQueue: []
  property var monitorGrown: []
  property int monitorRemaining: 0
  // Invariant: Late replies from an abandoned poll cannot reduce the next poll's outstanding count.
  property int monitorSerial: 0

  function refreshMonitored() {
    var ids = Array.isArray(account.monitoredIds) ? account.monitoredIds : []
    if (!account.ready || monitoredLoading || ids.length === 0) return
    monitoredLoading = true
    monitorSerial++
    monitorQueue = ids.map(function(id) { return String(id) })
    monitorGrown = []
    monitorRemaining = monitorQueue.length
    for (var slotIndex = 0; slotIndex < monitorConcurrency; slotIndex++) nextMonitorCount()
  }

  function nextMonitorCount() {
    if (monitorQueue.length === 0) return
    var labelId = monitorQueue[0]
    monitorQueue = monitorQueue.slice(1)
    var serial = monitorSerial
    var answered = false
    var handle = account.api.getLabelCounts(labelId, function(counts, error) {
      if (!labelActions || labelActions.retired || serial !== monitorSerial || answered) return
      answered = true
      monitorHandles = monitorHandles.filter(function(pendingHandle) { return pendingHandle !== handle })
      if (!error && counts) recordMonitorCount(labelId, counts)
      monitorCountDone()
    })
    // Invariant: A synchronous provider reply may finish before a request handle is returned.
    if (!handle && !answered) { answered = true; monitorCountDone(); return }
    if (handle && !answered) monitorHandles = monitorHandles.concat([handle])
  }

  function monitorCountDone() {
    monitorRemaining--
    if (monitorRemaining > 0) { nextMonitorCount(); return }
    monitoredLoading = false
    if (monitorGrown.length > 0) account.note(Model.monitoredNote(monitorGrown))
    monitorGrown = []
    account.cache.putLabels(account.labels)
  }

  function recordMonitorCount(labelId, counts) {
    var index = Model.indexById(account.labels, labelId)
    if (index < 0) return
    var before = Math.max(0, Math.floor(Number(account.labels[index].unread) || 0))
    var after = Math.max(0, Math.floor(Number(counts.unread) || 0))
    var updated = {}
    for (var key in account.labels[index]) updated[key] = account.labels[index][key]
    updated.unread = after
    updated.total = Math.max(0, Math.floor(Number(counts.total) || 0))
    account.labels = Model.replaceById(account.labels, updated)
    if (after > before && monitoredSeen[labelId] !== undefined)
      monitorGrown = monitorGrown.concat([{ name: String(updated.name || labelId), delta: after - before }])
    var seen = Object.create(null)
    for (var currentLabelId in monitoredSeen) seen[currentLabelId] = monitoredSeen[currentLabelId]
    seen[labelId] = after
    monitoredSeen = seen
  }

  function abortMonitored() {
    var handles = monitorHandles
    monitorSerial++
    monitorHandles = []
    monitorQueue = []
    monitorRemaining = 0
    monitorGrown = []
    monitoredLoading = false
    for (var handleIndex = 0; handleIndex < handles.length; handleIndex++) account.abortRequest(handles[handleIndex])
  }

  readonly property bool ready: !!account && account.ready
  onReadyChanged: if (!ready) abortMonitored()
  Component.onDestruction: { retired = true; abortMonitored() }

  // Invariant: The initial watched-label read establishes counts without announcing historical mail.
  property var monitoredSeen: Object.create(null)

  function labelById(id) {
    var index = Model.indexById(account.labels, id)
    return index >= 0 ? account.labels[index] : null
  }

  function labelPathOf(label) {
    return label ? String(label.name || "") : ""
  }

  function labelByPath(path) {
    for (var labelIndex = 0; labelIndex < account.labels.length; labelIndex++) if (labelPathOf(account.labels[labelIndex]) === String(path || "")) return account.labels[labelIndex]
    return null
  }

  // Invariant: Duplicate display paths would make the post-mutation identity lookup ambiguous.
  function takenProblem(name) {
    return labelByPath(name) ? "There is already a label named " + name : ""
  }

  function createLabel(parentPath, leaf) {
    if (!account.ready) return false
    var problem = Model.labelNameProblem(leaf)
    var name = Model.labelPathJoin(parentPath, leaf)
    problem = problem || takenProblem(name)
    if (problem !== "") { account.fail(problem); return false }
    account.api.createLabel(name, function(payload, error) {
      if (!labelActions || labelActions.retired) return
      if (error) { account.fail("Could not create " + name + ": " + String(error)); return }
      account.note("Created " + name)
      reloadLabels()
    })
    return true
  }

  function renameLabel(id, leaf) {
    var label = labelById(id)
    if (!account.ready || !label) return false
    var problem = Model.labelNameProblem(leaf)
    if (problem !== "") { account.fail(problem); return false }
    var path = labelPathOf(label)
    var name = Model.labelPathJoin(Model.labelParent(path), leaf)
    if (name === path) return false
    problem = takenProblem(name)
    if (problem !== "") { account.fail(problem); return false }
    account.api.renameLabel(String(label.id), name, function(payload, error) {
      if (!labelActions || labelActions.retired) return
      if (error) { account.fail("Could not rename " + path + ": " + String(error)); return }
      account.note("Renamed to " + name)
      afterLabelMoved(label)
    })
    return true
  }

  function moveLabel(id, newParentPath) {
    var label = labelById(id)
    if (!account.ready || !label) return false
    var path = labelPathOf(label)
    var parent = String(newParentPath || "")
    if (parent === path || parent.indexOf(path + "/") === 0) return false
    var name = Model.labelPathJoin(parent, Model.labelLeaf(path))
    if (name === path) return false
    var problem = takenProblem(name)
    if (problem !== "") { account.fail(problem); return false }
    account.api.renameLabel(String(label.id), name, function(payload, error) {
      if (!labelActions || labelActions.retired) return
      if (error) { account.fail("Could not move " + path + ": " + String(error)); return }
      account.note("Moved to " + name)
      afterLabelMoved(label)
    })
    return true
  }

  function deleteLabel(id) {
    var label = labelById(id)
    if (!account.ready || !label) return false
    var path = labelPathOf(label)
    account.api.deleteLabel(String(label.id), function(payload, error) {
      if (!labelActions || labelActions.retired) return
      if (error) { account.fail("Could not delete " + path + ": " + String(error)); return }
      account.note("Deleted " + path)
      if (account.rawLabelId === String(label.id)) account.selectMailbox("inbox")
      reloadLabels()
    })
    return true
  }

  property string followLabelId: ""
  property bool reloadRetried: false
  property bool reloading: false
  property bool reloadQueued: false
  property Timer reloadRetry: Timer {
    interval: 0
    onTriggered: labelActions.reloadLabels()
  }

  function afterLabelMoved(label) {
    if (account.rawQuery !== "" && account.rawLabelId === String(label.id || ""))
      followLabelId = String(label.id || "")
    reloadLabels()
  }

  function reloadLabels() {
    if (retired || !account.ready) return
    if (reloading) { reloadQueued = true; return }
    reloading = true
    account.api.getLabels(function(result, error) {
      if (!labelActions || labelActions.retired) return
      reloading = false
      // Invariant: A listing begun before a later mutation cannot settle that mutation.
      if (reloadQueued) {
        reloadQueued = false
        reloadLabels()
        return
      }
      if (error) {
        // Invariant: Retry once without clearing watched labels or the open label after a failed listing.
        account.fail("Could not read the labels back: " + String(error))
        if (!reloadRetried) { reloadRetried = true; reloadRetry.start() }
        return
      }
      reloadRetried = false
      account.labels = result
      account.cache.putLabels(result)
      var watched = Array.isArray(account.monitoredIds) ? account.monitoredIds : []
      var next = Model.retainedMonitoredIds(watched, result)
      if (next !== watched) account.monitoredMigrated(next)
      if (followLabelId !== "") {
        var moved = labelById(followLabelId)
        var wasSelected = account.rawLabelId === followLabelId
        followLabelId = ""
        if (!wasSelected) return
        if (moved) account.selectLabel(String(moved.name || ""), String(moved.id || ""))
        else account.selectMailbox("inbox")
      }
    })
  }
}

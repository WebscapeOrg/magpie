import QtQuick
import "Model.js" as Model
import "../providers/Registry.js" as Provider

// Invariant: Reload labels after server mutation because the server assigns their identities.
QtObject {
  id: labelActions

  required property var account

  // Performance: Bound watched-label requests to avoid opening one connection per folder at every refresh.
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
      if (!labelActions || serial !== monitorSerial || answered) return
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
  Component.onDestruction: abortMonitored()

  // Invariant: The initial watched-label read establishes counts without announcing historical mail.
  property var monitoredSeen: Object.create(null)

  readonly property bool canManageLabels: Provider.can(account.providerId, "manageLabels")

  function labelById(id) {
    var index = Model.indexById(account.labels, id)
    return index >= 0 ? account.labels[index] : null
  }

  // Invariant: Display paths are decoded; existing IMAP folders are addressed with their original wire ids.
  function labelPathOf(label) {
    return label ? String(label.name || label.rawName || "") : ""
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
    if (!account.ready || !canManageLabels) return false
    var parent = labelByPath(parentPath)
    var delimiter = Model.labelDelimiter(parent || (account.labels.length > 0 ? account.labels[0] : null))
    var problem = Model.labelNestProblem(parentPath, delimiter) || Model.labelNameProblem(leaf, delimiter)
    var name = Model.labelPathJoin(parentPath, leaf, delimiter)
    problem = problem || takenProblem(name)
    if (problem !== "") { account.fail(problem); return false }
    account.api.createLabel(name, function(payload, error) {
      if (!labelActions) return
      if (error) { account.fail("Could not create " + name + ": " + String(error)); return }
      account.note("Created " + name)
      reloadLabels()
    })
    return true
  }

  function renameLabel(id, leaf) {
    var label = labelById(id)
    if (!account.ready || !canManageLabels || !label) return false
    var delimiter = Model.labelDelimiter(label)
    var problem = Model.labelNameProblem(leaf, delimiter)
    if (problem !== "") { account.fail(problem); return false }
    var path = labelPathOf(label)
    var name = Model.labelPathJoin(Model.labelParent(path, delimiter), leaf, delimiter)
    if (name === path) return false
    problem = takenProblem(name)
    if (problem !== "") { account.fail(problem); return false }
    var before = account.labels
    account.api.renameLabel(String(label.id), name, function(payload, error) {
      if (!labelActions) return
      if (error) { account.fail("Could not rename " + path + ": " + String(error)); return }
      account.note("Renamed to " + name)
      afterLabelMoved(label, name, before)
    })
    return true
  }

  function moveLabel(id, newParentPath) {
    var label = labelById(id)
    if (!account.ready || !canManageLabels || !label) return false
    var delimiter = Model.labelDelimiter(label)
    var problem = Model.labelNestProblem(newParentPath, delimiter)
    if (problem !== "") { account.fail(problem); return false }
    var path = labelPathOf(label)
    var name = Model.labelPathJoin(newParentPath, Model.labelLeaf(path, delimiter), delimiter)
    if (name === path) return false
    problem = takenProblem(name)
    if (problem !== "") { account.fail(problem); return false }
    var before = account.labels
    account.api.renameLabel(String(label.id), name, function(payload, error) {
      if (!labelActions) return
      if (error) { account.fail("Could not move " + path + ": " + String(error)); return }
      account.note("Moved to " + name)
      afterLabelMoved(label, name, before)
    })
    return true
  }

  function deleteLabel(id) {
    var label = labelById(id)
    if (!account.ready || !canManageLabels || !label) return false
    var path = labelPathOf(label)
    var before = account.labels
    account.api.deleteLabel(String(label.id), function(payload, error) {
      if (!labelActions) return
      if (error) { account.fail("Could not delete " + path + ": " + String(error)); return }
      account.note("Deleted " + path)
      if (account.rawLabelId === String(label.id)) account.selectMailbox("inbox")
      migrations = migrations.concat([{ before: before, oldPath: path, newPath: "", delimiter: Model.labelDelimiter(label) }])
      reloadLabels()
    })
    return true
  }

  // Invariant: Queue path migrations until a successful listing supplies new wire ids; failed reads cannot discard watched-folder moves.
  property string followLabelPath: ""
  property var migrations: []
  property bool reloadRetried: false
  property bool reloading: false
  property bool reloadQueued: false

  function afterLabelMoved(label, newPath, before) {
    var wasOpen = account.rawQuery !== "" && account.rawLabelId === String(label.id || "")
    followLabelPath = wasOpen ? String(newPath || "") : ""
    migrations = migrations.concat([{ before: before, oldPath: labelPathOf(label), newPath: String(newPath || ""),
      delimiter: Model.labelDelimiter(label) }])
    reloadLabels()
  }

  function reloadLabels() {
    if (!account.ready) return
    if (reloading) { reloadQueued = true; return }
    reloading = true
    account.api.getLabels(function(result, error) {
      if (!labelActions) return
      reloading = false
      // Invariant: A listing begun before a later mutation cannot settle that mutation's migrations.
      if (reloadQueued) {
        reloadQueued = false
        reloadLabels()
        return
      }
      if (error) {
        // Invariant: Retry a failed post-mutation listing once, then retain migrations for a later refresh.
        followLabelPath = ""
        account.fail("Could not read the labels back: " + String(error))
        if (!reloadRetried) { reloadRetried = true; Qt.callLater(reloadLabels) }
        return
      }
      reloadRetried = false
      account.labels = result
      account.cache.putLabels(result)
      var moves = migrations
      migrations = []
      if (moves.length > 0) {
        var watched = Array.isArray(account.monitoredIds) ? account.monitoredIds : []
        var next = Model.migrateMonitoredChanges(watched, moves, result)
        if (next !== watched) account.monitoredMigrated(next)
      }
      if (followLabelPath !== "") {
        var moved = labelByPath(followLabelPath)
        followLabelPath = ""
        if (moved) account.selectLabel(String(moved.rawName || moved.name || ""), String(moved.id || ""))
        else account.selectMailbox("inbox")
      }
    })
  }
}

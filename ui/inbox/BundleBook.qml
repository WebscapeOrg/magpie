import QtQuick
import "Bundles.js" as Bundles

// The Inbox's bundles (Q-019, C-073), one record per account, read from the engine and shaped by
// Bundles.js. Refreshes keep the previous answer until the next one lands, so rows never jump.
// Invariant: the engine alone decides which mails are bundled; approving or refusing goes through
// its answer, and failures are logged rather than shown on the main screen.
Item {
  id: root
  required property var service
  required property var tools
  property bool pointsShown: true

  readonly property var backend: service ? service.backend : null
  // An engine older than bundles lists no such method, so this is checked as well as the API.
  readonly property bool supported: !!backend && backend.ready === true && Number(backend.apiVersion) >= 8
    && !!backend.protocolInfo && Array.isArray(backend.protocolInfo.methods)
    && backend.protocolInfo.methods.indexOf("inbox.bundles") >= 0
  // True only when an engine has answered and cannot do this; a reconnect keeps the last answer.
  readonly property bool absent: !!backend && backend.ready === true && !supported
  readonly property bool applies: !!service && service.curatedInbox === true && pointsShown && !absent

  property var states: ({})
  property var fetched: ({})
  property var answered: ({})
  property var inflight: ({})
  property var dirty: ({})
  property var failures: ({})
  property var fetchesInflight: ({})
  property var changes: ({})
  property int approvedRevision: 0

  readonly property var scopeAccounts: {
    if (!service || !supported) return []
    if (service.unified === true) return (service.accountSummaries || []).map(function(row) { return row.id })
    var active = String(service.activeAccountId || "")
    return active !== "" ? [active] : []
  }
  readonly property bool holding: applies && scopeAccounts.some(function(account) { return !root.answered[account] })
  Timer {
    interval: 1500
    running: root.holding
    onTriggered: {
      console.warn("Magpie bundles: no answer within the first-load wait, showing one row per mail.")
      var next = Object.assign({}, root.answered)
      root.scopeAccounts.forEach(function(account) { next[account] = true })
      root.answered = next
    }
  }

  function accountOf(row) {
    var host = service.hostForId(row.id)
    return host ? String(host.accountId || "") : ""
  }

  function summaryOf(account, id) {
    var own = fetched[account]
    return own ? own[id] : undefined
  }

  readonly property var projected: {
    var rows = service ? service.rawMessages || [] : []
    if (!applies) return {rows: rows, groups: {}, proposals: {}}
    if (holding) return {rows: [], groups: {}, proposals: {}}
    return Bundles.project(rows, states, accountOf, summaryOf)
  }

  function refresh(account) {
    if (!supported || !applies || !account) return
    if (inflight[account]) { dirty[account] = true; return }
    inflight[account] = true
    var seen = changeCount(account)
    backend.call("inbox.bundles", {accountId: account}, function(result, failure) {
      delete root.inflight[account]
      // Invariant: an answer worked out before Dave approved or refused cannot undo that choice.
      if (root.changeCount(account) !== seen) root.dirty[account] = true
      else root.accept(account, result, failure)
      if (root.dirty[account]) { delete root.dirty[account]; root.refresh(account) }
    })
  }

  function changeCount(account) { return Number(changes[account] || 0) }
  function noteChange(account) { changes[account] = changeCount(account) + 1 }

  // An answer of any kind ends the first-load wait. A failure that is not the first keeps the last
  // good answer, so a passing fault never jumps the rows; three in a row fall back to one row per mail.
  function accept(account, result, failure) {
    if (!(service.accountSummaries || []).some(function(row) { return row.id === account })) return
    if (!root.answered[account]) { var now = Object.assign({}, root.answered); now[account] = true; root.answered = now }
    if (failure || !result || !Array.isArray(result.bundles)) {
      console.warn("Magpie bundles: could not read bundles:", failure ? String(failure.message || failure) : "bad answer")
      root.failures[account] = Number(root.failures[account] || 0) + 1
      if (root.failures[account] >= 3 && root.states[account]) {
        var dropped = Object.assign({}, root.states); delete dropped[account]; root.states = dropped
      }
      return
    }
    root.failures[account] = 0
    var next = {bundles: result.bundles, proposals: Array.isArray(result.proposals) ? result.proposals : []}
    if (JSON.stringify(root.states[account] || null) !== JSON.stringify(next)) {
      var updated = Object.assign({}, root.states); updated[account] = next; root.states = updated
    }
    root.fetchCovered(account)
  }

  // Mail bundled behind a front row may not be in the loaded page; its summary is read so the row's
  // unread state, the reader's list and the actions can reach it.
  function fetchCovered(account) {
    if (fetchesInflight[account]) return
    var state = states[account]
    var loaded = ({})
    var rows = service.rawMessages || []
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      if (accountOf(rows[rowIndex]) === account) loaded[Bundles.sourceId(rows[rowIndex])] = true
    }
    var wanted = []
    var bundles = state && Array.isArray(state.bundles) ? state.bundles : []
    for (var bundleIndex = 0; bundleIndex < bundles.length; bundleIndex++) {
      var covered = bundles[bundleIndex].covered || []
      for (var coveredIndex = 0; coveredIndex < covered.length; coveredIndex++) {
        if (!loaded[covered[coveredIndex]] && wanted.length < 100) wanted.push(String(covered[coveredIndex]))
      }
    }
    if (wanted.length === 0) { dropFetched(account); return }
    var host = service.findAccount ? service.findAccount(account) : null
    fetchesInflight[account] = true
    backend.call("local.summaries", {accountId: account, ids: wanted}, function(result, failure) {
      delete root.fetchesInflight[account]
      if (failure || !result) { console.warn("Magpie bundles: could not read covered mail:", failure ? String(failure.message || failure) : "bad answer"); return }
      var rows = result.summaries || []
      var own = ({})
      for (var summaryIndex = 0; summaryIndex < rows.length; summaryIndex++) {
        if (host && typeof host.hydrateSummary === "function") rows[summaryIndex] = host.hydrateSummary(rows[summaryIndex])
        own[String(rows[summaryIndex].id)] = rows[summaryIndex]
      }
      if (JSON.stringify(root.fetched[account] || null) === JSON.stringify(own)) return
      var updated = Object.assign({}, root.fetched); updated[account] = own; root.fetched = updated
    })
  }

  function dropFetched(account) {
    if (!fetched[account]) return
    var updated = Object.assign({}, fetched); delete updated[account]; fetched = updated
  }

  function approve(rowId) {
    var offer = projected.proposals[rowId]
    if (!offer || !supported) return false
    noteChange(offer.accountId)
    backend.call("inbox.approveBundle", {accountId: offer.accountId, front: offer.front}, function(result, failure) {
      root.noteChange(offer.accountId)
      if (failure) {
        console.warn("Magpie bundles: approve refused:", String(failure.message || failure))
        root.refresh(offer.accountId)
        return
      }
      root.accept(offer.accountId, result, null)
      root.approvedRevision++
    })
    return true
  }

  function dismiss(rowId) {
    var offer = projected.proposals[rowId]
    if (!offer) return false
    return refuseIds(offer.accountId, offer.covered)
  }

  // "Not the same Point": the covered mails come back as rows and stay apart.
  function notTheSamePoint(rowId) {
    var group = projected.groups[rowId]
    if (!group || group.frontId !== rowId) return false
    return refuseIds(group.accountId, group.covered)
  }

  function refuseIds(account, ids) {
    if (!supported || ids.length === 0) return false
    var parts = Bundles.chunks(ids, 64)
    function next() {
      if (parts.length === 0) return
      root.noteChange(account)
      backend.call("inbox.refuseBundle", {accountId: account, ids: parts.shift()}, function(result, failure) {
        root.noteChange(account)
        if (failure) {
          console.warn("Magpie bundles: refuse failed:", String(failure.message || failure))
          root.refresh(account)
          return
        }
        root.accept(account, result, null)
        next()
      })
    }
    next()
    return true
  }

  function groupFor(id) {
    var group = projected.groups[String(id)]
    return group || null
  }

  function frontGroup(id) {
    var group = groupFor(id)
    return group && group.frontId === String(id) ? group : null
  }

  // The row an action pressed on any mail of a bundle belongs to, when that action reaches them all.
  function frontForAction(id, action) {
    var group = groupFor(id)
    return group && Bundles.expandsAction(action) ? group.frontId : ""
  }

  function planAction(ids, action) { return Bundles.plan(ids, action, projected.groups) }

  function readerStops(openId) { return Bundles.readerStops(groupFor(openId), openId) }

  // Opening the row reads every mail in it, in Gmail too, as opening any mail does.
  function markRead(id) {
    if (typeof service.actMany !== "function") return
    var group = frontGroup(id)
    var unread = Bundles.unreadCovered(group)
    if (unread.length === 0) return
    var prepared = prepare(unread)
    var started = service.actMany(unread, "markRead", function() {
      root.release(prepared)
      root.fetchCovered(group.accountId)
    }, true)
    if (!started) release(prepared)
  }

  // A covered mail outside the loaded page is put where the action can find it. The answer says
  // which rows were added, so release() can take them out again and they never reach the bar.
  function prepare(ids) {
    var unreachable = 0, added = []
    for (var index = 0; index < ids.length; index++) {
      var host = service.hostForId(ids[index])
      if (!host) { unreachable++; continue }
      var source = service.sourceIdFor ? service.sourceIdFor(ids[index]) : ids[index]
      var loaded = (host.messages || []).concat(host.previewMessages || []).some(function(row) { return row.id === source })
      if (loaded) continue
      var row = summaryOf(String(host.accountId || ""), source)
      if (!row) { unreachable++; continue }
      host.previewMessages = (host.previewMessages || []).concat([row])
      added.push({host: host, id: source})
    }
    if (unreachable > 0) console.warn("Magpie bundles: mail not yet readable was left out of an action:", unreachable)
    return {added: added}
  }

  function release(prepared) {
    prepared.added.forEach(function(entry) {
      entry.host.previewMessages = (entry.host.previewMessages || []).filter(function(row) { return row.id !== entry.id })
    })
  }

  // Undo for Archive, Trash and Snooze on a bundled row (Q-020), named by how many mails it covers.
  property var undoOffer: null
  property bool undoing: false
  property int undoSerial: 0
  Timer {
    id: undoTimer
    interval: 8000
    onTriggered: root.undoOffer = null
  }

  function offerUndo(offer) {
    undoing = false
    undoOffer = Object.assign({canUndo: true, serial: ++undoSerial}, offer)
    undoTimer.restart()
  }

  function offerEdits(action, count, groups) {
    var usable = (groups || []).filter(function(group) { return (group.tickets || []).length > 0 })
    if (count <= 0 || usable.length === 0) return
    offerUndo({kind: "edit", action: action, count: count, groups: usable, text: Bundles.actionText(action, count)})
  }

  function offerSnooze(count, entries) {
    if (count <= 0 || entries.length === 0) return
    offerUndo({kind: "snooze", action: "snooze", count: count, entries: entries, text: Bundles.actionText("snooze", count)})
  }

  function dismissUndo() { undoTimer.stop(); undoOffer = null; undoing = false }

  function runUndo() {
    var offer = undoOffer
    if (!offer || !offer.canUndo || undoing) return false
    undoing = true
    if (offer.kind === "edit") undoEdits(offer)
    else if (offer.kind === "snooze") undoSnooze(offer)
    return true
  }

  function afterUndo(offer, broken, total) {
    // A newer toast has taken this one's place while the Undo ran; it stays.
    if (undoOffer && undoOffer.serial !== offer.serial) return
    if (broken === 0) { dismissUndo(); return }
    undoing = false
    undoOffer = Object.assign({}, offer, {canUndo: false, text: Bundles.undoFailedText(offer.action, total, offer.count)})
    undoTimer.restart()
  }

  function undoEdits(offer) {
    var remaining = offer.groups.length, broken = 0, total = 0
    offer.groups.forEach(function(group) { total += group.tickets.length })
    offer.groups.forEach(function(group) {
      var host = service.findAccount(group.accountId)
      if (!host || !host.local) { broken += group.tickets.length; if (--remaining === 0) root.afterUndo(offer, broken, total); return }
      host.local.undoEdits(group.tickets, function(brokenCount) {
        broken += Number(brokenCount || 0)
        if (--remaining === 0) root.afterUndo(offer, broken, total)
      })
    })
  }

  function undoSnooze(offer) {
    var remaining = offer.entries.length, broken = 0
    offer.entries.forEach(function(entry) {
      backend.call("inbox.wake", {accountId: entry.accountId, id: entry.id, restore: true}, function(result, failure) {
        // A snooze that has already ended means the mail is back, which is what Undo was for.
        if (failure && String(failure.message || "").indexOf("snooze_missing") < 0) {
          console.warn("Magpie bundles: undo of snooze failed:", String(failure.message || failure))
          broken++
        }
        if (--remaining !== 0) return
        root.afterUndo(offer, broken, offer.entries.length)
        if (typeof root.tools.refresh === "function") root.tools.refresh()
        if (typeof service.refresh === "function") service.refresh()
      })
    })
  }
}

.pragma library

function idOf(row) { return String(row && row.id || "") }

function hasOwn(values, key) { return Object.prototype.hasOwnProperty.call(values, key) }

function merge(rows, overlays) {
  var result = []
  var seen = Object.create(null)
  var values = Array.isArray(rows) ? rows : []
  var changes = overlays || Object.create(null)
  for (var index = 0; index < values.length; index++) {
    var id = idOf(values[index])
    if (!id || seen[id]) continue
    seen[id] = true
    var change = hasOwn(changes, id) ? changes[id] : null
    if (change && change.include === false) continue
    result.push(change ? change.row : values[index])
  }
  for (var key in changes) {
    if (hasOwn(changes, key) && !seen[key] && changes[key].include === true) result.push(changes[key].row)
  }
  result.sort(function(left, right) {
    var difference = Number(right.dateMs || new Date(right.date).getTime() || 0)
      - Number(left.dateMs || new Date(left.date).getTime() || 0)
    if (difference) return difference
    return idOf(left) < idOf(right) ? 1 : idOf(left) > idOf(right) ? -1 : 0
  })
  return result
}

function overlay(previous, rows) {
  var result = Object.create(null)
  var existing = previous || Object.create(null)
  for (var key in existing) if (hasOwn(existing, key)) result[key] = existing[key]
  var values = Array.isArray(rows) ? rows : []
  for (var index = 0; index < values.length; index++) {
    var row = values[index]
    var id = idOf(row)
    if (!id || (!row.pendingEdit && !hasOwn(result, id))) continue
    var prior = hasOwn(result, id) ? result[id] : null
    var membership = row.pendingEdit
      ? row.pendingLabelMatch === false ? false : row.matchesQuery === true ? true : null
      : prior.include
    result[id] = {row: row, include: membership === true ? true : membership === false ? false : null}
  }
  return result
}

function combine(existing, incoming) {
  var byId = Object.create(null)
  var result = []
  var values = (incoming || []).concat(existing || [])
  for (var index = 0; index < values.length; index++) {
    var id = idOf(values[index])
    if (!id || byId[id]) continue
    byId[id] = true
    result.push(values[index])
  }
  return merge(result, Object.create(null))
}

function pendingCount(overlays) {
  var count = 0
  var values = overlays || Object.create(null)
  for (var key in values) if (hasOwn(values, key) && values[key].row.pendingEdit) count++
  return count
}

function pendingText(count) {
  return count > 0 ? " " + count + (count === 1 ? " change is" : " changes are") + " waiting to sync." : ""
}

function status(phase, error, errorCode, pending) {
  var text = phase === "preparing" ? "Preparing search…"
    : phase === "local" ? "Searching saved mail…"
    : phase === "checking" ? "Saved results shown. Checking Gmail…"
    : phase === "complete" ? "Gmail search complete."
    : phase === "stopped" ? "Search stopped. Results may be incomplete."
    : phase === "failed" ? "Gmail search could not finish. Results may be incomplete."
    : phase === "invalid" ? "Check the search query."
    : ""
  text += pendingText(pending)
  return {phase: phase, text: text, error: String(error || ""), errorCode: String(errorCode || ""),
    scope: "", canStop: phase === "preparing" || phase === "local" || phase === "checking",
    canRetry: phase === "failed" || phase === "stopped", pendingCount: pending || 0}
}

function aggregate(states, scope) {
  var values = states || []
  var checking = false, local = false, incomplete = false, complete = false, invalid = false, failed = false
  var errors = [], code = "", pending = 0, stop = false, retry = false
  for (var index = 0; index < values.length; index++) {
    var entry = values[index] || {}
    checking = checking || entry.phase === "checking"
    local = local || entry.phase === "local" || entry.phase === "preparing"
    incomplete = incomplete || entry.phase === "failed" || entry.phase === "stopped"
    failed = failed || entry.phase === "failed"
    complete = complete || entry.phase === "complete"
    invalid = invalid || entry.phase === "invalid"
    if (entry.error) errors.push(String(entry.label || "") + (entry.label ? ": " : "") + entry.error)
    if (!code && entry.errorCode) code = entry.errorCode
    pending += Number(entry.pendingCount || 0)
    stop = stop || entry.canStop === true
    retry = retry || entry.canRetry === true
  }
  var phase = checking ? "checking" : local ? "local" : invalid ? "invalid"
    : incomplete ? (complete ? "partial" : failed ? "failed" : "stopped") : complete ? "complete" : ""
  var result = status(phase, errors.join(" "), code, pending)
  if (phase === "partial") result.text = "Some accounts could not finish searching. Results may be incomplete." + pendingText(pending)
  result.scope = String(scope || "")
  result.canStop = stop
  result.canRetry = retry
  return result
}

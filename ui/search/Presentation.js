.pragma library

function active(status) {
  return !!status && String(status.phase || "") !== ""
}

function busy(status, query, loading, serverLoading) {
  var phase = String((status || {}).phase || "")
  if (phase) return phase === "preparing" || phase === "local" || phase === "checking"
  return String(query || "") !== "" && (loading === true || serverLoading === true)
}

function issue(status) {
  var phase = String((status || {}).phase || "")
  return phase === "invalid" || phase === "failed" || phase === "partial" || phase === "stopped"
}

function issueText(status) {
  var state = status || {}
  var error = String(state.error || "")
  if (state.phase === "invalid") return error || "Check the search query and try again."
  if (state.phase === "stopped") return "Search stopped. Results may be incomplete."
  if (state.phase === "failed" || state.phase === "partial")
    return error ? "Results may be incomplete. " + error : "Search could not finish. Retry to check for more messages."
  return ""
}

function emptyText(status, loading, loaded, searching) {
  var phase = String((status || {}).phase || "")
  if (phase === "preparing" || phase === "local" || phase === "checking") return ""
  if (phase === "stopped") return "Search stopped before all results were checked. Retry to finish."
  if (phase === "failed" || phase === "partial") return "Search could not finish. Retry to check for more messages."
  if (phase === "invalid") return "Edit the search to try again."
  if (phase === "complete") return "No messages match. Try fewer filters or different words."
  if (loading) return searching ? "" : "Fetching the mailbox"
  if (!loaded) return ""
  return searching ? "No messages match. Try fewer filters or different words." : "Nothing here"
}

function rowIds(rows) {
  var ids = []
  for (var index = 0; index < rows.length; index++) ids.push(String(rows[index].id || ""))
  return ids
}

function anchorIndex(anchor, ids) {
  if (!anchor || !ids.length) return -1
  var found = ids.indexOf(anchor.id)
  if (found >= 0) return found
  var positions = Object.create(null)
  for (var index = 0; index < ids.length; index++) positions[ids[index]] = index
  var previous = anchor.ids || []
  for (var next = anchor.index + 1; next < previous.length; next++) {
    found = positions[previous[next]]
    if (found !== undefined) return found
  }
  for (var before = anchor.index - 1; before >= 0; before--) {
    found = positions[previous[before]]
    if (found !== undefined) return found
  }
  return Math.min(Math.max(0, anchor.index), ids.length - 1)
}

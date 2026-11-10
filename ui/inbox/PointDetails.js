.pragma library

function model(value) {
  switch (value) {
    case "haiku": return "Claude Haiku"
    case "sonnet": return "Claude Sonnet"
    case "opus": return "Claude Opus"
    case "claude-haiku-5-5": return "Claude Haiku 5.5"
    case "claude-sonnet-5-5": return "Claude Sonnet 5.5"
    case "claude-opus-5-5": return "Claude Opus 5.5"
    default: return ""
  }
}

function duration(ms) {
  if (typeof ms !== "number" || !isFinite(ms) || ms < 0 || ms > 86400000 || Math.floor(ms) !== ms) return ""
  if (ms < 1000) return ms + " ms"
  if (ms < 60000) return (ms / 1000).toFixed(1) + " seconds"
  return Math.floor(ms / 60000) + " min " + Math.floor(ms / 1000) % 60 + " sec"
}

function rows(value) {
  value = value || {}
  var details = value.details || {}
  var historical = value.state === "ready" || value.state === "stale"
  var requested = model(details.requestedModel)
  var rows = [{title: "Requested model", value: requested || "Not recorded"}]
  var actual = model(details.model) || (historical ? model(value.tier) : "")
  if (actual && actual !== requested) rows.push({title: "Created with", value: actual})
  return rows.concat([
    {title: "Get from Gmail", value: duration(details.gmailMs) || "Not recorded"},
    {title: "Decide on model", value: duration(details.decideMs) || (details.choice === "default" ? "Default model" : "Not recorded")},
    {title: "Create the Point", value: duration(details.createMs) || "Not recorded"},
    {title: "Context tokens sent", value: tokens(details)},
    {title: "Downloaded during", value: activity(details.downloadRun)},
    {title: historical ? "Analysed during" : "Analysis attempted during", value: activity(details.createRun)}])
}

function tokens(details) {
  var n = details && details.contextTokens
  if (typeof n !== "number" || !isFinite(n) || n < 0 || n > 9007199254740991 || Math.floor(n) !== n) return "Not recorded"
  return (details.contextTokensPartial === true ? "At least " : "") + String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

function activity(run) {
  if (!run || typeof run !== "object") return "Not recorded"
  for (var i = 0; i < 2; i++) {
    var at = run[i === 0 ? "startedAt" : "finishedAt"]
    if (typeof at !== "number" || !isFinite(at) || Math.floor(at) !== at || at < 1 || at > 9007199254740991) return "Not recorded"
  }
  if (run.origin === "desktop") return run.startedActive === undefined && run.finishedActive === undefined && run.leftApp === undefined ? "The main machine" + (run.remainingText === true ? " (remaining text)" : "") : "Not recorded"
  if (run.origin !== "app" && run.origin !== "backgroundRefresh") return "Not recorded"
  if (typeof run.startedActive !== "boolean" || typeof run.finishedActive !== "boolean" || typeof run.leftApp !== "boolean") return "Not recorded"
  var label = run.origin === "backgroundRefresh" ? "Background refresh" : run.startedActive ? "While using Magpie" : "After leaving Magpie"
  if (run.origin === "backgroundRefresh" && run.startedActive) label += "; app already open"
  if (run.remainingText === true) label += " (remaining text)"
  if (run.leftApp) return label + "; app left during this step"
  if (!run.startedActive && run.finishedActive) return label + "; app opened during this step"
  return label
}

function note(value) {
  value = value || {}
  var details = value.details || {}, size = details.batchSize, known = tokens(details) !== "Not recorded"
  var note = ""
  if (typeof size === "number" && size >= 2 && size <= 4 && Math.floor(size) === size)
    note = known ? "The writing time and token count are shared by " + size + " Points written together." : "The writing time is shared by " + size + " Points written together."
  else if (value.state === "running" || value.state === "waiting") note = "The Point is not finished yet."
  if (known) note += (note ? " " : "") + "This counts reported input across writing passes, including reused context."
  return note
}

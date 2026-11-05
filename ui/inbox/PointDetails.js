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
    {title: "Create the Point", value: duration(details.createMs) || "Not recorded"}])
}

function note(value) {
  value = value || {}
  var size = value.details && value.details.batchSize
  if (typeof size === "number" && size >= 2 && size <= 4 && Math.floor(size) === size)
    return "The writing time is shared by " + size + " Points written together."
  return value.state === "running" || value.state === "waiting" ? "The Point is not finished yet." : ""
}

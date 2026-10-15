.pragma library

var SINGLE = "Single pane"
var SPLIT = "Split view"
var REGIONS = ["interface", "list", "message"]

function size(value) {
  var number = Number(value)
  return isFinite(number) && number >= 8 && number <= 36 ? Math.round(number) : 17
}

function family(value) {
  return typeof value === "string" && value.length <= 160
    && !/[\x00-\x1f<>]/.test(value) ? value.trim() : ""
}

function normalize(raw) {
  var source = raw && typeof raw === "object" ? raw : {}
  var result = {layout: source.layout === SPLIT ? SPLIT : SINGLE}
  for (var i = 0; i < REGIONS.length; i++) {
    var region = REGIONS[i]
    result[region + "Family"] = source[region + "Family"] === undefined
      ? "Chillax Light" : family(source[region + "Family"])
    result[region + "Size"] = size(source[region + "Size"])
  }
  return result
}

function changed(raw, key, value) {
  var result = normalize(raw)
  if (Object.prototype.hasOwnProperty.call(result, key)) result[key] = value
  return normalize(result)
}

function readWindow(raw) {
  try { return JSON.parse(String(raw || "{}")) || {} } catch (error) { return {} }
}

function fromWindow(raw) {
  return normalize(readWindow(raw).display)
}

function zoomForWindow(raw, savedZoom) {
  var display = readWindow(raw).display
  return display && typeof display === "object" && !Array.isArray(display) ? savedZoom : 1
}

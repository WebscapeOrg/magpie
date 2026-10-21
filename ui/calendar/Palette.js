.pragma library

var SLOT_KEYS = ["accent", "red", "green", "yellow", "blue", "magenta", "cyan"]
var ANSI_KEYS = {
  red: "color1", green: "color2", yellow: "color3", blue: "color4",
  magenta: "color5", cyan: "color6"
}

function keys() { return SLOT_KEYS.slice() }

function normalizeKey(value) {
  var key = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
  return SLOT_KEYS.indexOf(key) >= 0 ? key : ""
}

function defaultKey(identity) {
  var text = String(identity || "")
  var hash = 0
  for (var index = 0; index < text.length; index++) hash = ((hash * 31) + text.charCodeAt(index)) >>> 0
  return SLOT_KEYS[hash % SLOT_KEYS.length]
}

function parse(raw) {
  var values = {}
  var lines = String(raw || "").split("\n")
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    var match = lines[lineIndex].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (match) values[match[1].toLowerCase()] = match[2]
  }
  var result = {}
  for (var slotKeyIndex = 0; slotKeyIndex < SLOT_KEYS.length; slotKeyIndex++) {
    var key = SLOT_KEYS[slotKeyIndex]
    var value = values[key] || values[ANSI_KEYS[key]] || ""
    if (value !== "") result[key] = value
  }
  return result
}

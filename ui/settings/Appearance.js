.pragma library

// Invariant: standalone palette preferences apply only when no Omarchy theme is active.
var SYSTEM = "System"
var LIGHT = "Light"
var DARK = "Dark"
var MODES = [SYSTEM, LIGHT, DARK]
var MODE_DEFAULT = SYSTEM

// Invariant: stored appearance labels remain case-insensitive for older window preference values.
function normalizeMode(value) {
  var text = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
  for (var modeIndex = 0; modeIndex < MODES.length; modeIndex++) if (MODES[modeIndex].toLowerCase() === text) return MODES[modeIndex]
  return MODE_DEFAULT
}

function paletteFor(mode) {
  var normalized = normalizeMode(mode)
  if (normalized === LIGHT) return "light"
  if (normalized === DARK) return "dark"
  return ""
}

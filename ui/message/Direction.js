.pragma library
.import "DirectionData.js" as Bidi

// Invariant: Qt handles paragraph layout; this module excludes client-added subject/body
// prefixes and applies the user's direction preference. Modes match settings labels.
var AUTO = "Auto"
var LEFT_TO_RIGHT = "Left to right"
var RIGHT_TO_LEFT = "Right to left"
var MODE_DEFAULT = AUTO

var LTR = "ltr"
var RTL = "rtl"
// Invariant: An absent answer leaves Qt free to resolve each paragraph.
var UNKNOWN = ""

function normalizeMode(value) {
  var text = String(value === undefined || value === null ? "" : value)
  if (text === RIGHT_TO_LEFT) return RIGHT_TO_LEFT
  if (text === LEFT_TO_RIGHT) return LEFT_TO_RIGHT
  return AUTO
}

function isRightToLeft(direction) {
  return String(direction) === RTL
}

var LEFT_TO_RIGHT_EMBEDDING = 0x202A
var RIGHT_TO_LEFT_EMBEDDING = 0x202B
var LEFT_TO_RIGHT_OVERRIDE = 0x202D
var RIGHT_TO_LEFT_OVERRIDE = 0x202E
var LEFT_TO_RIGHT_ISOLATE = 0x2066
var RIGHT_TO_LEFT_ISOLATE = 0x2067
var FIRST_STRONG_ISOLATE = 0x2068
var POP_DIRECTIONAL_ISOLATE = 0x2069

function directionOfCode(code) {
  if (typeof code !== "number" || code !== Math.floor(code) || code < 0 || code > 0x10FFFF
      || (code >= 0xD800 && code <= 0xDFFF)) return UNKNOWN
  var low = 0
  var high = Bidi.RANGES.length
  while (low < high) {
    var middle = Math.floor((low + high) / 2)
    if (Bidi.RANGES[middle][1] < code) low = middle + 1
    else high = middle
  }
  if (low < Bidi.RANGES.length && Bidi.RANGES[low][0] <= code) return Bidi.RANGES[low][2]
  return LTR
}

// Algorithm: Unicode UAX #9 P2/P3 (https://www.unicode.org/reports/tr9/tr9-51.html).
// Invariant: Preserve the app's explicit
// embedding/override policy; Qt handles the remaining bidirectional algorithm.
function strongDirectionOf(text) {
  var source = String(text === undefined || text === null ? "" : text)
  var depth = 0

  for (var characterIndex = 0; characterIndex < source.length; characterIndex++) {
    var code = source.charCodeAt(characterIndex)

    if (code >= 0xD800 && code <= 0xDBFF && characterIndex + 1 < source.length) {
      var low = source.charCodeAt(characterIndex + 1)
      if (low >= 0xDC00 && low <= 0xDFFF) {
        code = (code - 0xD800) * 0x400 + (low - 0xDC00) + 0x10000
        characterIndex++
      }
    }

    if (code === LEFT_TO_RIGHT_ISOLATE || code === RIGHT_TO_LEFT_ISOLATE
        || code === FIRST_STRONG_ISOLATE) {
      depth++
      continue
    }
    if (code === POP_DIRECTIONAL_ISOLATE) {
      if (depth > 0) depth--
      continue
    }
    if (depth > 0) continue

    if (code === RIGHT_TO_LEFT_EMBEDDING || code === RIGHT_TO_LEFT_OVERRIDE) return RTL
    if (code === LEFT_TO_RIGHT_EMBEDDING || code === LEFT_TO_RIGHT_OVERRIDE) return LTR

    var direction = directionOfCode(code)
    if (direction !== UNKNOWN) return direction
  }
  return UNKNOWN
}

// Invariant: Only recognized client prefixes and list tags are skipped; an arbitrary
// word before a colon is part of the subject.
var REPLY_PREFIX = new RegExp(
  "^[\\s\\u200E\\u200F]*(?:"
    + "(?:re|aw|sv|vs|vl|antw|antwort|fw|fwd|wg|tr|rv|rif|res|enc|encaminhado"
    + "|doorst|odp|ynt|ilt|回复|回覆|转发|轉發)"
    + "\\s*(?:[\\[\\(]\\s*\\d+\\s*[\\]\\)])?\\s*:"
    + "|\\[[^\\]]{0,64}\\]"
    + "|\\((?:fwd|fw)\\)"
  + ")[\\s\\u200E\\u200F]*", "i")

function withoutReplyPrefixes(subject) {
  var text = String(subject === undefined || subject === null ? "" : subject)
  // Invariant: Limit cleanup work for untrusted stacks of client-added prefixes.
  for (var index = 0; index < 12; index++) {
    var stripped = text.replace(REPLY_PREFIX, "")
    if (stripped === text) break
    text = stripped
  }
  return text
}

function subjectDirectionOf(subject) {
  return strongDirectionOf(withoutReplyPrefixes(subject))
}

function resolve(text, mode) {
  var chosen = normalizeMode(mode)
  if (chosen === RIGHT_TO_LEFT) return RTL
  if (chosen === LEFT_TO_RIGHT) return LTR
  return strongDirectionOf(text)
}

// Invariant: Auto leaves native Qt fields to resolve their own content direction.
function forced(mode) {
  var chosen = normalizeMode(mode)
  if (chosen === RIGHT_TO_LEFT) return RTL
  if (chosen === LEFT_TO_RIGHT) return LTR
  return UNKNOWN
}

function resolveSubject(subject, mode) {
  var chosen = normalizeMode(mode)
  if (chosen === RIGHT_TO_LEFT) return RTL
  if (chosen === LEFT_TO_RIGHT) return LTR
  return subjectDirectionOf(subject)
}

// Invariant: Generated image markers are client text and must not choose body direction.
var IMAGE_MARKERS = /^(?:\s*\[image(?:\s+\d+)?\])+/

function withoutImageMarkers(text) {
  return String(text === undefined || text === null ? "" : text).replace(IMAGE_MARKERS, "")
}

function resolveBody(text, mode) {
  var chosen = normalizeMode(mode)
  if (chosen === RIGHT_TO_LEFT) return RTL
  if (chosen === LEFT_TO_RIGHT) return LTR
  return strongDirectionOf(withoutImageMarkers(text))
}

function alignsRight(direction) {
  return String(direction) === RTL
}

function hasAnswer(direction) {
  return String(direction) === RTL || String(direction) === LTR
}

function attributeFor(direction) {
  if (!hasAnswer(direction)) return ""
  return " dir=\"" + String(direction) + "\""
}

// Invariant: Qt rich text uses physical margin properties, not margin-inline-start/end.
function startEdge(direction) {
  return alignsRight(direction) ? "right" : "left"
}

function endEdge(direction) {
  return alignsRight(direction) ? "left" : "right"
}

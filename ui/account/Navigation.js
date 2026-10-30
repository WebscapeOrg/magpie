.pragma library

// Invariant: Navigation changes return fresh arrays; popping the root returns the same array so the caller can close the window.
var OVERLAYS = ["compose", "help"]

var KINDS = ["list", "reader", "settings",
  "setup", "compose", "help"]

var DEFAULT_KIND = "list"

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function isObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function contains(list, value) {
  for (var entryIndex = 0; entryIndex < list.length; entryIndex++) {
    if (list[entryIndex] === value) return true
  }
  return false
}

function isOverlay(kind) {
  return contains(OVERLAYS, trimmed(kind))
}

function normalizeKind(kind) {
  var name = trimmed(kind)
  return contains(KINDS, name) ? name : DEFAULT_KIND
}

// Invariant: Copy payload fields before writing the validated kind so data cannot replace the navigation discriminator.
function entry(kind, fields) {
  var made = {}
  var extra = isObject(fields) ? fields : {}
  for (var key in extra) {
    if (Object.prototype.hasOwnProperty.call(extra, key)) made[key] = extra[key]
  }
  made.kind = normalizeKind(kind)
  return made
}

function copy(stack) {
  var source = Array.isArray(stack) ? stack : []
  var next = []
  for (var entryIndex = 0; entryIndex < source.length; entryIndex++) {
    var item = source[entryIndex]
    if (isObject(item)) next.push(entry(item.kind, item))
  }
  if (next.length === 0) next.push(entry(DEFAULT_KIND))
  return next
}

function depth(stack) {
  return Array.isArray(stack) ? stack.length : 0
}

function top(stack) {
  var source = Array.isArray(stack) ? stack : []
  var last = source.length > 0 ? source[source.length - 1] : null
  return isObject(last) ? last : entry(DEFAULT_KIND)
}

// Invariant: Reader replacement does not accumulate history; a draft remembers its origin before opening the message it answers.
function push(stack, item) {
  var next = copy(stack)
  if (!isObject(item)) return next
  var added = entry(item.kind, item)
  var above = next[next.length - 1]
  var replaces = (added.kind === "reader" && above.kind === "reader")
    || (isOverlay(added.kind) && above.kind === added.kind)
  if (replaces) next.pop()
  var remembers = added.kind === "compose"
  if (remembers && typeof added.returnTo !== "number") added.returnTo = next.length
  next.push(added)
  return next
}

// Invariant: Returning from a draft must remove at least that entry and must never remove the root.
function pop(stack) {
  if (Array.isArray(stack) && stack.length === 1 && isObject(stack[0])) return stack
  var next = copy(stack)
  if (next.length === 1) return next
  var leaving = next[next.length - 1]
  var keep = next.length - 1
  if (typeof leaving.returnTo === "number" && isFinite(leaving.returnTo))
    keep = Math.min(keep, Math.floor(leaving.returnTo))
  return next.slice(0, Math.max(1, keep))
}

function replace(stack, item) {
  var next = copy(stack)
  if (!isObject(item)) return next
  next[next.length - 1] = entry(item.kind, item)
  return next
}

function replaceRoot(stack, kind) {
  return [entry(kind)]
}

function resetTo(stack, kind) {
  return replaceRoot(stack, kind)
}

function page(stack) {
  var source = Array.isArray(stack) ? stack : []
  for (var entryIndex = source.length - 1; entryIndex >= 0; entryIndex--) {
    if (isObject(source[entryIndex]) && !isOverlay(source[entryIndex].kind)) return source[entryIndex]
  }
  return entry(DEFAULT_KIND)
}

function overlay(stack) {
  var source = Array.isArray(stack) ? stack : []
  for (var entryIndex = source.length - 1; entryIndex >= 0; entryIndex--) {
    if (isObject(source[entryIndex]) && isOverlay(source[entryIndex].kind)) return source[entryIndex]
  }
  return null
}

function rootFor(state) {
  var value = isObject(state) ? state : {}
  if (value.anyReady === true)
    return [entry("list")]
  return [entry("setup", { draft: false })]
}

function kinds(stack) {
  var source = Array.isArray(stack) ? stack : []
  var names = []
  for (var entryIndex = 0; entryIndex < source.length; entryIndex++) {
    names.push(isObject(source[entryIndex]) ? String(source[entryIndex].kind || "") : "")
  }
  return names
}

.pragma library

// Invariant: cache versions 2 and 3 added provider item identity and the full CalDAV resource required for writes.
var VERSION = 3
var MAX_RANGES = 32
var MAX_EVENTS = 25000

function emptyStore() {
  return { version: VERSION, ranges: {} }
}

function isObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function load(text) {
  var raw = null
  try { raw = JSON.parse(String(text || "")) } catch (parseError) {}
  if (!isObject(raw) || Number(raw.version) !== VERSION || !isObject(raw.ranges))
    return emptyStore()
  return { version: VERSION, ranges: raw.ranges }
}

function serialize(store) {
  return JSON.stringify(store || emptyStore())
}

function rangeKey(scope, startMs, endMs) {
  return String(scope || "") + "\n" + Math.floor(Number(startMs) || 0)
    + ":" + Math.floor(Number(endMs) || 0)
}

function eventsFor(store, scope, startMs, endMs, enabledSourceIds) {
  var ranges = store && store.ranges || {}
  var candidates = Object.keys(ranges).filter(function(key) {
    var range = ranges[key]
    return key.indexOf(String(scope || "") + "\n") === 0
      && Number(range.startMs) < Number(endMs) && Number(range.endMs) > Number(startMs)
  }).map(function(key) { return ranges[key] })
  var ids = Array.isArray(enabledSourceIds) ? enabledSourceIds : []
  var output = []
  for (var idIndex = 0; idIndex < ids.length; idIndex++) {
    var id = String(ids[idIndex])
    var sources = candidates.filter(function(range) {
      return (range.sources || []).indexOf(id) >= 0 || (range.events || []).some(function(event) {
        return event && String(event.sourceId || "") === id
      })
    })
    sources.sort(function(left,right) {
      return Number(right.sourceTimes && right.sourceTimes[id] || right.at)
        - Number(left.sourceTimes && left.sourceTimes[id] || left.at)
    })
    var covered = []
    var seen = {}
    for (var sourceIndex = 0; sourceIndex < sources.length; sourceIndex++) {
      var source = sources[sourceIndex]
      var values = source.events || []
      for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
        var event = values[valueIndex]
        if (!event || String(event.sourceId || "") !== id) continue
        var begins = event.start ? Number(event.start.ms) : Number(source.startMs)
        var ends = event.end ? Number(event.end.ms) : Number(source.endMs)
        if (begins >= endMs || ends <= startMs) continue
        if (covered.some(function(range) { return range.startMs < ends && range.endMs > begins })) continue
        var key = String(event.uid || event.googleId || event.href || "") + ":" + begins
        if (!seen[key]) output.push(event)
        seen[key] = true
      }
      if ((source.sources || []).indexOf(id) >= 0) covered.push(source)
    }
  }
  return output
}

function coversSource(store,scope,startMs,endMs,id) {
  var ranges=store && store.ranges || {}
  return Object.keys(ranges).some(function(key) {
    var range=ranges[key]
    return key.indexOf(String(scope || "")+"\n")===0 && Number(range.startMs)<=startMs && Number(range.endMs)>=endMs
      && Array.isArray(range.sources) && range.sources.indexOf(String(id))>=0
  })
}

function putRange(store, scope, startMs, endMs, events, nowMs, refreshedSourceIds, requestAt) {
  var source = store && isObject(store.ranges) ? store.ranges : {}
  var ranges = {}
  for (var key in source) ranges[key] = source[key]
  var kept = Array.isArray(events) ? events.slice() : []
  var old = source[rangeKey(scope, startMs, endMs)]
  var stamp = Number(requestAt) || Number(nowMs) || 0
  var times = Object.assign({},old && old.sourceTimes || {})
  if (Array.isArray(refreshedSourceIds)) {
    var accepted = refreshedSourceIds.filter(function(id) {return Number(times[id] || 0) <= stamp})
    kept = kept.filter(function(event) {return accepted.indexOf(String(event.sourceId || ""))>=0})
    refreshedSourceIds = accepted
    for (var acceptedIndex=0;acceptedIndex<accepted.length;acceptedIndex++) times[accepted[acceptedIndex]]=stamp
  }
  if (Array.isArray(refreshedSourceIds) && old && Array.isArray(old.events)) {
    kept = kept.concat(old.events.filter(function(event) {
      return event && refreshedSourceIds.indexOf(String(event.sourceId || "")) < 0
    }))
  }
  ranges[rangeKey(scope, startMs, endMs)] = {
    startMs: Number(startMs) || 0,
    endMs: Number(endMs) || 0,
    at: Number(nowMs) || 0,
    events: kept.slice(0, MAX_EVENTS),
    sourceTimes: times,
    sources: kept.length > MAX_EVENTS ? [] : (old && Array.isArray(old.sources) ? old.sources : []).concat(
      Array.isArray(refreshedSourceIds) ? refreshedSourceIds : []).filter(function(id,index,values) {
        return values.indexOf(id) === index
      })
  }
  var keys = Object.keys(ranges)
  keys.sort(function(left, right) { return Number(ranges[right].at) - Number(ranges[left].at) })
  for (var keyIndex = MAX_RANGES; keyIndex < keys.length; keyIndex++) delete ranges[keys[keyIndex]]
  return { version: VERSION, ranges: ranges }
}

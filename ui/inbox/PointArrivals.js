.pragma library
.import "Readiness.js" as Readiness

function update(previous, rows, valueFor, activeFor, at, enabled, scope) {
  previous = previous || {queued:[], delivered:[], scope:""}
  if (!enabled) return {queued:[], delivered:[], scope:scope}
  if (previous.scope !== scope) previous = {queued:[], delivered:[]}
  var live = rows.map(function(row) { return row.id })
  function status(id) {
    var row = rows.find(function(row) { return row.id === id })
    return row ? Readiness.status(valueFor(row), at, false) : "plain"
  }
  var queued = previous.queued.filter(function(id) { return live.indexOf(id) >= 0 && status(id) !== "plain" })
  var delivered = previous.delivered.filter(function(id) { return live.indexOf(id) >= 0 })
  for (var i=0; i<rows.length; i++)
    if (status(rows[i].id) === "writing" && queued.indexOf(rows[i].id) < 0) queued.push(rows[i].id)
  var completed = queued.find(function(id) { return status(id) === "ready" })
  var active = rows.find(function(row) { return queued.indexOf(row.id) >= 0 && activeFor(row) })
  var first = completed || (active && active.id) || queued[0]
  if (first) queued = [first].concat(queued.filter(function(id) { return id !== first }))
  return {queued:queued, delivered:delivered, scope:scope}
}

function finish(state, id) {
  if (!state || state.queued[0] !== id) return state
  return {queued:state.queued.slice(1), delivered:[id].concat(state.delivered.filter(function(value) { return value !== id })), scope:state.scope}
}

function projection(state, rows, enabled) {
  if (!enabled || !state) return {messages:rows,currentId:"",count:0,depth:0}
  var ready = rows.filter(function(row) { return state.queued.indexOf(row.id) < 0 })
  var arrived = state.delivered.map(function(id) { return ready.find(function(row) { return row.id === id }) }).filter(Boolean)
  ready = arrived.concat(ready.filter(function(row) { return state.delivered.indexOf(row.id) < 0 }))
  var current = rows.find(function(row) { return row.id === state.queued[0] })
  return {messages:current ? [current].concat(ready) : ready,currentId:current ? current.id : "",count:state.queued.length,depth:Math.min(3,state.queued.length)}
}

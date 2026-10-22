.pragma library

function tokenAt(text, cursor, selectionStart, selectionEnd) {
  var source = String(text || "")
  var position = Math.max(0, Math.min(source.length, Number(cursor) || 0))
  var start = 0
  var quoted = false
  var escaped = false
  for (var index = 0; index < source.length; index++) {
    var character = source.charAt(index)
    if (escaped) { escaped = false; continue }
    if (character === "\\" && quoted) { escaped = true; continue }
    if (character === '"') { quoted = !quoted; continue }
    if (quoted || !/[\s(){}]/.test(character)) continue
    if (index < position) { start = index + 1; continue }
    return selectedToken(source, start, index, position, selectionStart, selectionEnd)
  }
  return selectedToken(source, start, source.length, position, selectionStart, selectionEnd)
}

function selectedToken(source, start, end, cursor, selectionStart, selectionEnd) {
  var first = Math.min(Number(selectionStart) || 0, Number(selectionEnd) || 0)
  var last = Math.max(Number(selectionStart) || 0, Number(selectionEnd) || 0)
  if (first !== last && (first < start || last > end)) return null
  return {start:start, end:end, text:source.slice(start,end), prefix:source.slice(start,cursor)}
}

function quotedValue(value) {
  var text = String(value || "")
  return /[\s"\\(){}]/.test(text) ? '"' + text.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"' : text
}

function valuePrefix(value) {
  var text = String(value || "")
  if (text.charAt(0) === '"') text = text.slice(1)
  if (text.charAt(text.length - 1) === '"') text = text.slice(0,-1)
  return text.replace(/\\(["\\])/g, "$1").toLowerCase()
}

function suggestions(text, cursor, selectionStart, selectionEnd, operators, labels) {
  var token = tokenAt(text,cursor,selectionStart,selectionEnd)
  if (!token) return []
  var prefix = token.prefix
  var negative = prefix.charAt(0) === "-" ? "-" : ""
  if (negative) prefix = prefix.slice(1)
  var colon = prefix.indexOf(":")
  var list = Array.isArray(operators) ? operators : []
  var result = []
  for (var operatorIndex = 0; operatorIndex < list.length; operatorIndex++) {
    var entry = list[operatorIndex] || {}
    var operator = String(entry.operator || "")
    if (operator === "") continue
    if (colon < 0) {
      if (operator.indexOf(prefix.toLowerCase()) !== 0) continue
      result.push({start:token.start,end:token.end,value:negative + operator + ":",
        label:negative + operator + ":",detail:String(entry.description || ""),complete:false})
      continue
    }
    if (operator !== prefix.slice(0,colon).toLowerCase()) continue
    var wanted = valuePrefix(prefix.slice(colon + 1))
    var values = operator === "label" ? labelValues(labels) : (entry.values || [])
    for (var valueIndex = 0; valueIndex < values.length; valueIndex++) {
      var value = String(values[valueIndex] || "")
      if (value === "" || value.toLowerCase().indexOf(wanted) !== 0) continue
      var replacement = negative + operator + ":" + quotedValue(value)
      if (replacement === token.text) continue
      result.push({start:token.start,end:token.end,value:replacement,
        label:replacement,detail:String(entry.description || ""),complete:true})
    }
  }
  return result
}

function labelValues(labels) {
  var list = Array.isArray(labels) ? labels : []
  var seen = Object.create(null)
  var result = []
  for (var index = 0; index < list.length; index++) {
    var name = typeof list[index] === "string" ? list[index] : String((list[index] || {}).name || "")
    if (name === "" || seen[name]) continue
    seen[name] = true
    result.push(name)
  }
  return result.sort(function(left,right) { return left.localeCompare(right) })
}

function replacement(text, suggestion) {
  var source = String(text || "")
  var choice = suggestion || {}
  var end = Number(choice.end) || 0
  var suffix = source.slice(end)
  var space = choice.complete && (suffix === "" || !/^[\s)}]/.test(suffix)) ? " " : ""
  return {start:Number(choice.start) || 0,end:end,value:String(choice.value || "") + space}
}

function exampleInsertion(text, start, end, example) {
  var source = String(text || "")
  var first = Math.min(start,end)
  var last = Math.max(start,end)
  var before = source.slice(0,first)
  var after = source.slice(last)
  return {start:first,end:last,value:(before !== "" && !/[\s({]$/.test(before) ? " " : "")
    + String(example || "") + (after === "" || !/^[\s)}]/.test(after) ? " " : "")}
}

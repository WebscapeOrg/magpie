.pragma library

// Invariant: QML var arrays may be length-bearing objects without JavaScript Array identity.
function asList(value) {
  if (value === undefined || value === null) return []
  if (Array.isArray(value)) return value
  var count = value.length
  if (typeof count !== "number" || count < 1) return []
  var out = []
  var valueIndex
  for (valueIndex = 0; valueIndex < count; valueIndex++) {
    if (value[valueIndex] !== undefined) out.push(value[valueIndex])
  }
  return out
}

function visible(rows, accountId, mode) {
  var list = asList(rows)
  var kind = String(mode || "new")
  if (kind === "new" || kind === "") return list
  var wanted = String(accountId || "")
  var kept = []
  var listIndex
  for (listIndex = 0; listIndex < list.length; listIndex++) {
    if (String(list[listIndex].accountId || "") === wanted) kept.push(list[listIndex])
  }
  return kept
}

function subtitle(identity) {
  var row = identity || ({})
  var name = String(row.displayName || "").trim()
  if (name !== "") return name
  var label = String(row.label || "").trim()
  var email = String(row.email || "").trim()
  if (label !== "" && label.toLowerCase() !== email.toLowerCase()) return label
  return ""
}

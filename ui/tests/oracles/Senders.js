.pragma library

// Invariant: New mail may use any connected identity; replies and forwards retain the source account.

// Invariant: QML lists can be length-bearing objects rather than JavaScript arrays.
function asList(value) {
  if (value === undefined || value === null) return []
  if (Array.isArray(value)) return value
  var length = value.length
  if (typeof length !== "number" || !isFinite(length) || Math.floor(length) !== length || length < 1) return []
  var output = []
  for (var itemIndex = 0; itemIndex < length; itemIndex++) {
    if (value[itemIndex] !== undefined) output.push(value[itemIndex])
  }
  return output
}

function aliasesOf(mailbox) {
  var aliases = Array.isArray(mailbox.aliases) ? mailbox.aliases : []
  if (aliases.length > 0) return aliases
  var fallback = String(mailbox.email || "").trim()
  if (fallback === "") return []
  return [{ email: fallback, displayName: String(mailbox.displayName || "") }]
}

function identities(mailboxes) {
  var rows = asList(mailboxes)
  var output = []
  var seen = Object.create(null)
  for (var itemIndex = 0; itemIndex < rows.length; itemIndex++) {
    var box = rows[itemIndex] || {}
    if (box.ready !== true || box.canSend === false) continue
    var accountId = String(box.id || "")
    if (accountId === "") continue
    var aliases = aliasesOf(box)
    for (var aliasIndex = 0; aliasIndex < aliases.length; aliasIndex++) {
      var alias = aliases[aliasIndex] || {}
      var email = String(alias.email || "").trim()
      if (email === "") continue
      var key = JSON.stringify([accountId, email.toLowerCase()])
      if (seen[key]) continue
      seen[key] = true
      output.push({
        accountId: accountId,
        email: email,
        displayName: String(alias.displayName || ""),
        label: String(box.label || "")
      })
    }
  }
  return output
}

function visible(rows, accountId, mode) {
  var list = asList(rows)
  var kind = String(mode || "new")
  if (kind === "new" || kind === "") return list
  var wanted = String(accountId || "")
  var kept = []
  for (var itemIndex = 0; itemIndex < list.length; itemIndex++) {
    if (String(list[itemIndex].accountId || "") === wanted) kept.push(list[itemIndex])
  }
  return kept
}

function subtitle(identity) {
  var row = identity || {}
  var name = String(row.displayName || "").trim()
  if (name !== "") return name
  var label = String(row.label || "").trim()
  var email = String(row.email || "").trim()
  if (label !== "" && label.toLowerCase() !== email.toLowerCase()) return label
  return ""
}

.pragma library

// Who a new message may be sent as. One mailbox can have several of its own
// addresses; several mailboxes can be signed in at once. The compose form
// needs one list of both, because a From that only names the current
// mailbox's aliases leaves every other connected account unreachable.
//
// A reply or forward stays on the mailbox that holds the original: sending
// that draft from a different account would hand another server a thread id
// it has never seen.

// QML `var` arrays are sometimes length-bearing objects, not JS Array.
// Array.isArray is then false and From would list nobody.
function asList(value) {
  if (value === undefined || value === null) return []
  if (Array.isArray(value)) return value
  var length = value.length
  if (typeof length !== "number" || length < 1) return []
  var output = []
  var itemIndex
  for (itemIndex = 0; itemIndex < length; itemIndex++) {
    if (value[itemIndex] !== undefined) output.push(value[itemIndex])
  }
  return output
}

function identities(mailboxes) {
  var rows = asList(mailboxes)
  var output = []
  var seen = ({})
  var itemIndex
  for (itemIndex = 0; itemIndex < rows.length; itemIndex++) {
    var box = rows[itemIndex] || ({})
    if (box.ready !== true || box.canSend === false) continue
    var accountId = String(box.id || "")
    if (accountId === "") continue
    var aliases = Array.isArray(box.aliases) ? box.aliases : []
    if (aliases.length === 0) {
      var fallback = String(box.email || "").trim()
      if (fallback === "") continue
      aliases = [{ email: fallback, displayName: String(box.displayName || "") }]
    }
    var aliasIndex
    for (aliasIndex = 0; aliasIndex < aliases.length; aliasIndex++) {
      var alias = aliases[aliasIndex] || ({})
      var email = String(alias.email || "").trim()
      if (email === "") continue
      var key = accountId + "\n" + email.toLowerCase()
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
  var itemIndex
  for (itemIndex = 0; itemIndex < list.length; itemIndex++) {
    if (String(list[itemIndex].accountId || "") === wanted) kept.push(list[itemIndex])
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

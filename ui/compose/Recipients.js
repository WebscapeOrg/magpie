.pragma library

// Invariant: replies to our own messages address the original To recipients.
function replyFields(summary, mode, ownAddresses) {
  var source = summary || ({})
  var own = normalize(ownAddresses)
  var self = ({})
  var seen = ({})
  var to = []
  var cc = []
  var ownIndex
  for (ownIndex = 0; ownIndex < own.length; ownIndex++) self[own[ownIndex].email.toLowerCase()] = true
  var sender = cleanContact(source.from)
  var outgoing = !!(sender && self[sender.email.toLowerCase()])
  function keep(values, target) {
    var contacts = normalize(values)
    for (var contactIndex = 0; contactIndex < contacts.length; contactIndex++) {
      var email = contacts[contactIndex].email
      var key = email.toLowerCase()
      if (self[key] || seen[key]) continue
      seen[key] = true
      target.push(email)
    }
  }
  if (outgoing) {
    keep(source.to, to)
  } else {
    var replyTo = cleanContact(source.replyTo) || sender
    keep(replyTo ? [replyTo] : [], to)
  }
  if (mode === "replyAll") {
    if (!outgoing) keep(source.to, cc)
    keep(source.cc, cc)
  }
  return {to: to.join(", "), cc: cc.join(", "), outgoing: outgoing}
}

function cleanContact(value) {
  var contact = value || ({})
  var name = String(contact.name || "").replace(/[\r\n]+/g, " ").trim()
  var email = String(contact.email || "").trim()
  if (/[\u0000-\u001f\u007f]/.test(email)
      || !/^(?:"(?:[^"\\]|\\.)*"|[^\s()<>\[\]:;@\\,"]+)@(?:[^\s()<>\[\]:;@\\,"]+|\[(?:IPv6:)?[0-9a-fA-F:.]+\])$/.test(email)) return null
  return ({ name: name, email: email })
}

function normalize(values) {
  var contacts = Array.isArray(values) ? values : []
  var seen = ({})
  var out = []
  for (var contactIndex = 0; contactIndex < contacts.length; contactIndex++) {
    var contact = cleanContact(contacts[contactIndex])
    if (!contact) continue
    var key = contact.email.toLowerCase()
    if (seen[key]) continue
    seen[key] = true
    out.push(contact)
  }
  return out
}

function currentToken(text) {
  var value = String(text || "")
  var comma = value.lastIndexOf(",")
  var semicolon = value.lastIndexOf(";")
  return value.substring(Math.max(comma, semicolon) + 1).trim()
}

function usedAddresses(text) {
  var parts = String(text || "").split(/[,;]/)
  var used = ({})
  for (var partIndex = 0; partIndex < parts.length - 1; partIndex++) {
    var angle = parts[partIndex].match(/<([^>]+)>/)
    var email = angle ? angle[1] : parts[partIndex]
    used[String(email || "").trim().toLowerCase()] = true
  }
  return used
}

function suggest(values, text, limit) {
  return suggestIndexed(index(values),text,limit)
}

function index(values) {
  var contacts = normalize(values)
  var result = contacts.map(function(contact) {
    return {contact:contact,email:contact.email.toLowerCase(),name:contact.name.toLowerCase(),
      sort:(contact.name || contact.email).toLowerCase()}
  })
  result.sort(function(left,right) { return left.sort < right.sort ? -1 : left.sort > right.sort ? 1 : 0 })
  return result
}

function suggestIndexed(contacts, text, limit) {
  var query = currentToken(text).toLowerCase()
  if (query === "") return []
  var used = usedAddresses(text)
  var count = Math.max(1, Math.floor(Number(limit) || 5))
  var prefix = []
  var matches = []
  for (var contactIndex = 0; contactIndex < contacts.length; contactIndex++) {
    var contact = contacts[contactIndex]
    var email = contact.email
    var name = contact.name
    if (used[email] || query === email) continue
    var emailAt = email.indexOf(query)
    var nameAt = name.indexOf(query)
    if (emailAt < 0 && nameAt < 0) continue
    if (emailAt === 0 || nameAt === 0) prefix.push(contact.contact)
    else if (matches.length < count) matches.push(contact.contact)
    if (prefix.length >= count) break
  }
  return prefix.concat(matches).slice(0,count)
}

function address(contact) {
  var value = cleanContact(contact)
  if (!value) return ""
  if (value.name === "") return value.email
  var name = value.name.replace(/([\\"])/g, "\\$1")
  if (/[()<>\[\]:;@\\",]/.test(name)) name = "\"" + name + "\""
  return name + " <" + value.email + ">"
}

function accept(text, contact) {
  var value = String(text || "")
  var comma = value.lastIndexOf(",")
  var semicolon = value.lastIndexOf(";")
  var split = Math.max(comma, semicolon)
  var prefix = split >= 0 ? value.substring(0, split + 1).trim() + " " : ""
  return prefix + address(contact)
}

function append(text, contact) {
  var addr = address(contact)
  if (!addr) return String(text || "")
  var current = String(text || "").trim()
  if (current === "") return addr
  current = current.replace(/[,;]+$/, "").trim()
  var used = usedAddresses(current + ",")
  var clean = cleanContact(contact)
  if (clean && used[clean.email.toLowerCase()]) return current
  return current + ", " + addr
}

function filter(values, query, limit) {
  var contacts = normalize(values)
  var normalizedQuery = String(query || "").trim().toLowerCase()
  var out = []
  for (var contactIndex = 0; contactIndex < contacts.length; contactIndex++) {
    var contact = contacts[contactIndex]
    if (normalizedQuery === "" || contact.email.toLowerCase().indexOf(normalizedQuery) >= 0 || contact.name.toLowerCase().indexOf(normalizedQuery) >= 0) {
      out.push(contact)
    }
  }
  out.sort(function(left, right) {
    var leftName = (left.name || left.email).toLowerCase()
    var rightName = (right.name || right.email).toLowerCase()
    return leftName < rightName ? -1 : (leftName > rightName ? 1 : 0)
  })
  if (typeof limit === "number" && limit > 0) {
    return out.slice(0, limit)
  }
  return out
}

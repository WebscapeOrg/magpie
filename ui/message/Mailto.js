.pragma library

// Invariant: mailto opens an editable draft; query headers lose line breaks while the body keeps them.

function percentDecode(value) {
  var text = String(value || "")
  try {
    return decodeURIComponent(text)
  } catch (parseError) {
    // Invariant: a malformed percent escape preserves the original field text.
    return text
  }
}

function headerSafe(value) {
  return String(value || "").replace(/[\r\n]+/g, " ").trim()
}

function bodyText(value) {
  return String(value || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n")
}

function appendAddresses(list, value) {
  var parts = String(value || "").split(",")
  var partIndex
  for (partIndex = 0; partIndex < parts.length; partIndex++) {
    var address = parts[partIndex].trim()
    if (address !== "") list.push(address)
  }
}

function emptyDraft() {
  return { to: "", cc: "", bcc: "", subject: "", body: "" }
}

function parse(entry) {
  var text = String(entry || "").trim()
  if (!/^mailto:/i.test(text)) return null
  var rest = text.substring(7)
  var hash = rest.indexOf("#")
  if (hash >= 0) rest = rest.substring(0, hash)
  var mark = rest.indexOf("?")
  var path = headerSafe(percentDecode(mark < 0 ? rest : rest.substring(0, mark)))
  var to = []
  var cc = []
  var bcc = []
  var subject = ""
  var body = ""
  appendAddresses(to, path)
  if (mark >= 0) {
    var pairs = rest.substring(mark + 1).split("&")
    var pairIndex
    for (pairIndex = 0; pairIndex < pairs.length; pairIndex++) {
      var equals = pairs[pairIndex].indexOf("=")
      if (equals < 0) continue
      var key = pairs[pairIndex].substring(0, equals).toLowerCase()
      var raw = percentDecode(pairs[pairIndex].substring(equals + 1))
      if (key === "to") appendAddresses(to, headerSafe(raw))
      else if (key === "cc") appendAddresses(cc, headerSafe(raw))
      else if (key === "bcc") appendAddresses(bcc, headerSafe(raw))
      else if (key === "subject") subject = headerSafe(raw)
      else if (key === "body") body = bodyText(raw)
    }
  }
  return {
    to: to.join(", "),
    cc: cc.join(", "),
    bcc: bcc.join(", "),
    subject: subject,
    body: body
  }
}

function draftFromPayload(payload) {
  if (!payload || typeof payload !== "object") return null
  if (payload.mailto) return parse(payload.mailto)
  if (payload.compose === true) return emptyDraft()
  return null
}

.pragma library

.import "Html.js" as Html
.import "Mailto.js" as Mailto

// Invariant: unsubscribe planning is pure; network dispatch must validate the chosen destination separately.
var MAX_HEADER_LENGTH = 2048
var MAX_ENTRIES = 8

// Invariant: List-Unsubscribe uses bracketed entries because commas can occur inside a mailto query.
function entries(value) {
  var text = String(value || "")
  if (text.length > MAX_HEADER_LENGTH) return []
  var found = []
  var open = -1
  for (var index = 0; index < text.length && found.length < MAX_ENTRIES; index++) {
    var character = text.charAt(index)
    if (character === "<") {
      open = index
      continue
    }
    if (character !== ">" || open < 0) continue
    var raw = text.substring(open + 1, index)
    var entry = /[\u0000-\u001f\u007f]/.test(raw) ? "" : raw.trim()
    if (entry !== "") found.push(entry)
    open = -1
  }
  return found
}

function parseMailto(entry) {
  var text = String(entry || "")
  if (!/^mailto:/i.test(text)) return null
  var rest = text.substring(7)
  var mark = rest.indexOf("?")
  var to = Mailto.headerSafe(Mailto.percentDecode(mark < 0 ? rest : rest.substring(0, mark)))
  // Invariant: unsubscribe mail targets one path recipient and never adopts query recipients.
  to = to.split(",")[0].trim()
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to)) return null

  var subject = ""
  var body = ""
  if (mark >= 0) {
    var pairs = rest.substring(mark + 1).split("&")
    for (var pairIndex = 0; pairIndex < pairs.length; pairIndex++) {
      var equals = pairs[pairIndex].indexOf("=")
      if (equals < 0) continue
      var key = pairs[pairIndex].substring(0, equals).toLowerCase()
      var raw = Mailto.percentDecode(pairs[pairIndex].substring(equals + 1))
      if (key === "subject") subject = Mailto.headerSafe(raw)
      else if (key === "body") body = String(raw)
    }
  }
  // Invariant: default unsubscribe subject and body keep an otherwise empty request sendable.
  return {
    to: to,
    subject: subject !== "" ? subject : "Unsubscribe",
    body: body !== "" ? body : "Unsubscribe"
  }
}

// Invariant: sender-controlled unsubscribe URLs must pass the same public-address policy as remote images.
function isPublicWebUrl(value) {
  if (/[\u0000-\u001f\u007f]/.test(String(value || ""))) return false
  var text = String(value || "").trim()
  if (!/^https?:\/\//i.test(text)) return false
  return Html.imageSourceKind(text) === "remote"
}

// Invariant: RFC 8058 one-click POST requires HTTPS.
function isPostableUrl(value) {
  return /^https:\/\//i.test(String(value || "").trim()) && isPublicWebUrl(value)
}

function empty() {
  return { available: false, oneClick: false, url: "", postUrl: "", mail: null }
}

// Invariant: an HTTPS URL alone never authorizes POST; List-Unsubscribe-Post must declare one-click support.
function from(listHeader, postHeader) {
  var result = empty()
  var list = entries(listHeader)
  if (list.length === 0) return result

  for (var listIndex = 0; listIndex < list.length; listIndex++) {
    var entry = list[listIndex]
    if (/^mailto:/i.test(entry)) {
      if (!result.mail) result.mail = parseMailto(entry)
      continue
    }
    if (result.url === "" && isPublicWebUrl(entry)) result.url = entry
  }

  var declared = String(postHeader || "")
  var oneClick = /List-Unsubscribe\s*=\s*One-Click/i.test(declared)
  if (oneClick && isPostableUrl(result.url)) {
    result.oneClick = true
    result.postUrl = result.url
  }

  result.available = result.oneClick || !!result.mail || result.url !== ""
  return result
}

function fromMessage(message) {
  var headers = message && message.payload && Array.isArray(message.payload.headers)
    ? message.payload.headers
    : (message && Array.isArray(message.headers) ? message.headers : [])
  return fromHeaders(headers)
}

function fromHeaders(headers) {
  var list = Array.isArray(headers) ? headers : []
  var listHeader = ""
  var postHeader = ""
  for (var listIndex = 0; listIndex < list.length; listIndex++) {
    var name = String(list[listIndex].name || "").toLowerCase()
    if (name === "list-unsubscribe" && listHeader === "") listHeader = String(list[listIndex].value || "")
    else if (name === "list-unsubscribe-post" && postHeader === "") postHeader = String(list[listIndex].value || "")
  }
  return from(listHeader, postHeader)
}

// Invariant: prefer one-click POST, then supported mail, then opening the sender's page.
function plan(info, canSend) {
  var found = info || empty()
  if (found.oneClick && found.postUrl !== "") return "post"
  if (found.mail && canSend === true) return "mail"
  if (found.url !== "") return "browser"
  if (found.mail) return "mail"
  return ""
}

// Invariant: a browser action uses an ellipsis because it leaves the app to finish the workflow.
function label(info, canSend) {
  var how = plan(info, canSend)
  if (how === "") return ""
  return how === "browser" ? "Unsubscribe..." : "Unsubscribe"
}

function explanation(info, canSend) {
  var how = plan(info, canSend)
  if (how === "post") return "This sender accepts a one-click unsubscribe"
  if (how === "mail") return "Unsubscribing sends a message to this list"
  if (how === "browser") return "Unsubscribing opens this sender's page in a browser"
  return ""
}

// Invariant: the RFC 8058 request body and content type are fixed protocol values.
function postBody() {
  return "List-Unsubscribe=One-Click"
}

function postContentType() {
  return "application/x-www-form-urlencoded"
}

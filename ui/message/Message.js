.pragma library
.import "Direction.js" as Direction
.import "Signature.js" as Signature

// Docs: providers share Gmail-shaped payloads; body data is base64url and headers can contain RFC 2047 words.

var B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// Performance: one lookup per base64 character avoids repeatedly scanning the alphabet on the drawing thread.
var B64_LOOKUP = (function() {
  var table = {}
  for (var index = 0; index < B64_ALPHABET.length; index++) table[B64_ALPHABET.charAt(index)] = index
  table["-"] = 62
  table["_"] = 63
  return table
})()

function b64Index(character) {
  var value = B64_LOOKUP[character]
  return value === undefined ? -1 : value
}

function base64ToBytes(text) {
  var input = String(text || "")
  var bytes = []
  var buffer = 0
  var bits = 0
  for (var index = 0; index < input.length; index++) {
    var value = B64_LOOKUP[input.charAt(index)]
    if (value === undefined) continue
    buffer = (buffer << 6) | value
    bits += 6
    if (bits >= 8) {
      bits -= 8
      bytes.push((buffer >> bits) & 0xff)
    }
  }
  return bytes
}

function utf8Scalar(bytes, index) {
  var first = bytes[index]
  if (first < 0x80) return first
  var width = first >= 0xc2 && first <= 0xdf ? 2
    : (first >= 0xe0 && first <= 0xef ? 3 : (first >= 0xf0 && first <= 0xf4 ? 4 : 0))
  if (width === 0 || index + width > bytes.length) return -1
  var codePoint = first & (width === 2 ? 0x1f : (width === 3 ? 0x0f : 0x07))
  for (var offset = 1; offset < width; offset++) {
    var continuation = bytes[index + offset]
    if (continuation < 0x80 || continuation > 0xbf) return -1
    codePoint = (codePoint << 6) | (continuation & 0x3f)
  }
  if (width === 3 && codePoint < 0x800) return -1
  if (width === 4 && (codePoint < 0x10000 || codePoint > 0x10ffff)) return -1
  if (codePoint >= 0xd800 && codePoint <= 0xdfff) return -1
  return codePoint
}

function bytesToUtf8(bytes) {
  var result = ""
  var byteIndex = 0
  while (byteIndex < bytes.length) {
    var first = bytes[byteIndex]
    if (first < 0x80) {
      result += String.fromCharCode(first)
      byteIndex++
      continue
    }
    var codePoint = utf8Scalar(bytes, byteIndex)
    if (codePoint < 0) {
      // Invariant: malformed UTF-8 bytes fall back individually to Latin-1 so message text remains readable.
      result += String.fromCharCode(first)
      byteIndex++
      continue
    }
    byteIndex += codePoint < 0x800 ? 2 : (codePoint < 0x10000 ? 3 : 4)
    if (codePoint <= 0xffff) {
      result += String.fromCharCode(codePoint)
      continue
    }
    codePoint -= 0x10000
    result += String.fromCharCode(0xd800 + (codePoint >> 10), 0xdc00 + (codePoint & 0x3ff))
  }
  return result
}

function bytesToLatin1(bytes) {
  var out = ""
  for (var byteIndex = 0; byteIndex < bytes.length; byteIndex++) out += String.fromCharCode(bytes[byteIndex])
  return out
}

// Invariant: Qt.atob returns decoded QString text; decoding it again as byte values corrupts non-ASCII text.
function decodeBase64Url(text) {
  var input = String(text || "")
  if (input === "") return ""
  if (typeof Qt !== "undefined" && typeof Qt.atob === "function") {
    try {
      return Qt.atob(input.replace(/-/g, "+").replace(/_/g, "/"))
    } catch (parseError) {

    }
  }
  return bytesToUtf8(base64ToBytes(input))
}

function utf8Bytes(text) {
  var input = String(text || "")
  var bytes = []
  for (var index = 0; index < input.length; index++) {
    var code = input.charCodeAt(index)
    if (code >= 0xd800 && code <= 0xdbff && index + 1 < input.length) {
      var low = input.charCodeAt(index + 1)
      if (low >= 0xdc00 && low <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00)
        index++
      }
    }
    if (code >= 0xd800 && code <= 0xdfff) code = 0xfffd
    if (code < 0x80) bytes.push(code)
    else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f))
    else if (code < 0x10000) bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f))
    else bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
      0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f))
  }
  return bytes
}

function bytesToBase64(bytes, urlSafe) {
  var out = ""
  for (var byteIndex = 0; byteIndex < bytes.length; byteIndex += 3) {
    var b0 = bytes[byteIndex]
    var b1 = byteIndex + 1 < bytes.length ? bytes[byteIndex + 1] : -1
    var b2 = byteIndex + 2 < bytes.length ? bytes[byteIndex + 2] : -1
    out += B64_ALPHABET.charAt(b0 >> 2)
    out += B64_ALPHABET.charAt(((b0 & 0x03) << 4) | (b1 < 0 ? 0 : b1 >> 4))
    out += b1 < 0 ? "=" : B64_ALPHABET.charAt(((b1 & 0x0f) << 2) | (b2 < 0 ? 0 : b2 >> 6))
    out += b2 < 0 ? "=" : B64_ALPHABET.charAt(b2 & 0x3f)
  }
  if (!urlSafe) return out
  return out.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function encodeBase64Url(text) {
  return bytesToBase64(utf8Bytes(text), true)
}

function encodeBase64(text) {
  return bytesToBase64(utf8Bytes(text), false)
}

function decodeQuotedPrintableWord(text) {
  var input = String(text || "").replace(/_/g, " ")
  var bytes = []
  for (var index = 0; index < input.length; index++) {
    if (input.charAt(index) === "=" && index + 2 < input.length) {
      var hex = input.substr(index + 1, 2)
      if (/^[0-9A-Fa-f]{2}$/.test(hex)) {
        bytes.push(parseInt(hex, 16))
        index += 2
        continue
      }
    }
    bytes.push(input.charCodeAt(index) & 0xff)
  }
  return bytes
}

// Invariant: only fully valid multibyte UTF-8 overrides a declared single-byte charset.
function looksLikeUtf8(bytes) {
  var values = bytes || []
  var multibyte = false
  var byteIndex = 0
  while (byteIndex < values.length) {
    if (values[byteIndex] < 0x80) {
      byteIndex++
      continue
    }
    var codePoint = utf8Scalar(values, byteIndex)
    if (codePoint < 0) return false
    byteIndex += codePoint < 0x800 ? 2 : (codePoint < 0x10000 ? 3 : 4)
    multibyte = true
  }
  return multibyte
}

function decodeWordBytes(charset, bytes) {
  var name = String(charset || "").toLowerCase()
  if (name.indexOf("utf-8") === 0 || name.indexOf("utf8") === 0) return bytesToUtf8(bytes)
  if (name.indexOf("iso-8859") === 0 || name.indexOf("windows-125") === 0
    || name.indexOf("us-ascii") === 0 || name === "")
    return looksLikeUtf8(bytes) ? bytesToUtf8(bytes) : bytesToLatin1(bytes)
  // Docs: unsupported multibyte charsets use the UTF-8/Latin-1 fallback because this portable path has no mapping tables.
  return bytesToUtf8(bytes)
}

// Invariant: RFC 2047 adjacent encoded words omit separating whitespace.
function decodeHeaderValue(value) {
  var input = String(value === undefined || value === null ? "" : value)
  if (input.indexOf("=?") < 0) return input
  var pattern = /=\?([^?]+)\?([BbQq])\?([^?]*)\?=/g
  var out = ""
  var lastEnd = 0
  var previousWasWord = false
  var match
  while ((match = pattern.exec(input)) !== null) {
    var between = input.substring(lastEnd, match.index)
    if (!(previousWasWord && /^[\s]*$/.test(between))) out += between
    var bytes = match[2].toUpperCase() === "B"
      ? base64ToBytes(match[3])
      : decodeQuotedPrintableWord(match[3])
    out += decodeWordBytes(match[1], bytes)
    lastEnd = match.index + match[0].length
    previousWasWord = true
  }
  out += input.substring(lastEnd)
  return out
}

function headerValue(message, name) {
  var payload = message && message.payload ? message.payload : null
  var headers = payload && Array.isArray(payload.headers) ? payload.headers : []
  var wanted = String(name || "").toLowerCase()
  for (var headerIndex = 0; headerIndex < headers.length; headerIndex++) {
    if (String(headers[headerIndex].name || "").toLowerCase() === wanted)
      return String(headers[headerIndex].value || "")
  }
  return ""
}

function decodedHeader(message, name) {
  return decodeHeaderValue(headerValue(message, name))
}

function unquote(value) {
  var text = String(value || "").trim()
  if (text.length >= 2 && text.charAt(0) === "\"" && text.charAt(text.length - 1) === "\"")
    text = text.substring(1, text.length - 1)
  return text.replace(/\\(.)/g, "$1").trim()
}

// Invariant: parse mailbox structure before decoding display words; decoded punctuation must never create a recipient.
function addressSyntax(value) {
  return String(value || "").replace(/=\?[^?\s]+\?[bq]\?[^?]*\?=/gi, function(word) {
    return new Array(word.length + 1).join(" ")
  })
}

function parseAddress(value) {
  var raw = String(value || "").trim()
  if (!raw) return { name: "", email: "", display: "" }
  var syntax = addressSyntax(raw)
  var angled = syntax.match(/^(.*)<([^<>]*)>\s*$/)
  var name = angled ? decodeHeaderValue(unquote(raw.substring(0, angled[1].length))) : ""
  var email = angled ? angled[2].trim() : syntax.trim()
  if (!/^(?:"(?:[^"\\]|\\.)*"|[^\s<>()\[\],;:@"\\]+)@(?:\[[^\r\n\]]+\]|[^\s<>()\[\],;:@"\\]+)$/.test(email)) email = ""
  if (!name && email === "") name = decodeHeaderValue(unquote(raw))
  if (!name && email.indexOf("@") > 0) name = email.substring(0, email.indexOf("@"))
  return { name: name, email: email, display: name || email }
}

function parseAddressList(value) {
  var raw = String(value || "")
  var syntax = addressSyntax(raw)
  var entries = []
  var start = 0
  var inQuotes = false
  var inAngle = false
  for (var characterIndex = 0; characterIndex < syntax.length; characterIndex++) {
    var character = syntax.charAt(characterIndex)
    if (inQuotes && character === "\\") {
      characterIndex++
      continue
    }
    if (character === "\"") inQuotes = !inQuotes
    if (inQuotes) continue
    if (character === "<") inAngle = true
    else if (character === ">") inAngle = false
    if (inAngle) continue
    if (character === ":") {
      start = characterIndex + 1
      continue
    }
    if (character !== "," && character !== ";") continue
    entries.push(raw.substring(start, characterIndex))
    start = characterIndex + 1
  }
  entries.push(raw.substring(start))
  var result = []
  for (var entryIndex = 0; entryIndex < entries.length; entryIndex++) {
    var parsed = parseAddress(entries[entryIndex])
    if (parsed.email !== "") result.push(parsed)
  }
  return result
}

function formatAddressList(addresses, limit) {
  var list = Array.isArray(addresses) ? addresses : []
  var max = Math.max(1, Math.floor(Number(limit) || 3))
  var names = []
  for (var listIndex = 0; listIndex < list.length && listIndex < max; listIndex++) names.push(list[listIndex].display)
  if (list.length > max) names.push("+" + (list.length - max))
  return names.join(", ")
}

function partCharset(part) {
  var mime = String(part && part.mimeType ? part.mimeType : "")
  var match = mime.match(/charset="?([^";]+)"?/i)
  if (match) return match[1]
  var headers = part && Array.isArray(part.headers) ? part.headers : []
  for (var headerIndex = 0; headerIndex < headers.length; headerIndex++) {
    if (String(headers[headerIndex].name || "").toLowerCase() !== "content-type") continue
    var found = String(headers[headerIndex].value || "").match(/charset="?([^";\s]+)"?/i)
    if (found) return found[1]
  }
  return ""
}

function decodePart(part) {
  var data = part && part.body ? part.body.data : ""
  if (!data) return ""
  return decodeWordBytes(partCharset(part) || "utf-8", base64ToBytes(data))
}

// Invariant: preserve image markers when flattening markup so a non-text message does not appear empty.
var IMAGE_MARKER = /\[image (\d+)\]/g

function htmlToText(html) {
  var imageCount = 0
  return String(html || "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, "")
    // Invariant: reader text and image IDs come from one Html walk; this fallback serves escaped snippets.
    .replace(/<img\b(?:[^>"']|"[^"]*"|'[^']*')*>/gi, function() {
      imageCount++
      return "[image " + imageCount + "]"
    })
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|tr|li|h[1-6])>/gi, "\n")
    .replace(/<li[^>]*>/gi, "• ")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, "\"")
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&#(\d+);/g, function(match, code) { return String.fromCharCode(Number(code)) })
    .replace(/&#x([0-9a-fA-F]+);/g, function(match, code) { return String.fromCharCode(parseInt(code, 16)) })
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/^\s+|\s+$/g, "")
}

function partHeader(part, wanted) {
  var headers = part && Array.isArray(part.headers) ? part.headers : []
  for (var headerIndex = 0; headerIndex < headers.length; headerIndex++) {
    if (String(headers[headerIndex].name || "").toLowerCase() === wanted)
      return String(headers[headerIndex].value || "")
  }
  return ""
}

function disposition(part) {
  return partHeader(part, "content-disposition").split(";")[0].trim().toLowerCase()
}

function embeddedImage(part) {
  if (!part || !/^image\//i.test(String(part.mimeType || ""))) return false
  var kind = disposition(part)
  return kind !== "attachment"
    && (kind === "inline" || partHeader(part, "content-id").trim().length > 0)
}

function isAttachment(part) {
  if (!part) return false
  if (embeddedImage(part)) return false
  if (part.filename && String(part.filename).length > 0) return true
  return disposition(part) === "attachment"
}

// Invariant: prefer text/plain; HTML flattening is a fallback because it loses formatting.
function extractBody(payload) {
  var plain = ""
  var html = ""

  function walk(part, depth) {
    if (!part || depth > 12) return
    var mime = String(part.mimeType || "").toLowerCase()
    var children = Array.isArray(part.parts) ? part.parts : []
    if (children.length > 0) {
      for (var childIndex = 0; childIndex < children.length; childIndex++) walk(children[childIndex], depth + 1)
      return
    }
    if (isAttachment(part)) return
    if (mime.indexOf("text/plain") === 0 && !plain) plain = decodePart(part)
    else if (mime.indexOf("text/html") === 0 && !html) html = decodePart(part)
  }

  walk(payload, 0)
  if (plain) return { text: plain.replace(/\r\n/g, "\n"), source: "plain" }
  if (html) return { text: htmlToText(html), source: "html" }
  return { text: "", source: "" }
}

// Performance: plain text and markup extraction stay separate so callers do not pay for both walks.
function extractHtml(payload) {
  var found = ""

  function walk(part, depth) {
    if (!part || depth > 12 || found) return
    var mime = String(part.mimeType || "").toLowerCase()
    var children = Array.isArray(part.parts) ? part.parts : []
    if (children.length > 0) {
      for (var childIndex = 0; childIndex < children.length; childIndex++) walk(children[childIndex], depth + 1)
      return
    }
    if (isAttachment(part)) return
    if (mime.indexOf("text/html") === 0) found = decodePart(part)
  }

  walk(payload, 0)
  return found
}

function attachments(payload) {
  var found = []

  function walk(part, depth) {
    if (!part || depth > 12) return
    var children = Array.isArray(part.parts) ? part.parts : []
    if (isAttachment(part) && part.body && part.body.attachmentId) {
      found.push({
        filename: decodeHeaderValue(part.filename || "attachment"),
        mimeType: String(part.mimeType || "application/octet-stream"),
        size: Math.max(0, Math.floor(Number(part.body.size) || 0)),
        attachmentId: String(part.body.attachmentId)
      })
    }
    for (var childIndex = 0; childIndex < children.length; childIndex++) walk(children[childIndex], depth + 1)
  }

  walk(payload, 0)
  return found
}

function partForAttachment(payload, attachmentId) {
  var wanted = String(attachmentId || "")
  if (wanted === "") return null
  var found = null

  function walk(part, depth) {
    if (!part || depth > 12 || found !== null) return
    if (part.body && String(part.body.attachmentId || "") === wanted) {
      found = part
      return
    }
    var children = Array.isArray(part.parts) ? part.parts : []
    for (var childIndex = 0; childIndex < children.length; childIndex++) walk(children[childIndex], depth + 1)
  }

  walk(payload, 0)
  return found
}

function formatSize(bytes) {
  var value = Math.max(0, Math.floor(Number(bytes) || 0))
  if (value < 1024) return value + " B"
  if (value < 1024 * 1024) return (value / 1024).toFixed(value < 10240 ? 1 : 0) + " KB"
  return (value / (1024 * 1024)).toFixed(value < 10485760 ? 1 : 0) + " MB"
}

function formatCount(count, singular) {
  var amount = Math.max(0, Math.floor(Number(count) || 0))
  var noun = String(singular || "item")
  return amount + " " + noun + (amount === 1 ? "" : "s")
}

// Docs: MIME input is a byte string, one character per octet; the result uses the shared provider payload shape.

var MAX_MIME_DEPTH = 12

function latin1Bytes(text) {
  var input = String(text || "")
  var bytes = []
  for (var index = 0; index < input.length; index++) bytes.push(input.charCodeAt(index) & 0xff)
  return bytes
}

// Invariant: body quoted-printable preserves underscores and removes soft line breaks, unlike encoded-word decoding.
function decodeQuotedPrintableBytes(text) {
  var input = String(text || "").replace(/=\r?\n/g, "")
  var bytes = []
  for (var index = 0; index < input.length; index++) {
    if (input.charAt(index) === "=" && index + 2 < input.length) {
      var hex = input.substr(index + 1, 2)
      if (/^[0-9A-Fa-f]{2}$/.test(hex)) {
        bytes.push(parseInt(hex, 16))
        index += 2
        continue
      }
    }
    bytes.push(input.charCodeAt(index) & 0xff)
  }
  return bytes
}

// Invariant: unfold header continuations before finding field separators.
function unfoldHeaders(text) {
  return String(text || "").replace(/\r?\n[ \t]+/g, " ")
}

function parseHeaderBlock(text) {
  var lines = unfoldHeaders(text).split(/\r?\n/)
  var headers = []
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    var line = lines[lineIndex]
    if (line === "") continue
    var colon = line.indexOf(":")

    if (colon <= 0) continue
    headers.push({
      name: line.substring(0, colon).trim(),
      value: line.substring(colon + 1).trim()
    })
  }
  return headers
}

function headerFrom(headers, name) {
  var list = Array.isArray(headers) ? headers : []
  var wanted = String(name || "").toLowerCase()
  for (var listIndex = 0; listIndex < list.length; listIndex++) {
    if (String(list[listIndex].name || "").toLowerCase() === wanted) return String(list[listIndex].value || "")
  }
  return ""
}

// Docs: RFC 2231 filename continuations are unsupported; ordinary quoted and bare parameters are parsed structurally.
function contentTypeParam(value, name) {
  var text = String(value || "")
  var wanted = String(name || "").toLowerCase()
  var parameter = /;\s*([^=;\s]+)\s*=\s*("(?:[^"\\]|\\.)*"|[^;\s]*)/g
  var match
  while ((match = parameter.exec(text)) !== null) {
    if (match[1].toLowerCase() !== wanted) continue
    var found = match[2]
    return found.charAt(0) === "\"" ? unquote(found) : found.trim()
  }
  return ""
}

function mimeTypeOf(contentType) {
  var value = String(contentType || "").split(";")[0].trim().toLowerCase()
  // Invariant: absent Content-Type defaults to text/plain.
  return value === "" ? "text/plain" : value
}

// Invariant: multipart delimiters begin a line; preambles and epilogues are outside all parts.
function splitMultipart(body, boundary) {
  var text = String(body || "")
  var marker = String(boundary || "")
  if (marker === "") return []
  var delimiter = new RegExp("^--" + marker.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "([^\\r\\n]*)(?:\\r?\\n|$)", "gm")
  var parts = []
  var start = -1
  var match
  while ((match = delimiter.exec(text)) !== null) {
    if (start >= 0) parts.push(text.substring(start, match.index).replace(/\r?\n$/, ""))
    if (match[1].substring(0, 2) === "--") return parts
    start = delimiter.lastIndex
  }
  if (start >= 0 && start < text.length) parts.push(text.substring(start).replace(/\r?\n$/, ""))
  return parts
}

// Invariant: HTML sniffing is limited to a body whose declared type is already unusable.
function looksLikeHtml(body) {
  return /^\s*(<!doctype\s+html|<html\b|<head\b|<body\b|<div\b|<table\b|<p\b)/i
    .test(String(body || ""))
}

function decodeTransfer(body, encoding) {
  var name = String(encoding || "").trim().toLowerCase()
  if (name === "base64") return base64ToBytes(body)
  if (name === "quoted-printable") return decodeQuotedPrintableBytes(body)
  // Docs: unknown transfer encodings retain the original octets.
  return latin1Bytes(body)
}

// Docs: partId is the RFC 3501 MIME part path used for attachment identity.
function parseMimeEntity(raw, partId, depth) {
  var text = String(raw || "")
  // Invariant: tolerate bare LF as well as RFC 5322 CRLF when separating headers from the body.
  var split = text.search(/\r?\n\r?\n/)
  var headerText = split < 0 ? text : text.substring(0, split)
  var body = ""
  if (split >= 0) {
    var blank = text.match(/\r?\n\r?\n/)
    body = text.substring(split + blank[0].length)
  }

  var headers = parseHeaderBlock(headerText)
  var contentType = headerFrom(headers, "Content-Type")
  var mimeType = mimeTypeOf(contentType)
  var disposition = headerFrom(headers, "Content-Disposition")
  var filename = contentTypeParam(disposition, "filename") || contentTypeParam(contentType, "name")

  var entity = {
    partId: String(partId || ""),
    mimeType: mimeType,
    filename: filename ? decodeHeaderValue(filename) : "",
    headers: headers,
    body: { size: 0 },
    parts: []
  }

  var boundary = contentTypeParam(contentType, "boundary")
  if (mimeType.indexOf("multipart/") === 0 && boundary !== "" && depth < MAX_MIME_DEPTH) {
    var chunks = splitMultipart(body, boundary)
    for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
      var childId = entity.partId === "" ? String(chunkIndex + 1) : entity.partId + "." + String(chunkIndex + 1)
      entity.parts.push(parseMimeEntity(chunks[chunkIndex], childId, depth + 1))
    }
    // Invariant: a missing multipart boundary falls back to a leaf type so its body remains reachable.
    if (entity.parts.length > 0) return entity
    entity.mimeType = looksLikeHtml(body) ? "text/html" : "text/plain"
  }

  var bytes = decodeTransfer(body, headerFrom(headers, "Content-Transfer-Encoding"))
  entity.body.size = bytes.length
  // Invariant: preserve decoded byte values when converting to the provider payload's base64url representation.
  entity.body.data = bytesToBase64(bytes, true)

  // Invariant: attachment listing requires a stable part ID even before any separate fetch.
  if (entity.filename !== "" || /attachment/i.test(disposition))
    entity.body.attachmentId = "part:" + entity.partId

  return entity
}

// Docs: parseMime returns payload only; provider metadata supplies IDs, labels, and receipt time.
function parseRfc822(raw) {
  return parseMimeEntity(raw, "", 0)
}

// Performance: derive a bounded IMAP preview once rather than cache a second full body.
function buildSnippet(text) {
  return String(text || "")
    .replace(/\s+/g, " ")
    .trim()
    .substring(0, 200)
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

function messageDate(message) {
  var internal = Number(message && message.internalDate)
  if (isFinite(internal) && internal > 0) return new Date(internal)
  var header = headerValue(message, "Date")
  if (header) {
    var parsed = new Date(header)
    if (!isNaN(parsed.getTime())) return parsed
  }
  return null
}

function pad(value) {
  return (value < 10 ? "0" : "") + value
}

function relativeTime(date, now) {
  if (!date) return ""
  var reference = now instanceof Date ? now : new Date(Number(now) || Date.now())
  var elapsed = reference.getTime() - date.getTime()
  if (elapsed < 0) elapsed = 0
  var minutes = Math.floor(elapsed / 60000)
  if (minutes < 1) return "now"
  if (minutes < 60) return minutes + "m"
  var sameDay = date.getFullYear() === reference.getFullYear()
    && date.getMonth() === reference.getMonth()
    && date.getDate() === reference.getDate()
  if (sameDay) return pad(date.getHours()) + ":" + pad(date.getMinutes())
  var days = Math.floor(elapsed / 86400000)
  if (days < 3) return WEEKDAYS[date.getDay()]
  if (days < 365)
    return MONTHS[date.getMonth()] + " " + date.getDate()
  return MONTHS[date.getMonth()] + " " + date.getDate() + ", " + date.getFullYear()
}

function fullTime(date) {
  if (!date) return ""
  return MONTHS[date.getMonth()] + " " + date.getDate() + ", " + date.getFullYear()
    + " " + pad(date.getHours()) + ":" + pad(date.getMinutes())
}

function labelIds(message) {
  return message && Array.isArray(message.labelIds) ? message.labelIds : []
}

function hasLabel(message, label) {
  return labelIds(message).indexOf(label) >= 0
}

function decodeSnippet(text) {
  // Invariant: Gmail snippets are entity-escaped prose even when they contain no markup.
  return htmlToText(String(text || "")).replace(/\s+/g, " ").trim()
}

// Docs: every summary carries a provider-neutral conversation; memberIds are oldest first and count matches their length.
function threadOf(message) {
  var source = message && message.thread && typeof message.thread === "object"
    ? message.thread : {}
  return normalizeThread(source, message ? message.threadId : "")
}

function normalizeThread(block, fallbackId) {
  var source = block && typeof block === "object" ? block : {}
  var list = Array.isArray(source.memberIds) ? source.memberIds : []
  var ids = []
  for (var listIndex = 0; listIndex < list.length; listIndex++) {
    var id = String(list[listIndex] === undefined || list[listIndex] === null ? "" : list[listIndex]).trim()
    if (id !== "") ids.push(id)
  }
  return {
    id: String(source.id || fallbackId || "").trim(),
    count: ids.length,
    unread: source.unread === true,
    flagged: source.flagged === true,
    memberIds: ids
  }
}

function hasAttachments(message) {
  var budget = 4000
  function walk(part, depth) {
    if (!part || depth > 12 || budget <= 0) return false
    budget--
    if (isAttachment(part)) return true
    var parts = Array.isArray(part.parts) ? part.parts : []
    for (var partIndex = 0; partIndex < parts.length; partIndex++) if (walk(parts[partIndex], depth + 1)) return true
    return false
  }
  return !!message && (message.hasAttachments === true || walk(message.payload, 0))
}

function summarize(message, now) {
  var from = parseAddress(headerValue(message, "From"))
  var date = messageDate(message)
  var subject = decodedHeader(message, "Subject").replace(/\s+/g, " ").trim()
  var thread = threadOf(message)
  return {
    id: String(message && message.id ? message.id : ""),
    threadId: String(message && message.threadId ? message.threadId : ""),
    from: from,
    // Invariant: list metadata can omit Reply-To and Message-ID; full reader metadata supplies reply routing.
    replyTo: parseAddress(headerValue(message, "Reply-To")),
    messageId: headerValue(message, "Message-ID"),
    to: parseAddressList(headerValue(message, "To")),
    cc: parseAddressList(headerValue(message, "Cc")),
    bcc: parseAddressList(headerValue(message, "Bcc")),
    inReplyTo: headerValue(message, "In-Reply-To"),
    subject: subject || "(no subject)",
    snippet: decodeSnippet(message && message.snippet),
    date: date,
    time: relativeTime(date, now),
    fullTime: fullTime(date),
    thread: thread,
    // Invariant: conversation unread and flagged state comes from all counted members, not just the representative.
    unread: hasLabel(message, "UNREAD") || thread.unread,
    starred: hasLabel(message, "STARRED") || thread.flagged,
    important: hasLabel(message, "IMPORTANT"),
    inInbox: hasLabel(message, "INBOX"),
    inTrash: hasLabel(message, "TRASH"),
    inSpam: hasLabel(message, "SPAM"),
    isSent: hasLabel(message, "SENT"),
    isDraft: hasLabel(message, "DRAFT"),
    labelIds: labelIds(message).slice(),
    hasAttachments: hasAttachments(message),
    sizeEstimate: Math.max(0, Math.floor(Number(message && message.sizeEstimate) || 0))
  }
}

function draftAddressText(addresses) {
  var list = Array.isArray(addresses) ? addresses : []
  var out = []
  for (var listIndex = 0; listIndex < list.length; listIndex++) {
    var email = String(list[listIndex] && list[listIndex].email ? list[listIndex].email : "").trim()
    if (email !== "") out.push(email)
  }
  return out.join(", ")
}

function draftFields(summary, body) {
  var source = summary || ({})
  var subject = String(source.subject || "")
  return {
    mode: "draft",
    from: String(source.from && source.from.email ? source.from.email : ""),
    to: draftAddressText(source.to),
    cc: draftAddressText(source.cc),
    bcc: draftAddressText(source.bcc),
    // Invariant: preserve a saved draft's Reply-To field across another save.
    replyTo: String(source.replyTo && source.replyTo.email ? source.replyTo.email : ""),
    subject: subject === "(no subject)" ? "" : subject,
    body: String(body || ""),
    threadId: String(source.threadId || ""),
    inReplyTo: String(source.inReplyTo || "")
  }
}

// Invariant: outgoing header values cannot contain line breaks that would introduce another header.
function headerSafe(value) {
  return String(value === undefined || value === null ? "" : value).replace(/[\r\n]+/g, " ")
}

// Invariant: encoded display words belong outside quotes; ASCII display punctuation uses a quoted phrase.
function encodedPhrase(text) {
  var value = headerSafe(text).trim()
  if (value === "") return ""
  if (!/^[\x20-\x7e]*$/.test(value))
    return "=?UTF-8?B?" + encodeBase64(value) + "?="
  return '"' + value.replace(/([\\"])/g, "\\$1") + '"'
}

// Docs: addressHeader returns a mailbox header value, without a field name, so provider adapters can reuse it.
function addressHeader(email, displayName) {
  var address = headerSafe(email).trim()
  var phrase = encodedPhrase(displayName)
  return phrase === "" ? address : phrase + " <" + address + ">"
}

function fromHeader(email, displayName) {
  return "From: " + addressHeader(email, displayName)
}

function foldHeader(name, value) {
  var text = headerSafe(value)
  // Invariant: encode non-ASCII header values as RFC 2047 words for Gmail raw messages.
  if (/^[\x20-\x7e]*$/.test(text)) return name + ": " + text
  return name + ": =?UTF-8?B?" + encodeBase64(text) + "?="
}

// Invariant: sender-controlled threading IDs must remain bounded, printable, and on one line.
function referenceValue(value) {
  return headerSafe(value).replace(/[^\x20-\x7e]+/g, "").substring(0, 512).trim()
}

function quoteBody(summary, body) {
  var header = summary && summary.from
    ? "On " + (summary.fullTime || "") + ", " + summary.from.display + " wrote:"
    : ""
  var lines = String(body || "").split("\n")
  var quoted = []
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) quoted.push("> " + lines[lineIndex])
  return (header ? header + "\n" : "") + quoted.join("\n")
}

// Invariant: placed signatures precede quoted history and follow the editable reply space.
function composeBody(signature, quoted) {
  var parts = []
  var sign = String(signature === undefined || signature === null ? "" : signature).trim()
  var quote = String(quoted === undefined || quoted === null ? "" : quoted)
  if (sign !== "") parts.push(sign)
  if (quote !== "") parts.push(quote)
  if (parts.length === 0) return ""
  return "\n\n" + parts.join("\n\n")
}

function replySubject(subject) {
  var text = String(subject || "").trim()
  if (/^re:/i.test(text)) return text
  return "Re: " + (text || "(no subject)")
}

// Invariant: MIME base64 lines wrap at 76 characters for receiving-server interoperability.
function base64Body(text) {
  var encoded = encodeBase64(String(text || ""))
  var wrapped = []
  for (var index = 0; index < encoded.length; index += 76) wrapped.push(encoded.substr(index, 76))
  return wrapped.join("\r\n")
}

// Invariant: convert base64 alphabets without decoding binary attachments through a text string.
function mimeBase64(data) {
  var encoded = String(data || "").replace(/[\r\n\s]/g, "")
    .replace(/-/g, "+").replace(/_/g, "/")
  while (encoded.length % 4 !== 0) encoded += "="
  var wrapped = []
  for (var index = 0; index < encoded.length; index += 76) wrapped.push(encoded.substr(index, 76))
  return wrapped.join("\r\n")
}

function attachmentType(value) {
  var type = String(value || "").split(";")[0].trim().toLowerCase()
  return /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(type)
    ? type : "application/octet-stream"
}

// Invariant: generated boundaries contain an underscore absent from standard base64 bodies.
function mimeBoundary(given) {
  var stated = String(given || "").replace(/[^A-Za-z0-9'()+_,\-.\/:=?]/g, "")
  if (stated !== "") return stated.substring(0, 60)
  var random = Math.floor(Math.random() * 0x100000000).toString(36)
  return "=_Omamail_" + (new Date()).getTime().toString(36) + "_" + random
}

function addressDomain(value) {
  var address = headerSafe(value).trim()
  var at = address.lastIndexOf("@")
  return at < 0 ? "" : address.substring(at + 1).replace(/[^A-Za-z0-9.-]/g, "")
}

// Invariant: Message-ID uses the explicit sender domain or the signed-in mailbox domain.
function messageIdDomain(from, accountAddress) {
  var domain = addressDomain(from) || addressDomain(accountAddress)
  // Invariant: RFC 2606 .invalid avoids borrowing a real domain when no sender domain is available.
  return domain === "" ? "omamail.invalid" : domain
}

function messageIdValue(given, from, nowMilliseconds, accountAddress) {
  var stated = String(given === undefined || given === null ? "" : given)
  // Invariant: replace a malformed caller-supplied Message-ID with a generated valid one.
  if (stated.length <= 250
      && /^<[A-Za-z0-9!#$%&'*+\/=?^_\x60{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+\/=?^_\x60{|}~-]+)*@[A-Za-z0-9!#$%&'*+\/=?^_\x60{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+\/=?^_\x60{|}~-]+)*>$/.test(stated))
    return stated
  var now = Math.floor(Number(nowMilliseconds) || Date.now())
  var random = Math.floor(Math.random() * 0x100000000).toString(36)
  return "<" + now.toString(36) + "." + random + ".omamail@"
    + messageIdDomain(from, accountAddress) + ">"
}

// Invariant: outgoing Date uses RFC 5322 numeric timezone syntax.
function sentDate(given, nowMilliseconds) {
  var stated = headerSafe(given).trim()
  // Invariant: JavaScript date parsing accepts non-header syntax; validate canonical header shape and calendar fields first.
  var canonical = /^(Sun|Mon|Tue|Wed|Thu|Fri|Sat), (0[1-9]|[12][0-9]|3[01]) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ([0-9]{4}) ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9] [+-][0-9]{2}[0-5][0-9]$/
  var parts = stated.match(canonical)
  if (parts) {
    var day = Number(parts[2])
    var month = MONTHS.indexOf(parts[3])
    var year = Number(parts[4])
    var calendar = new Date(Date.UTC(year, month, day))
    if (year >= 1900 && calendar.getUTCFullYear() === year && calendar.getUTCMonth() === month
        && calendar.getUTCDate() === day && WEEKDAYS[calendar.getUTCDay()] === parts[1])
      return stated
  }
  var date = new Date(nowMilliseconds === undefined || nowMilliseconds === null ? Date.now() : Number(nowMilliseconds))
  if (isNaN(date.getTime())) date = new Date()
  var offset = -date.getTimezoneOffset()
  var minutes = Math.abs(offset)
  return WEEKDAYS[date.getDay()] + ", " + pad(date.getDate()) + " " + MONTHS[date.getMonth()]
    + " " + date.getFullYear() + " " + pad(date.getHours()) + ":" + pad(date.getMinutes())
    + ":" + pad(date.getSeconds()) + " " + (offset < 0 ? "-" : "+")
    + pad(Math.floor(minutes / 60)) + pad(minutes % 60)
}

// Invariant: an untrusted calendar method cannot introduce another MIME header.
function calendarMethod(value) {
  var text = String(value || "").toUpperCase().replace(/[^A-Z]/g, "")
  return text === "" ? "REPLY" : text.substring(0, 20)
}

// Invariant: an RTL plain-text message needs an HTML alternative to carry its direction to receiving clients.
function outgoingDirection(body) {
  return Direction.resolve(body, Direction.AUTO)
}

// Invariant: the HTML direction alternative escapes body text and preserves the plain-text alternative.
function directionalHtmlBody(text, direction) {
  var body = String(text === undefined || text === null ? "" : text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\r\n/g, "\n")
    .replace(/\n/g, "<br>\n")
  return "<html><body dir=\"" + direction + "\">" + body + "</body></html>"
}

// Invariant: RFC 2046 forbids a nested boundary beginning with the outer boundary; prefix the inner name instead of suffixing it.
function nestedBoundary(outer) {
  return mimeBoundary("alt_" + String(outer || ""))
}

// Invariant: inline signature images use related CID parts because Gmail does not render data URLs in received HTML.
function htmlBodyWithSignature(body, plainSignature, signatureHtml, direction) {
  var text = String(body === undefined || body === null ? "" : body)
  var sign = String(plainSignature === undefined || plainSignature === null ? "" : plainSignature).trim()
  var directionAttribute = Direction.isRightToLeft(direction) ? " dir=\"rtl\"" : ""
  // Invariant: replace the first sign-off only; a signature removed from plain text must not reappear in markup.
  var at = sign === "" ? -1 : text.indexOf(sign)
  if (sign !== "" && at < 0)
    return "<html><body" + directionAttribute + ">" + escapedParagraphs(text) + "</body></html>"
  var before, after
  if (at >= 0) {
    before = text.slice(0, at)
    after = text.slice(at + sign.length)
  } else {
    // Invariant: an image-only signature has no text marker and belongs before quoted history.
    var quoteAt = text.search(/(^|\n)>/)
    before = quoteAt >= 0 ? text.slice(0, quoteAt) : text
    after = quoteAt >= 0 ? text.slice(quoteAt) : ""
  }
  return "<html><body" + directionAttribute + ">" + escapedParagraphs(before)
    + String(signatureHtml || "") + escapedParagraphs(after) + "</body></html>"
}

function escapedParagraphs(text) {
  var lines = String(text || "").replace(/\r\n/g, "\n").split("\n")
  var out = []
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    out.push(lines[lineIndex].replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"))
  }
  var joined = out.join("<br>")
  return joined === "" ? "" : "<div>" + joined + "</div>"
}

function pushSignedBodyPart(lines, values, direction, boundary) {
  var swapped = Signature.inlineParts(values.signatureHtml, "sig")
  var html = htmlBodyWithSignature(values.body, values.signature, swapped.html, direction)
  var alt = nestedBoundary(boundary)
  var related = swapped.parts.length > 0 ? boundary : ""
  if (related !== "") {
    lines.push("Content-Type: multipart/related; boundary=\"" + related + "\"; type=\"multipart/alternative\"")
    lines.push("")
    lines.push("--" + related)
  }
  lines.push("Content-Type: multipart/alternative; boundary=\"" + alt + "\"")
  lines.push("")
  lines.push("--" + alt)
  lines.push("Content-Type: text/plain; charset=UTF-8")
  lines.push("Content-Transfer-Encoding: base64")
  lines.push("")
  lines.push(base64Body(values.body))
  lines.push("--" + alt)
  lines.push("Content-Type: text/html; charset=UTF-8")
  lines.push("Content-Transfer-Encoding: base64")
  lines.push("")
  lines.push(base64Body(html))
  lines.push("--" + alt + "--")
  for (var index = 0; index < swapped.parts.length; index++) {
    var part = swapped.parts[index]
    lines.push("--" + related)
    lines.push("Content-Type: " + part.mimeType)
    lines.push("Content-Transfer-Encoding: base64")
    lines.push("Content-ID: <" + part.cid + ">")
    lines.push("Content-Disposition: inline")
    lines.push("")
    lines.push(mimeBase64(part.data))
  }
  if (related !== "") lines.push("--" + related + "--")
}

function pushBodyPart(lines, body, direction, boundary, values) {
  if (values && String(values.signatureHtml || "") !== "") {
    pushSignedBodyPart(lines, values, direction, boundary)
    return
  }
  if (!Direction.isRightToLeft(direction)) {
    lines.push("Content-Type: text/plain; charset=UTF-8")
    lines.push("Content-Transfer-Encoding: base64")
    lines.push("")
    lines.push(base64Body(body))
    return
  }
  // Invariant: MIME alternatives appear least preferred first so capable clients choose the directional HTML.
  lines.push("Content-Type: multipart/alternative; boundary=\"" + boundary + "\"")
  lines.push("")
  lines.push("--" + boundary)
  lines.push("Content-Type: text/plain; charset=UTF-8")
  lines.push("Content-Transfer-Encoding: base64")
  lines.push("")
  lines.push(base64Body(body))
  lines.push("--" + boundary)
  lines.push("Content-Type: text/html; charset=UTF-8")
  lines.push("Content-Transfer-Encoding: base64")
  lines.push("")
  lines.push(base64Body(directionalHtmlBody(body, direction)))
  lines.push("--" + boundary + "--")
}

function buildRawMessage(fields) {
  var values = fields || {}
  // Invariant: Date and Message-ID use one clock reading.
  var now = Date.now()
  var lines = []
  if (values.from) lines.push(fromHeader(values.from, values.fromName))
  lines.push(foldHeader("To", values.to || ""))
  if (values.cc) lines.push(foldHeader("Cc", values.cc))
  if (values.bcc) lines.push(foldHeader("Bcc", values.bcc))
  // Invariant: Reply-To uses the same header-injection protection as other outgoing fields.
  if (values.replyTo) lines.push(foldHeader("Reply-To", values.replyTo))
  lines.push(foldHeader("Subject", values.subject || ""))
  var inReplyTo = referenceValue(values.inReplyTo)
  if (inReplyTo) {
    lines.push("In-Reply-To: " + inReplyTo)
    lines.push("References: " + (referenceValue(values.references) || inReplyTo))
  }
  // Invariant: originated messages include Date while preserving the established From-first header order.
  lines.push("Date: " + sentDate(values.date, now))
  // Invariant: originate Message-ID because a relay may leave missing headers unchanged.
  lines.push("Message-ID: "
    + messageIdValue(values.messageId, values.from, now, values.accountAddress))
  lines.push("MIME-Version: 1.0")

  var calendar = values.calendar && String(values.calendar.text || "") !== ""
    ? values.calendar : null
  var attachments = Array.isArray(values.attachments) ? values.attachments : []
  var included = []
  for (var attachmentIndex = 0; attachmentIndex < attachments.length; attachmentIndex++) {
    var attachment = attachments[attachmentIndex] || ({})
    if (attachment.data === undefined || attachment.data === null) continue
    included.push(attachment)
  }

  // Invariant: sent messages and saved drafts share one direction decision.
  var direction = outgoingDirection(values.body)

  if (!calendar && included.length === 0) {
    pushBodyPart(lines, values.body, direction, mimeBoundary(values.boundary), values)
    return lines.join("\r\n") + "\r\n"
  }

  if (included.length > 0) {
    var mixedBoundary = mimeBoundary(values.boundary)
    lines.push("Content-Type: multipart/mixed; boundary=\"" + mixedBoundary + "\"")
    lines.push("")
    lines.push("--" + mixedBoundary)
    pushBodyPart(lines, values.body, direction, nestedBoundary(mixedBoundary), values)
    for (var includedIndex = 0; includedIndex < included.length; includedIndex++) {
      var file = included[includedIndex]
      var filename = String(file.filename || "attachment")
      lines.push("--" + mixedBoundary)
      lines.push("Content-Type: " + attachmentType(file.mimeType)
        + "; name=" + encodedPhrase(filename))
      lines.push("Content-Transfer-Encoding: base64")
      lines.push("Content-Disposition: attachment; filename=" + encodedPhrase(filename))
      lines.push("")
      lines.push(mimeBase64(file.data))
    }
    lines.push("--" + mixedBoundary + "--")
    return lines.join("\r\n") + "\r\n"
  }

  // Invariant: calendar replies use multipart/alternative for the human sentence and RFC 5546 payload.
  var boundary = mimeBoundary(values.boundary)
  lines.push("Content-Type: multipart/alternative; boundary=\"" + boundary + "\"")
  lines.push("")
  lines.push("--" + boundary)
  lines.push("Content-Type: text/plain; charset=UTF-8")
  lines.push("Content-Transfer-Encoding: base64")
  lines.push("")
  lines.push(base64Body(values.body))
  lines.push("--" + boundary)
  lines.push("Content-Type: text/calendar; charset=UTF-8; method="
    + calendarMethod(calendar.method))
  lines.push("Content-Transfer-Encoding: base64")
  lines.push("")
  lines.push(base64Body(calendar.text))
  lines.push("--" + boundary + "--")
  return lines.join("\r\n") + "\r\n"
}

function buildSendPayload(fields) {
  var payload = { raw: encodeBase64Url(buildRawMessage(fields)) }
  if (fields && fields.threadId) payload.threadId = String(fields.threadId)
  // Invariant: send and save retain the replaced draft ID so capable providers can remove the previous copy atomically.
  payload.draftId = String((fields && fields.draftId) || "")
  var files = Array.isArray(fields && fields.attachments) ? fields.attachments : []
  var paths = []
  for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
    if (files[fileIndex] && files[fileIndex].path)
      paths.push({ path: String(files[fileIndex].path), filename: String(files[fileIndex].filename || "") })
  }
  if (paths.length > 0) payload.attachments = paths
  return payload
}

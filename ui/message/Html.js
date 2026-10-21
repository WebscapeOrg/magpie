.pragma library

.import "Direction.js" as Direction

// Invariant: sanitize through tokenizer, tree, cleaning and serialization before Qt consumes mail.
// Qt can fetch resources and render hidden/style content. The bounded parser closes sender elements
// without HTML5 reparenting.

var RAW_TEXT_ELEMENTS = { script: true, style: true, textarea: true, title: true }

var VOID_ELEMENTS = {
  img: true, br: true, hr: true, input: true, meta: true, link: true,
  area: true, base: true, col: true, embed: true, source: true, track: true,
  wbr: true, param: true, keygen: true
}

// Performance: character codes avoid per-character string allocation in the tokenizer hot loop.
function isSpaceCode(code) {
  return code === 32 || code === 9 || code === 10 || code === 13 || code === 12
}

function isNameStartCode(code) {
  return (code >= 97 && code <= 122) || (code >= 65 && code <= 90)
}

function isNameCode(code) {
  return isNameStartCode(code) || (code >= 48 && code <= 57)
    || code === 45 || code === 95 || code === 58 || code === 46
}

function matchesIgnoreCase(text, at, needle) {
  if (at + needle.length > text.length) return false
  return text.substr(at, needle.length).toLowerCase() === needle
}

// Performance: the caller reuses the end/terminated output record to avoid one allocation per tag.
function readTag(text, from, out) {
  var length = text.length
  var at = from + 1
  var closing = false
  if (text.charCodeAt(at) === 47) {
    closing = true
    at++
  }

  if (!isNameStartCode(text.charCodeAt(at))) return null
  var nameStart = at
  var upper = false
  while (at < length) {
    var nameCode = text.charCodeAt(at)
    if (!isNameCode(nameCode)) break
    if (nameCode >= 65 && nameCode <= 90) upper = true
    at++
  }
  // Performance: fold names only when scanning found uppercase characters.
  var name = text.substring(nameStart, at)
  if (upper) name = name.toLowerCase()

  // Performance: ordinary closing tags need no attribute array or start-tag scan.
  if (closing) {
    var closeAt = at
    while (closeAt < length && isSpaceCode(text.charCodeAt(closeAt))) closeAt++
    if (text.charCodeAt(closeAt) === 62) {
      out.end = closeAt + 1
      out.terminated = true
      return { type: "end", name: name }
    }
  }

  var attributes = []
  var selfClosing = false
  while (at < length) {
    while (at < length && isSpaceCode(text.charCodeAt(at))) at++
    if (at >= length) break
    var code = text.charCodeAt(at)
    if (code === 62) {
      at++
      out.end = at
      out.terminated = true
      return {
        type: closing ? "end" : "start",
        name: name,
        attrs: attributes,
        selfClosing: selfClosing
      }
    }
    if (code === 47) {
      selfClosing = text.charCodeAt(at + 1) === 62
      at++
      continue
    }

    var attrStart = at
    var attrUpper = false
    while (at < length) {
      var attrCode = text.charCodeAt(at)
      if (isSpaceCode(attrCode) || attrCode === 61 || attrCode === 62 || attrCode === 47) break
      if (attrCode >= 65 && attrCode <= 90) attrUpper = true
      at++
    }

    if (at === attrStart) {
      at++
      continue
    }
    var attributeName = text.substring(attrStart, at)
    if (attrUpper) attributeName = attributeName.toLowerCase()

    while (at < length && isSpaceCode(text.charCodeAt(at))) at++
    var value = null
    if (text.charCodeAt(at) === 61) {
      at++
      while (at < length && isSpaceCode(text.charCodeAt(at))) at++
      var quote = text.charCodeAt(at)
      if (quote === 34 || quote === 39) {
        at++
        var close = text.indexOf(quote === 34 ? "\"" : "'", at)
        // Invariant: an unclosed quoted value consumes the remaining document, matching Qt.
        value = close < 0 ? text.substring(at) : text.substring(at, close)
        at = close < 0 ? length : close + 1
      } else {
        var valueStart = at
        while (at < length) {
          var valueCode = text.charCodeAt(at)
          if (isSpaceCode(valueCode) || valueCode === 62) break
          at++
        }
        value = text.substring(valueStart, at)
      }
    }
    attributes.push({ name: attributeName, value: value })
  }

  out.end = length
  out.terminated = false
  return {
    type: closing ? "end" : "start",
    name: name,
    attrs: attributes,
    selfClosing: selfClosing
  }
}

// Invariant: raw text ends at the first matching close tag, even inside a CSS or JavaScript string.
function findRawTextEnd(text, from, name) {
  var needle = "</" + name
  for (var at = from; at < text.length; at++) {
    if (text.charAt(at) !== "<") continue
    if (!matchesIgnoreCase(text, at, needle)) continue

    var after = text.charCodeAt(at + needle.length)
    if (!isNaN(after) && after !== 62 && after !== 47 && !isSpaceCode(after)) continue
    var close = text.indexOf(">", at + needle.length)
    return { contentEnd: at, next: close < 0 ? text.length : close + 1 }
  }
  return { contentEnd: text.length, next: text.length }
}

// Performance: parsing consumes tokens incrementally instead of allocating a complete intermediate
// list.
function tokenize(html, visit) {
  var text = String(html === undefined || html === null ? "" : html)
  var tokens = visit ? null : []
  var emit = visit || function(token) { tokens.push(token) }
  var pending = ""
  var at = 0
  var out = { end: 0, terminated: false }

  function flushText() {
    if (pending === "") return
    emit({ type: "text", text: pending })
    pending = ""
  }

  while (at < text.length) {
    var open = text.indexOf("<", at)
    if (open < 0) {
      pending += text.substring(at)
      break
    }
    pending += text.substring(at, open)

    // Performance: character codes avoid temporary strings for the per-tag comment check.
    if (text.charCodeAt(open + 1) === 33 && text.charCodeAt(open + 2) === 45
      && text.charCodeAt(open + 3) === 45) {
      var commentEnd = text.indexOf("-->", open + 4)
      flushText()
      emit({ type: "comment" })
      at = commentEnd < 0 ? text.length : commentEnd + 3
      continue
    }

    var second = text.charCodeAt(open + 1)
    if (second === 33 || second === 63) {
      var declarationEnd = text.indexOf(">", open + 2)
      flushText()
      emit({ type: "declaration" })
      at = declarationEnd < 0 ? text.length : declarationEnd + 1
      continue
    }

    var token = readTag(text, open, out)
    if (!token) {

      pending += "<"
      at = open + 1
      continue
    }
    flushText()
    if (out.terminated) emit(token)
    // Invariant: Qt consumes the rest of an unterminated tag; retaining its contents can expose a
    // hidden resource.
    at = out.end
    if (!out.terminated) break

    if (token.type === "start" && !token.selfClosing
      && RAW_TEXT_ELEMENTS[token.name] === true) {
      var raw = findRawTextEnd(text, at, token.name)
      emit({ type: "text", text: text.substring(at, raw.contentEnd), raw: true })
      emit({ type: "end", name: token.name })
      at = raw.next
    }
  }

  flushText()
  return tokens
}

// Invariant: unclosed sibling cells and list items must not accumulate artificial nesting.
var IMPLIED_CLOSE = {
  li: { li: true },
  p: { p: true },
  dt: { dt: true, dd: true },
  dd: { dt: true, dd: true },
  tr: { tr: true, td: true, th: true },
  td: { td: true, th: true },
  th: { td: true, th: true },
  thead: { thead: true, tbody: true, tfoot: true },
  tbody: { thead: true, tbody: true, tfoot: true },
  tfoot: { thead: true, tbody: true, tfoot: true },
  option: { option: true }
}

function elementNode(token) {
  return {
    type: "element",
    name: token.name,
    attrs: token.attrs,
    selfClosing: token.selfClosing === true,
    children: []
  }
}

// Invariant: recursive walks run on the desktop GUI thread. Keep the depth ceiling to prevent
// sender-controlled stack exhaustion.
var MAX_TREE_DEPTH = 128

function parse(html) {
  var root = { type: "root", children: [] }
  var stack = [root]

  tokenize(html, function(token) {
    var top = stack[stack.length - 1]

    if (token.type === "text") {
      // Performance: streaming text tokens already have the tree-node shape and are not reused.
      if (token.text !== "") top.children.push(token)
      return
    }
    // Invariant: Qt may display declarations as message text; they are not body content.
    if (token.type !== "start" && token.type !== "end") return

    if (token.type === "start") {
      var implied = IMPLIED_CLOSE[token.name]
      if (implied) {
        while (stack.length > 1 && implied[stack[stack.length - 1].name] === true) stack.pop()
        top = stack[stack.length - 1]
      }
      var node = elementNode(token)
      top.children.push(node)
      if (VOID_ELEMENTS[token.name] !== true && !node.selfClosing
        && stack.length < MAX_TREE_DEPTH) stack.push(node)
      return
    }

    for (var depth = stack.length - 1; depth > 0; depth--) {
      if (stack[depth].name === token.name) {
        stack.length = depth
        return
      }
    }
  })

  return root
}

// Invariant: preserve existing entity references during serialization; escaping ampersands again
// changes displayed text.

function serializeAttributes(attributes) {
  var out = ""
  for (var attributeIndex = 0; attributeIndex < attributes.length; attributeIndex++) {
    var attribute = attributes[attributeIndex]
    out += " " + attribute.name
    if (attribute.value === null || attribute.value === undefined) continue
    out += "=\"" + String(attribute.value).replace(/"/g, "&quot;") + "\""
  }
  return out
}

// Invariant: unwrapping elements or removing invisible characters can join text into new markup.
// Escape text-node angle brackets at the common serializer boundary.
function escapeMarkup(text) {
  var value = String(text)
  if (value.indexOf("<") < 0 && value.indexOf(">") < 0) return value
  return value.replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// Performance: one output buffer avoids copying the complete subtree again at every recursive
// level.
function serializeInto(node, out, fit) {
  if (node.type === "text") {
    out.push(escapeMarkup(node.text))
    return
  }
  if (node.type !== "root") {
    out.push("<" + node.name + serializeAttributes(fit ? fitAttributes(node, fit) : node.attrs))
    if (VOID_ELEMENTS[node.name] === true || node.selfClosing) {
      out.push(node.selfClosing ? "/>" : ">")
      return
    }
    out.push(">")
  }
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) serializeInto(node.children[childIndex], out, fit)
  if (node.type !== "root") out.push("</" + node.name + ">")
}

// Invariant: fitting must not mutate the tree reused at later window widths.
function serialize(node, fit) {
  var out = []
  serializeInto(node, out, fit)
  return out.join("")
}

function transform(node, visit) {
  var kept = []
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") {
      kept.push(child)
      continue
    }
    var verdict = visit(child)
    if (verdict === null) continue
    transform(child, visit)
    if (verdict === "unwrap") {
      for (var grandchildIndex = 0; grandchildIndex < child.children.length; grandchildIndex++) kept.push(child.children[grandchildIndex])
      continue
    }
    kept.push(child)
  }
  node.children = kept
  return node
}

function attributeOf(node, name) {
  for (var attributeIndex = 0; attributeIndex < node.attrs.length; attributeIndex++) {
    if (node.attrs[attributeIndex].name === name) return node.attrs[attributeIndex]
  }
  return null
}

function attributeValue(node, name) {
  var attribute = attributeOf(node, name)
  return attribute && attribute.value !== null && attribute.value !== undefined ? String(attribute.value) : ""
}

function removeAttribute(node, name) {
  var kept = []
  for (var attributeIndex = 0; attributeIndex < node.attrs.length; attributeIndex++) {
    if (node.attrs[attributeIndex].name !== name) kept.push(node.attrs[attributeIndex])
  }
  node.attrs = kept
}

function setAttribute(node, name, value) {
  var attribute = attributeOf(node, name)
  if (attribute) attribute.value = String(value)
  else node.attrs.push({ name: name, value: String(value) })
}

function setStyle(node, declarations) {
  var attribute = attributeOf(node, "style")
  var style = joinDeclarations(declarations)
  if (style === "") {
    if (attribute) removeAttribute(node, "style")
    return
  }
  if (attribute) attribute.value = style
  else node.attrs.push({ name: "style", value: style })
}

// Invariant: Qt resolves entity references and URL whitespace before resource loading. Validate the
// same decoded spelling.
var NAMED_REFERENCES = {
  amp: "&", quot: "\"", apos: "'", lt: "<", gt: ">", sol: "/", colon: ":",
  nbsp: " ", ensp: " ", emsp: " ", thinsp: " ",
  mdash: "\u2014", ndash: "\u2013", hellip: "\u2026", bull: "\u2022",
  lsquo: "\u2018", rsquo: "\u2019", ldquo: "\u201c", rdquo: "\u201d",
  middot: "\u00b7", copy: "\u00a9", reg: "\u00ae", trade: "\u2122",
  deg: "\u00b0", times: "\u00d7", laquo: "\u00ab", raquo: "\u00bb",
  euro: "\u20ac", pound: "\u00a3", yen: "\u00a5", cent: "\u00a2", sect: "\u00a7"
}

function decodeReferences(text) {
  return String(text).replace(/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);?/g,
    function(match, body) {
      if (body.charAt(0) !== "#") {
        var named = NAMED_REFERENCES[body.toLowerCase()]
        return typeof named === "string" ? named : match
      }
      var code = body.charAt(1) === "x" || body.charAt(1) === "X"
        ? parseInt(body.substring(2), 16)
        : parseInt(body.substring(1), 10)
      if (!isFinite(code) || code < 0 || code > 0x10ffff) return match
      if (code <= 0xffff) return String.fromCharCode(code)
      var supplementary = code - 0x10000
      return String.fromCharCode(0xd800 + (supplementary >> 10), 0xdc00 + (supplementary & 1023))
    })
}

// Invariant: decode schemes twice to reject entity-hidden dangerous schemes conservatively.
function normalizedUrl(value) {
  var text = String(value === undefined || value === null ? "" : value)
  text = decodeReferences(decodeReferences(text))
  return text.replace(/[\t\n\r]/g, "").replace(/^[\s\u0000-\u001f]+|[\s\u0000-\u001f]+$/g, "")
}

// Invariant: decoding can introduce @ and change URL authority. Both the once-decoded and
// twice-decoded hosts must be public.
function hostsOf(value) {
  var text = String(value === undefined || value === null ? "" : value)
  var once = decodeReferences(text)
  var twice = decodeReferences(once)
  return once === twice ? [hostOf(normalizedUrl(text))]
    : [hostOf(normalizedUrl(text)), hostOf(once.replace(/[\t\n\r]/g, ""))]
}

function isPublicUrl(value) {
  var hosts = hostsOf(value)
  for (var hostIndex = 0; hostIndex < hosts.length; hostIndex++) {
    if (!isPublicHost(hosts[hostIndex])) return false
  }
  return true
}

// Invariant: this spelling check protects deliberate browser links, not automatic fetches;
// public_http pins checked DNS destinations.
function externallyOpenableHttpUrl(value) {
  var text = String(value || "").trim()
  if (!/^https?:\/\//i.test(text)) return ""
  return isPublicUrl(text) ? text : ""
}

function hostOf(url) {
  var text = String(url || "").replace(/^https?:/i, "")
  if (text.indexOf("//") !== 0) return ""
  var authority = text.substring(2)
  var end = authority.search(/[\/?#]/)
  if (end >= 0) authority = authority.substring(0, end)
  var at = authority.lastIndexOf("@")
  if (at >= 0) authority = authority.substring(at + 1)
  if (authority.charAt(0) === "[") {
    var close = authority.indexOf("]")
    return (close < 0 ? authority : authority.substring(0, close + 1)).toLowerCase()
  }
  var colon = authority.indexOf(":")
  return (colon < 0 ? authority : authority.substring(0, colon)).toLowerCase()
}

var DOTTED_QUAD = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/

function isPublicIpv4(host) {
  var parts = String(host).match(DOTTED_QUAD)
  if (!parts) return false
  var octets = []
  for (var octetIndex = 1; octetIndex <= 4; octetIndex++) {
    // Invariant: leading-zero IPv4 components have conflicting decimal/octal interpretations across
    // resolvers.
    if (parts[octetIndex].length > 1 && parts[octetIndex].charAt(0) === "0") return false
    var value = Number(parts[octetIndex])
    if (value > 255) return false
    octets.push(value)
  }
  var firstOctet = octets[0]
  var secondOctet = octets[1]
  if (firstOctet === 0 || firstOctet === 10 || firstOctet === 127) return false
  if (firstOctet === 169 && secondOctet === 254) return false
  if (firstOctet === 172 && secondOctet >= 16 && secondOctet <= 31) return false
  if (firstOctet === 192 && (secondOctet === 168 || secondOctet === 0)) return false
  if (firstOctet === 198 && (secondOctet === 18 || secondOctet === 19)) return false
  if (firstOctet === 100 && secondOctet >= 64 && secondOctet <= 127) return false
  if (firstOctet >= 224) return false
  return true
}

// Invariant: reserved .example and .invalid names are not private-network destinations.
var PRIVATE_SUFFIX = /(^|\.)(localhost|home\.arpa)$|\.(local|localdomain|internal|intranet|lan|home|corp|test)$/
var PUBLIC_TLD = /\.(xn--[a-z0-9-]+|[a-z]{2,})$/

// Invariant: this hostname gate does not prevent DNS rebinding. Automatic requests also require
// public_http address validation and pinning.
function isPublicHost(host) {
  var name = String(host || "")
  if (name === "" || name.length > 253) return false
  if (isPublicIpv4(name)) return true
  if (!/^[a-z0-9.-]+$/.test(name)) return false
  if (name.indexOf("..") >= 0) return false
  if (PRIVATE_SUFFIX.test(name)) return false
  return PUBLIC_TLD.test(name)
}

function isRemoteSource(value) {
  return /^(https?:)?\/\//i.test(normalizedUrl(value))
}

// Invariant: data URLs must contain recognized raster signatures. SVG can reference resources and
// must never reach Qt through this image gate.
var BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function base64Prefix(payload, byteLimit) {
  var text = String(payload || "")
  if (text === "" || text.length % 4 !== 0
      || !/^[A-Za-z0-9+/]*={0,2}$/.test(text)) return []
  var padding = text.slice(-2) === "==" ? 2 : (text.slice(-1) === "=" ? 1 : 0)
  if (padding === 2 && BASE64_ALPHABET.indexOf(text.charAt(text.length - 3)) % 16 !== 0)
    return []
  if (padding === 1 && BASE64_ALPHABET.indexOf(text.charAt(text.length - 2)) % 4 !== 0)
    return []
  var out = []
  for (var offset = 0; offset < text.length && out.length < byteLimit; offset += 4) {
    var firstDigit = BASE64_ALPHABET.indexOf(text.charAt(offset))
    var secondDigit = BASE64_ALPHABET.indexOf(text.charAt(offset + 1))
    var thirdDigit = text.charAt(offset + 2) === "=" ? 0 : BASE64_ALPHABET.indexOf(text.charAt(offset + 2))
    var fourthDigit = text.charAt(offset + 3) === "=" ? 0 : BASE64_ALPHABET.indexOf(text.charAt(offset + 3))
    if (firstDigit < 0 || secondDigit < 0 || thirdDigit < 0 || fourthDigit < 0) return []
    out.push((firstDigit << 2) | (secondDigit >> 4))
    if (text.charAt(offset + 2) !== "=" && out.length < byteLimit)
      out.push(((secondDigit & 15) << 4) | (thirdDigit >> 2))
    if (text.charAt(offset + 3) !== "=" && out.length < byteLimit)
      out.push(((thirdDigit & 3) << 6) | fourthDigit)
  }
  return out
}

function bytesStartWith(bytes, expected) {
  if (bytes.length < expected.length) return false
  for (var byteIndex = 0; byteIndex < expected.length; byteIndex++) {
    if (bytes[byteIndex] !== expected[byteIndex]) return false
  }
  return true
}

function isRasterDataImage(value) {
  var match = String(value || "").match(
    /^data:image\/(png|jpe?g|gif|webp|bmp);base64,([A-Za-z0-9+/]*={0,2})$/i)
  if (!match) return false
  var bytes = base64Prefix(match[2], 12)
  var kind = match[1].toLowerCase()
  if (kind === "png")
    return bytesStartWith(bytes, [137, 80, 78, 71, 13, 10, 26, 10])
  if (kind === "jpg" || kind === "jpeg")
    return bytesStartWith(bytes, [255, 216, 255])
  if (kind === "gif")
    return bytesStartWith(bytes, [71, 73, 70, 56, 55, 97])
      || bytesStartWith(bytes, [71, 73, 70, 56, 57, 97])
  if (kind === "webp")
    return bytesStartWith(bytes, [82, 73, 70, 70])
      && bytes.length >= 12
      && bytes[8] === 87 && bytes[9] === 69 && bytes[10] === 66 && bytes[11] === 80
  return kind === "bmp" && bytesStartWith(bytes, [66, 77])
}

function imageSourceKind(value) {
  var url = normalizedUrl(value)
  if (url === "") return "none"
  if (/^cid:/i.test(url)) return "inline"
  if (/^data:/i.test(url)) return isRasterDataImage(url) ? "inline" : "unsafe"
  if (/^(https?:)?\/\//i.test(url)) return isPublicUrl(value) ? "remote" : "unsafe"
  return /^[a-z][a-z0-9+.-]*:/i.test(url) ? "unsafe" : "local"
}

// Invariant: direct Qt Image sources must be prepared raster bytes, never original remote URLs.
function isDisplayableImageUrl(value) {
  return isRasterDataImage(value)
}

// Invariant: links reach the external opener even when Qt itself ignores their scheme.
function safeHref(value) {
  return /^\s*(https?:|mailto:)/i.test(String(value || ""))
}

// Invariant: decode references before splitting CSS declarations; an encoded semicolon or url token
// must not reconstruct a resource after filtering.
function stripCssComments(text) {
  var input = String(text || "")
  var out = ""
  var position = 0
  while (position < input.length) {
    if (input.charAt(position) === "/" && input.charAt(position + 1) === "*") {
      var end = input.indexOf("*/", position + 2)
      if (end < 0) break
      position = end + 2
      continue
    }
    out += input.charAt(position)
    position++
  }
  return out
}

function cssUnescape(text) {
  var input = String(text || "")
  var out = ""
  for (var position = 0; position < input.length; position++) {
    if (input.charAt(position) !== "\\") {
      out += input.charAt(position)
      continue
    }
    if (position + 1 >= input.length) break
    var hex = ""
    var escapeEnd = position + 1
    while (escapeEnd < input.length && hex.length < 6 && /[0-9a-fA-F]/.test(input.charAt(escapeEnd))) {
      hex += input.charAt(escapeEnd)
      escapeEnd++
    }
    if (hex !== "") {
      out += String.fromCharCode(parseInt(hex, 16))
      if (/[\t\n\r\f ]/.test(input.charAt(escapeEnd))) escapeEnd++
      position = escapeEnd - 1
      continue
    }
    out += input.charAt(position + 1)
    position++
  }
  return out
}

function resolvedStyle(style) {
  var current = String(style === undefined || style === null ? "" : style)
  var previous = ""
  var iteration = 0
  while (current !== previous && iteration < 8) {
    previous = current
    current = cssUnescape(stripCssComments(current))
    iteration++
  }
  return current
}

function splitDeclarations(style) {
  var text = String(style === undefined || style === null ? "" : style)
  if (text.indexOf("&") >= 0) text = decodeReferences(decodeReferences(text))
  text = resolvedStyle(text)
  var out = []
  var current = ""
  var quote = ""
  var depth = 0
  for (var characterIndex = 0; characterIndex < text.length; characterIndex++) {
    var character = text.charAt(characterIndex)
    if (quote !== "") {
      current += character
      if (character === quote) quote = ""
      continue
    }
    if (character === "\"" || character === "'") {
      quote = character
      current += character
      continue
    }
    if (character === "(") depth++
    else if (character === ")") depth = Math.max(0, depth - 1)
    else if (character === ";" && depth === 0) {
      out.push(current)
      current = ""
      continue
    }
    current += character
  }
  out.push(current)

  var declarations = []
  for (var declarationIndex = 0; declarationIndex < out.length; declarationIndex++) {
    var piece = out[declarationIndex]
    if (piece.replace(/\s+/g, "") === "") continue
    var colon = piece.indexOf(":")
    if (colon < 0) continue
    declarations.push({
      name: piece.substring(0, colon).replace(/^\s+|\s+$/g, "").toLowerCase(),
      value: piece.substring(colon + 1).replace(/^\s+|\s+$/g, "")
    })
  }
  return declarations
}

// Performance: cache the original style parse across discovery, reading and cleaning. Later fitting
// reads the cleaned attributes independently.
function sourceDeclarations(node) {
  if (node._sourceDeclarationsRead === true) return node._sourceDeclarations
  var style = attributeOf(node, "style")
  node._sourceDeclarationsRead = true
  node._sourceDeclarations = style !== null && style.value !== null
    && style.value !== undefined ? splitDeclarations(style.value) : null
  return node._sourceDeclarations
}

function joinDeclarations(declarations) {
  var parts = []
  for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
    if (declarations[declarationIndex].value === "") continue
    parts.push(declarations[declarationIndex].name + ":" + declarations[declarationIndex].value)
  }
  return parts.join(";")
}

function rewriteStyle(node, decide) {
  var attribute = attributeOf(node, "style")
  if (!attribute || attribute.value === null || attribute.value === undefined) return
  var declarations = splitDeclarations(attribute.value)
  var kept = []
  for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
    var verdict = decide(declarations[declarationIndex])
    if (verdict) kept.push(verdict)
  }
  setStyle(node, kept)
}

// Invariant: Qt can render stylesheet and script contents as body text.
var DROPPED_ELEMENTS = {
  script: true, style: true, iframe: true, object: true, embed: true,
  applet: true, noscript: true, meta: true, link: true, base: true,
  // Invariant: title and textarea raw text are not message body content.
  title: true, textarea: true
}

// Invariant: remove sender foreground and background together so theme substitution cannot make
// text unreadable.
var COLOUR_ATTRIBUTES = { bgcolor: true, bordercolor: true, color: true }
var COLOUR_DECLARATIONS = {
  color: true, background: true, "background-color": true,
  "border-color": true, "outline-color": true
}

// Invariant: HTML background is a resource URL, not a color. Appearance preferences must never
// enable a resource request.
var RESOURCE_ATTRIBUTES = {
  background: true, srcset: true, lowsrc: true, dynsrc: true, poster: true,
  data: true, codebase: true, usemap: true, ping: true, formaction: true,
  longdesc: true, profile: true, manifest: true, archive: true, cite: true
}

function stripColorsFrom(node) {
  for (var name in COLOUR_ATTRIBUTES) removeAttribute(node, name)
  for (var resource in RESOURCE_ATTRIBUTES) removeAttribute(node, resource)
  rewriteStyle(node, function(declaration) {
    return COLOUR_DECLARATIONS[declaration.name] === true ? null : declaration
  })
}

// Invariant: CSS resource URLs are forbidden regardless of which declarations Qt currently
// supports.
function stripStyleUrlsFrom(node) {
  rewriteStyle(node, function(declaration) {
    return /url/i.test(declaration.value) || declaration.value.indexOf("\\") >= 0
      ? null : declaration
  })
}

// Invariant: Qt ignores display:none; hidden content must be removed before rendering.
function isHiddenBy(declarations) {
  for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
    var declaration = declarations[declarationIndex]
    if (declaration.name === "display" && /^none\b/i.test(declaration.value)) return true
    if (declaration.name === "visibility" && /^hidden\b/i.test(declaration.value)) return true
  }
  return false
}

function isHidden(node) {
  if (VOID_ELEMENTS[node.name] === true) return false
  var style = attributeValue(node, "style")
  if (style === "") return false
  return isHiddenBy(splitDeclarations(style))
}

// Invariant: tracking-sized images must neither render nor become fetch candidates.
function isTrackingPixel(node) {
  var width = Number(attributeValue(node, "width"))
  var height = Number(attributeValue(node, "height"))
  if (isFinite(width) && attributeValue(node, "width") !== "" && width <= 2) return true
  if (isFinite(height) && attributeValue(node, "height") !== "" && height <= 2) return true
  var declarations = sourceDeclarations(node) || []
  for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
    if (declarations[declarationIndex].name !== "width" && declarations[declarationIndex].name !== "height") continue
    if (/^[012](\.\d+)?px/i.test(declarations[declarationIndex].value)) return true
  }
  return false
}

// Performance: flatten excess layout grids before Qt synchronously resolves competing column
// widths.
var KEEP_TABLE_DEPTH = 2
var TABLE_PARTS = {
  table: true, thead: true, tbody: true, tfoot: true, tr: true, td: true, th: true
}

// Invariant: table depth alone cannot distinguish layout wrappers from data. Keep grids with
// multiple multi-cell rows.
function rowsOf(node, out) {
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") continue
    // Invariant: a nested table owns its own rows.
    if (child.name === "table") continue
    if (child.name === "tr") out.push(child)
    rowsOf(child, out)
  }
  return out
}

function isGrid(node) {
  var rows = rowsOf(node, [])
  var lines = 0
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    var cells = 0
    for (var childIndex = 0; childIndex < rows[rowIndex].children.length; childIndex++) {
      var cell = rows[rowIndex].children[childIndex]
      if (cell.type === "text") continue
      if (cell.name === "td" || cell.name === "th") cells++
    }
    if (cells >= 2 && ++lines >= 2) return true
  }
  return false
}

function asBlock(node) {
  var style = attributeValue(node, "style")
  node.name = "div"
  node.attrs = style === "" ? [] : [{ name: "style", value: style }]
}

function flattenPartsOf(node) {
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text" || child.name === "table") continue
    flattenPartsOf(child)
    if (TABLE_PARTS[child.name] === true) asBlock(child)
  }
}

// Invariant: the depth budget counts retained grids, not wrappers already flattened.
function flattenTablesIn(node, limit, depth) {
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") continue
    if (child.name !== "table") {
      flattenTablesIn(child, limit, depth)
      continue
    }
    var keep = depth < limit && isGrid(child)
    flattenTablesIn(child, limit, keep ? depth + 1 : depth)
    if (keep) continue
    flattenPartsOf(child)
    asBlock(child)
  }
}

// Invariant: Qt rich-text layout runs synchronously in the desktop process. Refuse excessive markup
// complexity before layout.
var MAX_RICH_TEXT = 120000
var MAX_ELEMENTS = 2500
var MAX_IMAGES = 24

var MAX_TABLES = 60
var MAX_TABLE_DEPTH = 4

// Performance: filter one element’s attributes in one pass instead of rebuilding the list for each
// rule.
var HANDLER_ATTRIBUTE = /^on[a-z]+$/

// Invariant: preserve cell alignment because it conveys column structure; other centered wrappers
// become panel-aligned content.
var CENTRED = /^center\b/i
var ALIGNED_BY_COLUMN = { td: true, th: true }

function cleanAttributes(node, keepColors, declarations) {
  var uncentre = ALIGNED_BY_COLUMN[node.name] !== true
  var attributes = node.attrs
  var kept = attributes
  var dropped = false

  for (var attributeIndex = 0; attributeIndex < attributes.length; attributeIndex++) {
    var attribute = attributes[attributeIndex]
    var name = attribute.name
    var drop = false
    // Invariant: resource refusal precedes appearance options.
    if (!/^[a-z_:][a-z0-9_.:-]*$/i.test(name)) drop = true
    else if (/:href$/.test(name) || (name === "href" && node.name !== "a")) drop = true
    else if (RESOURCE_ATTRIBUTES[name] === true) drop = true
    // Invariant: only img owns a checked src; other elements cannot inherit that permission.
    else if (name === "src" && node.name !== "img") drop = true
    else if (!keepColors && COLOUR_ATTRIBUTES[name] === true) drop = true

    else if (name.charCodeAt(0) === 111 && HANDLER_ATTRIBUTE.test(name)) drop = true
    else if (name === "href" && !safeHref(attribute.value)) drop = true
    else if (uncentre && name === "align" && CENTRED.test(String(attribute.value))) drop = true

    if (drop && !dropped) {
      dropped = true
      kept = attributes.slice(0, attributeIndex)
    } else if (!drop && dropped) {
      kept.push(attribute)
    }
  }
  if (dropped) node.attrs = kept
  collapseAttributes(node)
  if (declarations === null) return

  var survivors = []
  for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
    var declaration = declarations[declarationIndex]
    if (!keepColors && COLOUR_DECLARATIONS[declaration.name] === true) continue
    if (uncentre && declaration.name === "text-align" && CENTRED.test(declaration.value)) continue
    // Invariant: declarations are already entity-decoded before resource checks.
    if (/url/i.test(declaration.value) || declaration.value.indexOf("\\") >= 0) continue
    survivors.push(declaration)
  }
  setStyle(node, survivors)
}

function collapseAttributes(node) {
  var seen = {}
  var kept = []
  var attributes = node.attrs
  for (var attributeIndex = 0; attributeIndex < attributes.length; attributeIndex++) {
    var name = attributes[attributeIndex].name
    if (seen[name] === true) continue
    seen[name] = true
    kept.push(attributes[attributeIndex])
  }
  node.attrs = kept
}

// Invariant: Qt reads image dimensions from HTML attributes, not CSS width/height; promote absolute
// pixel dimensions.
function promoteImageDimensions(node, declarations) {
  if (node.name !== "img" || declarations === null) return
  for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
    var declaration = declarations[declarationIndex]
    if (declaration.name !== "width" && declaration.name !== "height") continue
    if (attributeOf(node, declaration.name) !== null) continue
    var pixels = String(declaration.value).match(/^(\d+(?:\.\d+)?)px$/i)
    if (!pixels) continue
    setAttribute(node, declaration.name, pixels[1])
  }
}

// Invariant: Qt honors dir but ignores CSS direction. Preserve explicit sender dir while promoting
// valid CSS defaults.
var DIRECTION_VALUES = { ltr: true, rtl: true }

function promoteDirection(node, declarations) {
  if (declarations === null) return

  if (attributeOf(node, "dir") !== null) return
  for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
    if (declarations[declarationIndex].name !== "direction") continue
    var value = String(declarations[declarationIndex].value).trim().toLowerCase()
    if (DIRECTION_VALUES[value] !== true) continue
    setAttribute(node, "dir", value)
    return
  }
}

function hasDirectImage(node) {
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    if (node.children[childIndex].type !== "text" && node.children[childIndex].name === "img") return true
  }
  return false
}

// Invariant: Qt collapses zero-height image rows and paints following text over them; remove that
// browser-specific spacing rule.
function keepImageRowOpen(node) {
  if (!hasDirectImage(node)) return
  rewriteStyle(node, function(declaration) {
    if ((declaration.name === "line-height" || declaration.name === "font-size")
      && /^0(?:\.0+)?(?:px|pt|%|em|rem)?$/i.test(declaration.value)) return null
    return declaration
  })
}

// Performance: remove only semantically empty wrappers before Qt parses and lays out the document
// again.
var TRANSPARENT_INLINE = { span: true, font: true, small: true, big: true }

var PLAIN_CONTAINER = {
  div: true, section: true, article: true, aside: true,
  header: true, footer: true, main: true, nav: true
}

function soleBlockChild(node) {
  var found = null
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") {
      if (child.text.replace(/[\s\u00a0]+/g, "") !== "") return null
      continue
    }
    if (found !== null) return null
    if (BLOCK_ELEMENTS[child.name] !== true) return null
    found = child
  }
  return found
}

// Invariant: collapse wrappers bottom-up so one pass removes the complete redundant chain.
function collapse(node) {
  var kept = []
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") {
      kept.push(child)
      continue
    }
    collapse(child)
    if (child.attrs.length === 0) {
      if (TRANSPARENT_INLINE[child.name] === true) {
        for (var grandchildIndex = 0; grandchildIndex < child.children.length; grandchildIndex++) kept.push(child.children[grandchildIndex])
        continue
      }
      if (PLAIN_CONTAINER[child.name] === true) {
        var inner = soleBlockChild(child)
        if (inner !== null) {
          kept.push(inner)
          continue
        }
      }
    }
    kept.push(child)
  }
  node.children = kept
}

var MAX_EMBEDDED_DATA_BYTES = 16 * 1024 * 1024
var MAX_ALLOWED_IMAGES = 256

function imagePolicy(options) {
  var settings = options || {}
  var requested = settings.maxImages === undefined ? MAX_IMAGES : Number(settings.maxImages)
  return {
    allowImages: settings.allowRemoteImages === true,
    imageData: settings.remoteImageData && typeof settings.remoteImageData === "object"
      ? settings.remoteImageData : null,
    limit: Math.max(0, Math.min(MAX_ALLOWED_IMAGES, Math.floor(isNaN(requested) ? 0 : requested))),
    admitted: 0,
    embeddedBytes: 0,
    embeddedLayoutLength: 0,
    kept: 0,
    blocked: 0
  }
}

function preparedImage(policy, source) {
  if (policy.imageData === null || !Object.prototype.hasOwnProperty.call(policy.imageData, source)) return ""
  var value = String(policy.imageData[source] || "")
  return isRasterDataImage(value) ? value : ""
}

function admitImage(policy, source) {
  var embedded = /^data:/i.test(source) || /^data:/i.test(normalizedUrl(source))
  var bytes = embedded ? source.length : 0
  if (policy.admitted >= policy.limit || bytes > MAX_EMBEDDED_DATA_BYTES - policy.embeddedBytes) {
    policy.blocked++
    return false
  }
  policy.admitted++
  policy.embeddedBytes += bytes
  policy.embeddedLayoutLength += bytes
  return true
}

function tooHeavyWithoutImageData(size, policy) {
  return isTooHeavy({ length: Math.max(0, size.length - policy.embeddedLayoutLength),
    tags: size.tags, tables: size.tables, tableDepth: size.tableDepth })
}

function sanitize(html, options) {
  var settings = options || {}
  var source = String(html === undefined || html === null ? "" : html)
  var keepColors = settings.keepColors === true
  var images = imagePolicy(settings)
  var limit = images.limit

  // Invariant: remote image approval permits fetching through the checked backend; only
  // successfully prepared bytes may enter the document.
  var loadable = 0
  var remoteSources = []
  var seenRemoteSources = {}

  function keepImage(node) {
    var source = attributeValue(node, "src")
    if (attributeOf(node, "src") === null) return true
    var kind = imageSourceKind(source)
    if (kind === "none") return true
    if (kind !== "inline" && kind !== "remote") return false
    if (isTrackingPixel(node)) {
      images.blocked++
      return false
    }
    if (kind === "inline") return admitImage(images, source)
    if (loadable < limit) loadable++
    var prepared = images.allowImages ? preparedImage(images, source) : ""
    if (prepared === "") {
      images.blocked++
      return false
    }
    if (!admitImage(images, prepared)) return false
    attributeOf(node, "src").value = prepared
    images.kept++
    return true
  }

  function clean(node) {
    var survivors = []
    for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
      var child = node.children[childIndex]
      if (child.type === "text") {
        survivors.push(child)
        continue
      }
      if (DROPPED_ELEMENTS[child.name] === true) continue

      if (child.name === "center") child.name = "div"

      // Performance: hidden-state and attribute filtering reuse the original style declaration
      // parse.
      var declarations = sourceDeclarations(child)
      if (child.name === "img" && attributeOf(child, "hidden") !== null) continue
      if (declarations !== null && (VOID_ELEMENTS[child.name] !== true || child.name === "img")
        && isHiddenBy(declarations)) continue

      // Performance: collect candidates during cleaning before attributes change, avoiding another
      // complete tree traversal.
      if (child.name === "img" && remoteSources.length < limit) {
        var remoteSource = attributeValue(child, "src")
        if (imageSourceKind(remoteSource) === "remote" && !isTrackingPixel(child)
          && seenRemoteSources[remoteSource] !== true) {
          seenRemoteSources[remoteSource] = true
          remoteSources.push(remoteSource)
        }
      }

      promoteImageDimensions(child, declarations)
      promoteDirection(child, declarations)
      cleanAttributes(child, keepColors, declarations)

      if (child.name === "img" && !keepImage(child)) continue

      clean(child)
      keepImageRowOpen(child)
      survivors.push(child)
    }
    node.children = survivors
  }

  var root = parse(source)

  // Invariant: plain-text markers are numbered from the sender tree before image filtering, keeping
  // marker indices aligned with their source list.
  var plain = settings.withPlainText === true ? readTree(root) : null

  // Invariant: build reading mode from the original tree before formatted cleaning removes
  // typography and table structure.
  var reader = settings.withReader === true
    ? readerTree(root, settings)
    : null

  clean(root)
  if (settings.keepTables !== true) {
    flattenTablesIn(root, settings.keepTableDepth === undefined
      ? KEEP_TABLE_DEPTH : Math.max(0, settings.keepTableDepth), 0)
  }

  collapse(root)

  // Performance: measure the existing tree rather than reparsing its serialized output.
  var text = serialize(root)
  var size = { length: text.length, tags: 0, images: 0, tables: 0, tableDepth: 0 }
  size.tableDepth = measure(root, 0, size)

  return {
    html: text,
    blockedImages: images.blocked,
    images: images.kept,
    remoteImages: loadable,
    remoteImageSources: remoteSources,
    complexity: size,
    tooHeavy: tooHeavyWithoutImageData(size, images),
    plainText: plain,

    reader: reader,
    // Invariant: callers may reuse this tree for fitting because fitting does not mutate it.
    document: root
  }
}

function hasRemoteImages(html) {
  return sanitize(html).blockedImages > 0
}

function stripColors(html) {
  var root = parse(html)
  transform(root, function(node) {
    stripColorsFrom(node)
    return node
  })
  return serialize(root)
}

function dropHidden(html) {
  var root = parse(html)
  transform(root, function(node) {
    return isHidden(node) ? null : node
  })
  return serialize(root)
}

function flattenTables(html, keepDepth) {
  var root = parse(html)
  flattenTablesIn(root, keepDepth === undefined ? KEEP_TABLE_DEPTH : Math.max(0, keepDepth), 0)
  return serialize(root)
}

function stripElement(html, name) {
  var wanted = String(name || "").toLowerCase()
  var root = parse(html)
  transform(root, function(node) {
    return node.name === wanted ? null : node
  })
  return serialize(root)
}

function measure(node, depth, size) {
  var deepest = depth
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") continue
    size.tags++
    if (child.name === "img") size.images++
    var childDepth = depth
    if (child.name === "table") {
      size.tables++
      childDepth = depth + 1
    }
    var reached = measure(child, childDepth, size)
    if (reached > deepest) deepest = reached
  }
  return deepest
}

function complexity(html) {
  var text = String(html === undefined || html === null ? "" : html)
  var size = { length: text.length, tags: 0, images: 0, tables: 0, tableDepth: 0 }
  size.tableDepth = measure(parse(text), 0, size)
  return size
}

function tableDepth(html) {
  return complexity(html).tableDepth
}

function isTooHeavy(size) {
  return size.length > MAX_RICH_TEXT
    || size.tags > MAX_ELEMENTS
    || size.tables > MAX_TABLES
    || size.tableDepth > MAX_TABLE_DEPTH
}

function tooHeavyForRichText(html) {
  return isTooHeavy(complexity(html))
}

// Invariant: Qt max-width needs pixels; explicit heights can survive width clamping and distort an
// image.
var MIN_IMAGE_WIDTH = 40

function fitting(options, available) {
  return {
    heights: options.heights === true,
    clampedHeightsOnly: options.clampedHeightsOnly === true,
    sides: options.sides === true,
    widths: options.widths === true,
    limit: Math.max(MIN_IMAGE_WIDTH, Math.floor(Number(available) || 0))
  }
}

var SIDE_SPACING = {
  "padding-left": true, "padding-right": true,
  "margin-left": true, "margin-right": true
}

function withoutSides(value) {
  var parts = String(value).replace(/^\s+|\s+$/g, "").split(/\s+/)
  if (parts.length >= 4) return parts[0] + " 0 " + parts[2] + " 0"
  if (parts.length === 3) return parts[0] + " 0 " + parts[2]
  return parts[0] + " 0"
}

var SIZED_ELEMENTS = { table: true, td: true, th: true, tr: true, div: true }

function intrinsicContentWidth(node, value) {
  var percent = String(value || "").replace(/^\s+|\s+$/g, "").match(/^(\d+(?:\.\d+)?)%$/)
  if (!percent || Number(percent[1]) > 5) return false
  if (node.name === "table") return true
  if (node.name !== "td" && node.name !== "th") return false
  return String(attributeValue(node, "style")).toLowerCase().indexOf("nowrap") >= 0
}

function fitDeclaration(declaration, node, fit, dropImageHeight) {
  var name = declaration.name
  if (dropImageHeight && name === "height") return null
  if (fit.sides) {
    if (SIDE_SPACING[name] === true) return null
    if (name === "padding" || name === "margin")
      return { name: name, value: withoutSides(declaration.value) }
  }
  if (fit.widths) {
    if (name === "width" && intrinsicContentWidth(node, declaration.value)) return null
    if (name === "width" && SIZED_ELEMENTS[node.name] === true) {
      var pixels = declaration.value.match(/^(\d+)px$/i)
      if (pixels && Number(pixels[1]) > fit.limit) return null
    }

    if (name === "white-space" && /^nowrap\b/i.test(declaration.value)) return null
  }
  return declaration
}

// Performance: inspect a short style substring before parsing declarations during repeated width
// fitting.
var FITTABLE_DECLARATION = /width|nowrap/i

// Invariant: fitted attributes must leave the reusable source node unchanged.
function fitStyleAttribute(node, attribute, fit, dropImageHeight) {
  var declarations = splitDeclarations(attribute.value)
  var kept = []
  var changed = false
  for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
    var fitted = fitDeclaration(declarations[declarationIndex], node, fit, dropImageHeight)
    if (fitted !== declarations[declarationIndex]) changed = true
    if (fitted) kept.push(fitted)
  }
  if (!changed) return attribute
  var style = joinDeclarations(kept)
  return style === "" ? null : { name: "style", value: style }
}

function fitAttributes(node, fit) {
  var attributes = node.attrs
  if (attributes.length === 0) return attributes
  var isImage = fit.heights && node.name === "img"
  var isSized = fit.widths && SIZED_ELEMENTS[node.name] === true
  var imageWidth = Number(attributeValue(node, "width"))
  var dropImageHeight = isImage && (!fit.clampedHeightsOnly
    || (isFinite(imageWidth) && imageWidth > fit.limit))
  if (!isImage && !isSized && !fit.sides) {
    if (!fit.widths) return attributes
    // Invariant: any element can carry nowrap, so the fast path must still inspect that
    // declaration.
    var carried = attributeOf(node, "style")
    if (carried === null || String(carried.value).indexOf("nowrap") < 0) return attributes
  }

  var out = null
  for (var attributeIndex = 0; attributeIndex < attributes.length; attributeIndex++) {
    var attribute = attributes[attributeIndex]
    var replacement = attribute

    // Invariant: remove explicit image height when Qt narrows its width; otherwise the original
    // height distorts the aspect ratio.
    if (dropImageHeight && attribute.name === "height") replacement = null
    else if (isSized && attribute.name === "width"
      && intrinsicContentWidth(node, attribute.value)) replacement = null
    else if (isSized && attribute.name === "width" && /^\d+$/.test(String(attribute.value))
      && Number(attribute.value) > fit.limit) replacement = null
    else if (attribute.name === "style" && attribute.value !== null && attribute.value !== undefined
      && (fit.sides || FITTABLE_DECLARATION.test(String(attribute.value))
        || dropImageHeight)) {
      replacement = fitStyleAttribute(node, attribute, fit, dropImageHeight)
    }

    if (replacement === attribute) {
      if (out !== null) out.push(attribute)
      continue
    }
    if (out === null) out = attributes.slice(0, attributeIndex)
    if (replacement !== null) out.push(replacement)
  }
  return out === null ? attributes : out
}

// Performance: accept the sanitized tree directly to avoid reparsing on every width or zoom change.
function documentTree(source) {
  if (source && source.type === "root") return source
  return parse(source)
}

var CONTENT_WIDTH_ELEMENTS = {
  body: true, div: true, table: true, section: true, article: true,
  header: true, footer: true, main: true
}

function fixedPixelWidth(value) {
  var match = String(value === undefined || value === null ? "" : value)
    .replace(/^\s+|\s+$/g, "").match(/^(\d+(?:\.\d+)?)(?:px)?$/i)
  return match ? Number(match[1]) : 0
}

function widestDeclaredContent(node, current) {
  var widest = current
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") continue
    if (CONTENT_WIDTH_ELEMENTS[child.name] === true) {
      var width = fixedPixelWidth(attributeValue(child, "width"))
      var declarations = splitDeclarations(attributeValue(child, "style"))
      for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
        if (declarations[declarationIndex].name !== "max-width"
          && declarations[declarationIndex].name !== "width") continue
        width = Math.max(width, fixedPixelWidth(declarations[declarationIndex].value))
      }
      // Invariant: small fixed boxes are icons or badges, not the message’s preferred content
      // width.
      if (width >= 240) widest = Math.max(widest, width)
    }
    widest = widestDeclaredContent(child, widest)
  }
  return widest
}

function preferredContentWidth(source, available) {
  var limit = Math.max(80, Math.floor(Number(available) || 0))
  var declared = widestDeclaredContent(documentTree(source), 0)
  return declared > 0 ? Math.min(limit, Math.floor(declared)) : limit
}

function stripImageHeights(html) {
  return serialize(parse(html), fitting({ heights: true }, 0))
}

function compactHorizontal(html) {
  return serialize(parse(html), fitting({ sides: true }, 0))
}

function relaxFixedWidths(html, available) {
  return serialize(parse(html), fitting({ widths: true }, available))
}

// Invariant: base dir and physical stylesheet sides must agree; changing margins alone can make Qt
// list markers disappear.
function baseDirectionAttribute(palette) {
  return Direction.attributeFor(String(palette.direction || ""))
}

function documentFor(bodyHtml, colors) {
  var palette = colors || {}
  var foreground = String(palette.foreground || "")
  var background = String(palette.background || "")
  var link = String(palette.link || foreground)
  var quote = String(palette.quote || foreground)
  // Invariant: Qt ignores body margins, so document padding belongs on a wrapper.
  var paddingPixels = Math.max(0, Math.floor(Number(palette.padding) || 0))
  var maxImageWidthPixels = Math.floor(Number(palette.maxImageWidth) || 0)

  var direction = String(palette.direction || "")
  var quoteEdge = Direction.startEdge(direction)

  var root = documentTree(bodyHtml)
  // Invariant: content must fit the panel because it has no horizontal scrolling.
  var fit = fitting({ heights: true, sides: palette.compact === true,
    widths: maxImageWidthPixels >= MIN_IMAGE_WIDTH, clampedHeightsOnly: true }, maxImageWidthPixels)

  return "<html><head><style type=\"text/css\">"
    + "body{color:" + foreground + ";background-color:" + background + ";}"
    + "a{color:" + link + ";}"
    // Invariant: Qt uses physical CSS edges; choose quote indentation from the content direction.
    + "blockquote{color:" + quote + ";margin-" + quoteEdge + ":8px;padding-"
      + quoteEdge + ":8px;}"
    + "td,th{padding:2px;}"
    + (maxImageWidthPixels >= MIN_IMAGE_WIDTH ? "img{max-width:" + maxImageWidthPixels + "px;}" : "")
    + "</style></head><body" + baseDirectionAttribute(palette) + ">"
    + (paddingPixels > 0 ? "<div style=\"padding:" + paddingPixels + "px\">" : "")
    + serialize(root, fit)
    + (paddingPixels > 0 ? "</div>" : "")
    + "</body></html>"
}

// Invariant: reading mode builds fresh elements with checked text, links, images and dimensions.
// Sender styles and resource-bearing attributes are never copied.

var READER_DROPPED = {
  script: true, style: true, head: true, title: true, textarea: true,
  iframe: true, object: true, embed: true, applet: true, noscript: true,
  meta: true, link: true, base: true, input: true, select: true, option: true,
  optgroup: true, svg: true, canvas: true, map: true, area: true,
  frame: true, frameset: true, video: true, audio: true, source: true,
  track: true, param: true, template: true, col: true, colgroup: true
}

var READER_INLINE = {
  b: "strong", strong: "strong",
  i: "em", em: "em", cite: "em", dfn: "em", "var": "em",
  code: "code", kbd: "code", samp: "code", tt: "code"
}

var READER_HEADINGS = { h1: true, h2: true, h3: true, h4: true, h5: true, h6: true }

var READER_BLOCK = {
  div: true, p: true, section: true, article: true, aside: true, header: true,
  footer: true, main: true, nav: true, center: true, form: true,
  fieldset: true, figure: true, figcaption: true, address: true, dl: true,
  dt: true, dd: true, caption: true, legend: true, details: true, summary: true
}

// Invariant: refuse an oversized reader document whole rather than silently truncate the message.
var MAX_READER_TABLE_ROWS = 40
var MAX_READER_TABLE_COLUMNS = 8

var MAX_HEADING_CHARS = 120

function readerElement(name) {
  return { type: "element", name: name, attrs: [], selfClosing: false, children: [] }
}

function readerText(text) {
  return { type: "text", text: text }
}

// Invariant: reopen the inline chain across block boundaries so a link around a table retains its
// target on every block.
function readerState() {
  return { blocks: [], inline: [], chain: [], pending: false, filled: false }
}

function readerTarget(state) {
  return state.chain.length === 0 ? state.inline : state.chain[state.chain.length - 1].children
}

function readerLastText(state) {
  var target = readerTarget(state)
  var last = target.length > 0 ? target[target.length - 1] : null
  return last && last.type === "text" ? last : null
}

// Invariant: pending whitespace belongs before the next inline element, not inside its link or
// emphasis.
function readerSpace(state) {
  if (!state.pending || !state.filled) return
  var last = readerLastText(state)
  if (last) last.text += " "
  else readerTarget(state).push(readerText(" "))
  state.pending = false
}

// Invariant: cap reopened inline chains to prevent a small sender document multiplying into a large
// tree before complexity checks.
var MAX_READER_CHAIN = 8

function readerOpen(state, node) {
  if (state.chain.length >= MAX_READER_CHAIN) return false
  readerSpace(state)
  readerTarget(state).push(node)
  state.chain.push(node)
  return true
}

function readerAppendText(state, raw) {
  var value = String(raw).replace(UNDRAWN_CHARACTERS, "").replace(SOURCE_WHITESPACE, " ")
  if (value === "") return
  var core = value.replace(/^ +| +$/g, "")
  if (core === "") {
    if (state.filled) state.pending = true
    return
  }
  if (value.charAt(0) === " " && state.filled) state.pending = true
  var lead = state.pending && state.filled ? " " : ""
  var last = readerLastText(state)
  if (last) last.text += lead + core
  else readerTarget(state).push(readerText(lead + core))
  state.filled = true
  state.pending = value.charAt(value.length - 1) === " "
}

function readerAppendBreak(state) {

  if (!state.filled) return
  var target = readerTarget(state)
  var last = target.length > 0 ? target[target.length - 1] : null
  if (last && last.type === "element" && last.name === "br") return
  target.push(readerElement("br"))
  state.pending = false
}

function readerMeaningful(nodes) {
  for (var nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
    var node = nodes[nodeIndex]
    if (node.type === "text") {
      if (decodeReferences(node.text).replace(/[\s\u00a0]+/g, "") !== "") return true
      continue
    }
    if (node.name === "img") return true
    if (node.name === "br" || node.name === "hr") continue
    if (readerMeaningful(node.children)) return true
  }
  return false
}

function readerEdgeless(node) {
  if (node.type === "text") return decodeReferences(node.text).replace(/[\s\u00a0]+/g, "") === ""
  return node.name === "br"
}

function readerTrimmed(nodes) {
  var from = 0
  var to = nodes.length
  while (from < to && readerEdgeless(nodes[from])) from++
  while (to > from && readerEdgeless(nodes[to - 1])) to--
  return from === 0 && to === nodes.length ? nodes : nodes.slice(from, to)
}

function readerLength(nodes) {
  var total = 0
  for (var nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
    var node = nodes[nodeIndex]
    if (node.type === "text") total += decodeReferences(node.text).length

    else if (node.name === "img") total += 8
    else total += readerLength(node.children)
  }
  return total
}

function readerFlush(state, name) {
  var content = state.inline
  state.inline = []
  state.pending = false
  state.filled = false

  var reopened = []
  for (var chainIndex = 0; chainIndex < state.chain.length; chainIndex++) {
    var fresh = readerElement(state.chain[chainIndex].name)
    // Performance: built reader attributes are immutable, so reopened inline elements can share
    // them.
    fresh.attrs = state.chain[chainIndex].attrs
    if (reopened.length > 0) reopened[reopened.length - 1].children.push(fresh)
    else state.inline.push(fresh)
    reopened.push(fresh)
  }
  state.chain = reopened

  if (!readerMeaningful(content)) return
  var block = readerElement(name || "p")
  block.children = readerTrimmed(content)
  state.blocks.push(block)
}

// Invariant: Qt does not reliably hide email preheaders through tiny type, opacity or clipped
// height; remove hidden content before rendering.
var READER_INVISIBLE_TYPE = /^\s*[0-2](\.\d+)?\s*(px|pt)?\s*$/i
var READER_ZERO_LENGTH = /^\s*0(\.0+)?\s*(px|pt|em|rem|%)?\s*$/i

function readerHiddenBy(declarations, leaf) {
  if (isHiddenBy(declarations)) return true
  var clipped = false
  var hidden = false
  for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
    var declaration = declarations[declarationIndex]
    var name = declaration.name
    // Invariant: container font-size:0 can separate visible children with their own sizes. Apply
    // tiny-type hiding only at text leaves.
    if (leaf && name === "font-size" && READER_INVISIBLE_TYPE.test(declaration.value)) return true
    if (name === "opacity" && /^\s*0(\.0+)?\s*$/.test(declaration.value)) return true
    // Invariant: max-height:0 hides content only when overflow is also clipped.
    if (name === "max-height" && READER_ZERO_LENGTH.test(declaration.value)) hidden = true
    if (name === "overflow" && /^\s*hidden\b/i.test(declaration.value)) clipped = true
  }
  return hidden && clipped
}

// Invariant: mso-hide:all means hidden from Outlook, not from every client; removing it can lose
// the non-Outlook call to action.
function readerHidden(node) {
  if (attributeOf(node, "hidden") !== null) return true
  var style = attributeValue(node, "style")
  if (style === "") return false
  var leaf = true
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    if (node.children[childIndex].type !== "text") { leaf = false; break }
  }
  return readerHiddenBy(sourceDeclarations(node) || [], leaf)
}

// Invariant: reading-mode links permit mailto and public-host HTTP(S), while refused addresses
// retain their visible labels.
function readerHref(node) {
  var raw = attributeValue(node, "href")
  if (!safeHref(raw)) return ""
  var url = normalizedUrl(raw)
  if (!safeHref(url)) return ""
  if (/^\s*mailto:/i.test(url)) return raw
  return isPublicUrl(raw) ? raw : ""
}

// Invariant: alt attributes are text, not markup; decode then escape them before adding a text
// node.
function readerAltText(node) {
  var attribute = attributeOf(node, "alt")
  if (!attribute || attribute.value === null || attribute.value === undefined) return ""
  return escapeText(decodeReferences(String(attribute.value)))
    .replace(SOURCE_WHITESPACE, " ").replace(/^ +| +$/g, "")
}

// Invariant: bounded sender dimensions keep high-resolution icons from expanding to their natural
// bitmap size.
var MAX_READER_INLINE_IMAGE = 96
var MAX_READER_IMAGE_DIMENSION = 640

function readerImageDimension(node, name) {
  var raw = attributeValue(node, name)
  var value = /^\s*\d+(?:\.\d+)?\s*$/.test(raw) ? Number(raw) : 0
  if (!(value > 0)) {
    var declarations = sourceDeclarations(node) || []
    for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
      if (declarations[declarationIndex].name !== name) continue
      var match = String(declarations[declarationIndex].value).match(/^\s*(\d+(?:\.\d+)?)px\s*$/i)
      if (match) value = Number(match[1])
    }
  }
  if (!isFinite(value) || value <= 2 || value > MAX_READER_IMAGE_DIMENSION) return 0
  return Math.max(3, Math.round(value))
}

function readerAppendImage(state, node, reading) {

  if (isTrackingPixel(node)) return
  var attribute = attributeOf(node, "src")
  var source = attribute && attribute.value !== null && attribute.value !== undefined ? String(attribute.value) : ""
  var kind = attribute === null ? "none" : imageSourceKind(source)

  var renderedSource = kind === "remote" ? preparedImage(reading, source) : source
  var eligible = kind === "inline" || (kind === "remote" && reading.allowImages && renderedSource !== "")
  if (eligible && admitImage(reading, renderedSource)) {
    if (kind === "remote") reading.kept++
    readerSpace(state)
    var image = readerElement("img")
    image.attrs = [{ name: "src", value: renderedSource }]
    var width = readerImageDimension(node, "width")
    var height = readerImageDimension(node, "height")
    if (width > 0) image.attrs.push({ name: "width", value: String(width) })
    // Invariant: only small images keep explicit width and height; larger images must preserve
    // aspect ratio when Qt clamps width.
    if (height > 0 && width > 0 && width <= MAX_READER_INLINE_IMAGE
      && height <= MAX_READER_INLINE_IMAGE)
      image.attrs.push({ name: "height", value: String(height) })
    readerTarget(state).push(image)
    state.filled = true
    state.pending = false
    return
  }
  if (!eligible && kind === "remote") reading.blocked++

  var alt = readerAltText(node)
  if (alt !== "") {
    readerAppendText(state, alt)
    return
  }
  // Invariant: explicit empty alt marks decoration; absent alt on a blocked remote picture needs a
  // visible placeholder.
  if (kind === "remote" && attribute !== null && attributeOf(node, "alt") === null)
    readerAppendText(state, "[image]")
}

function readerHeadingLevel(value) {
  var text = String(value).replace(/^\s+|\s+$/g, "").toLowerCase()
  var number = parseFloat(text)
  if (!isFinite(number)) return ""
  // Invariant: normalize heading thresholds to pixels; em and percent use the mail reader’s
  // sixteen-pixel baseline.
  var pixels = /px$/.test(text) ? number
    : (/pt$/.test(text) ? number * 4 / 3
      : (/r?em$/.test(text) ? number * 16
        : (/%$/.test(text) ? number * 0.16 : 0)))
  if (pixels === 0) return ""
  if (pixels >= 28) return "h2"
  return pixels >= 20 ? "h3" : ""
}

function readerHeadingOf(node) {
  var style = attributeValue(node, "style")
  if (style === "") return ""
  if (style.toLowerCase().indexOf("font-size") < 0) return ""
  var declarations = sourceDeclarations(node) || []
  var level = ""
  for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
    if (declarations[declarationIndex].name !== "font-size") continue
    level = readerHeadingLevel(declarations[declarationIndex].value)
  }
  return level
}

// Invariant: inferred headings cannot absorb multiple blocks; an explicit heading and a large-type
// container carry different semantics.
function readerHeading(node, state, reading, tag, single) {
  readerFlush(state, "p")
  var blocks = readerBuild(node, reading)
  var content = single === true && blocks.length > 1 ? null : []
  for (var blockIndex = 0; blockIndex < blocks.length && content !== null; blockIndex++) {
    if (blocks[blockIndex].name !== "p") {
      content = null
      break
    }
    if (content.length > 0) content.push(readerText(" "))
    for (var childIndex = 0; childIndex < blocks[blockIndex].children.length; childIndex++) content.push(blocks[blockIndex].children[childIndex])
  }

  if (content === null || content.length === 0
    || readerLength(content) > MAX_HEADING_CHARS) {
    for (var remainingIndex = 0; remainingIndex < blocks.length; remainingIndex++) state.blocks.push(blocks[remainingIndex])
    return
  }
  var heading = readerElement(tag)
  heading.children = content
  state.blocks.push(heading)
}

var READER_SEPARATOR = /^[\s\u00a0]*[|\u00b7\u2022\u2013\u2014\/-]?[\s\u00a0]*$/

function readerFurniture(node) {
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") continue

    if (child.name === "img") return false
    if (!readerFurniture(child)) return false
  }
  return READER_SEPARATOR.test(readerTextOf(node))
}

function readerTextOf(node) {
  var text = ""
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    text += child.type === "text" ? child.text : readerTextOf(child)
  }
  return text
}

function readerDataTable(node, reading) {
  var rows = rowsOf(node, [])
  if (rows.length === 0 || rows.length > MAX_READER_TABLE_ROWS) return null

  // Performance: settle a table’s admissible shape before building its cells, avoiding a second
  // build on fallback.
  var grid = []
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    var cells = []
    for (var childIndex = 0; childIndex < rows[rowIndex].children.length; childIndex++) {
      var cell = rows[rowIndex].children[childIndex]
      if (cell.type === "text") continue
      if (cell.name === "td" || cell.name === "th") cells.push(cell)
    }
    if (cells.length > MAX_READER_TABLE_COLUMNS) return null
    if (cells.length > 0) grid.push(cells)
  }
  if (grid.length === 0) return null

  var columns = 0
  for (var gridIndex = 0; gridIndex < grid.length; gridIndex++) {
    if (grid[gridIndex].length > columns) columns = grid[gridIndex].length
  }
  for (var column = columns - 1; column >= 0; column--) {
    var furniture = true
    for (var candidateRow = 0; candidateRow < grid.length && furniture; candidateRow++) {
      if (column >= grid[candidateRow].length || !readerFurniture(grid[candidateRow][column])) furniture = false
    }
    if (!furniture) continue
    for (var trimmedRow = 0; trimmedRow < grid.length; trimmedRow++) grid[trimmedRow].splice(column, 1)
  }
  var widest = 0
  for (var widthIndex = 0; widthIndex < grid.length; widthIndex++) {
    if (grid[widthIndex].length > widest) widest = grid[widthIndex].length
  }

  if (widest < 2) return null

  var table = readerElement("table")
  // Invariant: reader mode admits one grid level; nested grids are flattened into readable content.
  reading.tables = false
  for (var row = 0; row < grid.length; row++) {
    var line = readerElement("tr")
    for (var columnIndex = 0; columnIndex < grid[row].length; columnIndex++) {
      var out = readerElement(grid[row][columnIndex].name === "th" ? "th" : "td")
      out.children = readerInlineOrBlocks(readerBuild(grid[row][columnIndex], reading))
      line.children.push(out)
    }
    table.children.push(line)
  }
  reading.tables = true
  return table
}

// Performance: build each layout cell once. Rebuilding cells at every nested table level caused
// exponential work in newsletters.
var MAX_ROW_CHARS = 160

// Invariant: a cell with its own line break cannot join the next cell’s first line.
function readerBroken(children) {
  for (var childIndex = 0; childIndex < children.length; childIndex++) {
    var child = children[childIndex]
    if (child.type === "text") continue
    if (child.name === "br") return true
    if (readerBroken(child.children)) return true
  }
  return false
}

function readerRow(node, state, reading) {

  var cells = []
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var cell = node.children[childIndex]
    if (cell.type === "text") continue
    if (cell.name !== "td" && cell.name !== "th") return false
    // Invariant: joining a row must not discard the font-size evidence that identifies a heading.
    if (readerHeadingOf(cell) !== "") return false

    if (readerFurniture(cell)) continue
    cells.push(cell)
  }

  var built = []
  for (var cellIndex = 0; cellIndex < cells.length; cellIndex++) built.push(readerBuild(cells[cellIndex], reading))

  var line = []
  for (var lineIndex = 0; lineIndex < built.length && line !== null; lineIndex++) {
    var blocks = built[lineIndex]
    if (blocks.length === 0) continue
    if (blocks.length > 1 || blocks[0].name !== "p" || readerBroken(blocks[0].children)) {
      line = null
      break
    }
    if (line.length > 0) line.push(readerText(" "))
    for (var wordIndex = 0; wordIndex < blocks[0].children.length; wordIndex++) line.push(blocks[0].children[wordIndex])
  }

  readerFlush(state, "p")
  if (line !== null && readerLength(line) <= MAX_ROW_CHARS) {
    if (line.length > 0) {
      var joined = readerElement("p")
      joined.children = readerTrimmed(line)
      state.blocks.push(joined)
    }
    return true
  }
  for (var cellIndex = 0; cellIndex < built.length; cellIndex++) {
    for (var blockIndex = 0; blockIndex < built[cellIndex].length; blockIndex++) state.blocks.push(built[cellIndex][blockIndex])
  }
  return true
}

function readerInlineOrBlocks(blocks) {
  if (blocks.length === 1 && blocks[0].name === "p") return blocks[0].children
  return blocks
}

function readerListItems(node, list, reading) {
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") continue
    if (READER_DROPPED[child.name] === true) continue
    if (child.name !== "li") {
      readerListItems(child, list, reading)
      continue
    }
    var item = readerElement("li")
    item.children = readerInlineOrBlocks(readerBuild(child, reading))
    if (item.children.length === 0) continue
    list.children.push(item)
  }
}

function readerNode(child, state, reading) {
  if (child.type === "text") {

    if (!child.raw) readerAppendText(state, child.text)
    return
  }
  var name = child.name
  if (READER_DROPPED[name] === true) return
  if (readerHidden(child)) return

  if (name === "br") {
    readerAppendBreak(state)
    return
  }
  if (name === "img") {
    readerAppendImage(state, child, reading)
    return
  }
  if (name === "hr") {
    readerFlush(state, "p")
    state.blocks.push(readerElement("hr"))
    return
  }

  if (name === "a") {
    var href = readerHref(child)

    if (href === "") {
      readerWalk(child, state, reading)
      return
    }
    var link = readerElement("a")
    link.attrs = [{ name: "href", value: href }]
    var linked = readerOpen(state, link)
    readerWalk(child, state, reading)
    if (linked) state.chain.pop()
    return
  }

  var inline = READER_INLINE[name]
  if (typeof inline === "string") {
    var opened = readerOpen(state, readerElement(inline))
    readerWalk(child, state, reading)
    if (opened) state.chain.pop()
    return
  }

  if (READER_HEADINGS[name] === true) {
    readerHeading(child, state, reading, name)
    return
  }

  if (name === "pre") {
    readerFlush(state, "p")
    var preformatted = readerPreText(child, "").replace(/^\n+/, "").replace(/\s+$/, "")
    if (preformatted !== "") {
      var block = readerElement("pre")
      block.children = [readerText(preformatted)]
      state.blocks.push(block)
    }
    return
  }

  if (name === "ul" || name === "ol") {
    readerFlush(state, "p")
    var list = readerElement(name)
    readerListItems(child, list, reading)
    if (list.children.length > 0) {
      state.blocks.push(list)
      return
    }

    readerWalk(child, state, reading)
    readerFlush(state, "p")
    return
  }

  if (name === "blockquote") {
    readerFlush(state, "p")
    var quoted = readerBuild(child, reading)
    if (quoted.length === 0) return
    var quote = readerElement("blockquote")
    quote.children = quoted
    state.blocks.push(quote)
    return
  }

  if (name === "table") {
    readerFlush(state, "p")
    if (reading.tables) {
      var grid = isGrid(child) ? readerDataTable(child, reading) : null
      if (grid !== null) {
        state.blocks.push(grid)
        return
      }
    }
    readerWalk(child, state, reading)
    readerFlush(state, "p")
    return
  }

  // Invariant: row rebuilding would lose an inline link opened outside that row; join only with an
  // empty chain.
  if (name === "tr" && state.chain.length === 0 && readerRow(child, state, reading)) return

  if (TABLE_PARTS[name] === true || READER_BLOCK[name] === true) {
    // Invariant: inferred-heading rebuilding would lose an enclosing link; retain the original walk
    // while the chain is open.
    var inferred = state.chain.length === 0 ? readerHeadingOf(child) : ""
    if (inferred !== "") {
      readerHeading(child, state, reading, inferred, true)
      return
    }
    readerFlush(state, "p")
    readerWalk(child, state, reading)
    readerFlush(state, "p")
    return
  }

  readerWalk(child, state, reading)
}

function readerWalk(node, state, reading) {
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) readerNode(node.children[childIndex], state, reading)
}

// Invariant: whitespace inside pre is message content, not template indentation.
function readerPreText(node, out) {
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") {
      if (!child.raw) out += child.text
      continue
    }
    if (READER_DROPPED[child.name] === true) continue
    if (child.name === "br") {
      out += "\n"
      continue
    }
    out = readerPreText(child, out)
  }
  return out
}

function readerBuild(node, reading) {
  var state = readerState()
  readerWalk(node, state, reading)
  readerFlush(state, "p")
  return state.blocks
}

function readerTidy(blocks) {
  var out = []
  for (var blockIndex = 0; blockIndex < blocks.length; blockIndex++) {
    var block = blocks[blockIndex]
    if (block.name === "hr") {
      if (out.length === 0) continue
      if (out[out.length - 1].name === "hr") continue
    }
    var avatar = readerAvatarRow(block)
    if (avatar !== null) block = avatar
    // Invariant: join only consecutive paragraphs consisting entirely of bounded small images;
    // ordinary picture-and-text paragraphs stay separate.
    if (block.name === "p" && readerSmallImageCount(block.children) > 0
      && out.length > 0 && out[out.length - 1].name === "p"
      && readerSmallImageCount(out[out.length - 1].children) > 0) {
      out[out.length - 1].children.push(readerText(" "))
      for (var joined = 0; joined < block.children.length; joined++)
        out[out.length - 1].children.push(block.children[joined])
      continue
    }
    out.push(block)
  }
  while (out.length > 0 && out[out.length - 1].name === "hr") out.pop()
  return out
}

// Invariant: Qt aligns paragraph images to the text baseline. A bounded leading avatar needs an
// explicit table-cell row to align with its label.
function readerAvatarRow(block) {
  if (block.name !== "p") return null
  var children = readerTrimmed(block.children)
  if (children.length < 2 || readerSmallImageCount([children[0]]) !== 1) return null
  var words = children.slice(1)
  if (!readerMeaningful(words) || readerContainsImage(words)) return null

  var table = readerElement("table")
  table.attrs = [{ name: "cellspacing", value: "0" }, { name: "cellpadding", value: "0" }]
  var row = readerElement("tr")
  var picture = readerElement("td")
  var text = readerElement("td")
  // Invariant: fixed avatar-cell spacing must replace the document’s generic table spacing to avoid
  // doubled gaps.
  picture.attrs = [{ name: "valign", value: "middle" },
    { name: "style", value: "padding:0px;padding-right:6px" }]
  text.attrs = [{ name: "valign", value: "middle" },
    { name: "style", value: "padding:0px" }]
  picture.children = [children[0]]
  text.children = words
  row.children = [picture, text]
  table.children = [row]
  return table
}

function readerContainsImage(nodes) {
  for (var nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
    var node = nodes[nodeIndex]
    if (node.type === "text") continue
    if (node.name === "img" || readerContainsImage(node.children)) return true
  }
  return false
}

function readerSmallImageCount(nodes) {
  var count = 0
  for (var nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
    var node = nodes[nodeIndex]
    if (node.type === "text") {
      if (decodeReferences(node.text).replace(/[\s\u00a0]+/g, "") !== "") return 0
      continue
    }
    if (node.name === "img") {
      var width = Number(attributeValue(node, "width"))
      var height = Number(attributeValue(node, "height"))
      if (width <= 2 || width > MAX_READER_INLINE_IMAGE
        || (height > 0 && height > MAX_READER_INLINE_IMAGE)) return 0
      count++
      continue
    }
    if (node.name !== "a") return 0
    var linkedImages = readerSmallImageCount(node.children)
    if (linkedImages === 0) return 0
    count += linkedImages
  }
  return count
}

// Invariant: reader construction must not mutate the sender tree subsequently used by formatted
// cleaning.
function readerTree(root, options) {
  var settings = options || {}
  var reading = imagePolicy(settings)
  reading.tables = true
  var document = { type: "root", children: readerTidy(readerBuild(root, reading)) }
  var text = serialize(document)
  var size = { length: text.length, tags: 0, images: 0, tables: 0, tableDepth: 0 }
  size.tableDepth = measure(document, 0, size)
  return {
    document: document,
    html: text,
    images: reading.kept,
    blockedImages: reading.blocked,
    complexity: size,
    tooHeavy: tooHeavyWithoutImageData(size, reading),

    empty: document.children.length === 0
  }
}

function readerDocumentFor(source, colors) {
  var palette = colors || {}
  var foreground = String(palette.foreground || "")
  var background = String(palette.background || "")
  var link = String(palette.link || foreground)
  var quote = String(palette.quote || foreground)
  var base = Math.max(8, Math.floor(Number(palette.fontSize) || 13))
  var maxImageWidthPixels = Math.floor(Number(palette.maxImageWidth) || 0)

  var gap = Math.max(4, Math.round(base * 0.85))
  var rule = Math.max(2, Math.round(base * 0.5))

  var direction = String(palette.direction || "")
  var startEdge = Direction.startEdge(direction)
  var endEdge = Direction.endEdge(direction)

  return "<html><head><style type=\"text/css\">"
    + "body{color:" + foreground + ";background-color:" + background + ";}"
    + "a{color:" + link + ";}"
    + "p{margin-top:0px;margin-bottom:" + gap + "px;}"
    + "h1{font-size:" + Math.round(base * 1.6) + "px;margin-top:" + (gap * 2)
      + "px;margin-bottom:" + rule + "px;}"
    + "h2{font-size:" + Math.round(base * 1.35) + "px;margin-top:" + (gap * 2)
      + "px;margin-bottom:" + rule + "px;}"
    + "h3{font-size:" + Math.round(base * 1.18) + "px;margin-top:" + Math.round(gap * 1.6)
      + "px;margin-bottom:" + rule + "px;}"
    + "h4,h5,h6{font-size:" + base + "px;margin-top:" + Math.round(gap * 1.4)
      + "px;margin-bottom:" + rule + "px;}"
    // Invariant: Qt’s own list indent and the stylesheet indent must not both apply.
    + "ul,ol{margin-top:0px;margin-bottom:" + gap
      + "px;margin-" + startEdge + ":26px;-qt-list-indent:0;}"
    + "li{margin-bottom:" + rule + "px;}"
    + "blockquote{color:" + quote + ";margin-" + startEdge + ":" + rule
      + "px;padding-" + startEdge + ":" + gap
      + "px;margin-top:0px;margin-bottom:" + gap + "px;}"
    + "pre{margin-top:0px;margin-bottom:" + gap + "px;}"

    + "td,th{padding-top:" + rule + "px;padding-bottom:" + rule
      + "px;padding-" + endEdge + ":" + gap + "px;}"
    + "th{font-weight:bold;text-align:" + startEdge + ";}"
    + (maxImageWidthPixels >= MIN_IMAGE_WIDTH ? "img{max-width:" + maxImageWidthPixels + "px;}" : "")
    + "</style></head><body" + baseDirectionAttribute(palette) + ">"
    + serialize(documentTree(source))
    + "</body></html>"
}

var BODY_MODES = { reader: true, original: true, plain: true }
var HEAVY_MESSAGE_RENDERING_DEFAULT = "Show plain text first"
var HEAVY_MESSAGE_RENDERING_ALWAYS = "Always render"

function alwaysRenderHeavyMessages(value) {
  return value === HEAVY_MESSAGE_RENDERING_ALWAYS
}

function heavyMessageRendering(always) {
  return always === true ? HEAVY_MESSAGE_RENDERING_ALWAYS : HEAVY_MESSAGE_RENDERING_DEFAULT
}

function bodyModeOf(value, fallback) {
  var wanted = String(value === undefined || value === null ? "" : value)
  if (BODY_MODES[wanted] === true) return wanted
  var other = String(fallback === undefined || fallback === null ? "" : fallback)
  return BODY_MODES[other] === true ? other : "reader"
}

function resolveBodyMode(wanted, available) {
  var has = available || {}
  var want = BODY_MODES[wanted] === true ? wanted : "reader"

  if (has.html !== true) return "plain"
  if (want === "plain") return "plain"
  if (want === "reader" && has.reader !== true) want = "original"
  var heavy = want === "reader" ? has.readerHeavy === true : has.originalHeavy === true
  // Invariant: heavy rich text must remain refused until the user explicitly overrides the
  // GUI-thread layout budget.
  if (heavy && has.forced !== true) return "plain"
  return want
}

function bodyModeEmptied(wanted, available) {
  var has = available || {}
  if (wanted !== "reader" || has.html !== true) return false
  return has.reader !== true && resolveBodyMode(wanted, available) === "original"
}

function bodyModeRefused(wanted, available) {
  var has = available || {}
  if (wanted === "plain" || has.html !== true) return false
  return resolveBodyMode(wanted, available) === "plain"
}

function readingColumnWidth(available, maximum) {
  var room = Math.max(80, Math.floor(Number(available) || 0))
  var ideal = Math.floor(Number(maximum) || 0)

  return ideal > 0 ? Math.min(room, ideal) : room
}

function readingColumnOffset(available, width) {
  var room = Math.max(0, Math.floor(Number(available) || 0))
  var column = Math.max(0, Math.floor(Number(width) || 0))
  return Math.max(0, Math.round((room - column) / 2))
}

var IMAGE_LINK_PREFIX = "omarchy-image:"

var BLOCK_ELEMENTS = {
  p: true, div: true, tr: true, li: true, blockquote: true, section: true,
  article: true, header: true, footer: true, table: true, ul: true, ol: true,
  h1: true, h2: true, h3: true, h4: true, h5: true, h6: true
}

// Invariant: plain-text markers and source images share one walk and index order. A marker must
// never open a different image.
var SOURCE_WHITESPACE = /[ \t\r\n\f]+/g

// Invariant: end plain-text table cells with a line boundary so labels and values do not join into
// one word.
var CELL_ELEMENTS = { td: true, th: true }

function flatten(node, state) {
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") {
      // Invariant: collapse source whitespace before decoding entities so explicit nonbreaking
      // spacing survives.
      if (!child.raw) state.text += decodeReferences(child.text.replace(SOURCE_WHITESPACE, " "))
      continue
    }
    if (DROPPED_ELEMENTS[child.name] === true) continue
    if (child.name === "img") {

      if (isTrackingPixel(child)) continue
      state.images.push(imageSourceOf(child))
      state.text += "[image " + state.images.length + "]"
      continue
    }
    if (child.name === "br") {
      state.text += "\n"
      continue
    }
    if (child.name === "li") state.text += "• "
    flatten(child, state)
    if (BLOCK_ELEMENTS[child.name] === true || CELL_ELEMENTS[child.name] === true) {
      state.text += "\n"
    }
  }
  return state
}

function imageSourceOf(node) {
  var attribute = attributeOf(node, "src")
  return attribute && attribute.value !== null && attribute.value !== undefined ? String(attribute.value) : ""
}

function readTree(root) {
  var state = flatten(root, { text: "", images: [] })
  state.text = state.text
    .replace(/[^\S\n]+\n/g, "\n")
    // Invariant: discard template indentation after line boundaries; preserving it creates false
    // manual indentation in the plain-text document.
    .replace(/\n[^\S\n]+/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/^\s+|\s+$/g, "")
  return state
}

function readPlainText(html) {
  return readTree(parse(html))
}

// Invariant: strip invisible preview padding while preserving U+00A0 as real spacing.
var UNDRAWN_CHARACTERS = /[\u00ad\u034f\u061c\u180e\u200b-\u200f\u2060-\u2064\ufeff]/g

var BLANK_LINE = /^[^\S\n]+$/gm
var BLANK_RUN = /\n{3,}/g

function readableText(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(UNDRAWN_CHARACTERS, "")
    .replace(BLANK_LINE, "")
    .replace(BLANK_RUN, "\n\n")
    .replace(/^\s+|\s+$/g, "")
}

function escapeText(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

// Invariant: plain-text rendering preserves deliberate runs of spaces, unlike HTML’s normal
// whitespace collapse.
function preserveSpacing(escaped) {
  return String(escaped).replace(/ {2,}/g, function(run) {
    return new Array(run.length + 1).join("&nbsp;")
  })
}

function plainTextDocument(text, colors, linkImages) {
  var palette = colors || {}
  var foreground = String(palette.foreground || "")
  var background = String(palette.background || "")
  var link = String(palette.link || foreground)
  var body = preserveSpacing(escapeText(readableText(text)))
  if (linkImages) {
    body = body.replace(/\[image (\d+)\]/g, function(match, index) {
      return "<a href=\"" + IMAGE_LINK_PREFIX + index + "\">" + match + "</a>"
    })
  }
  body = body.replace(/\n/g, "<br>")
  return "<html><head><style type=\"text/css\">"
    + "body{color:" + foreground + ";background-color:" + background + ";}"
    + "a{color:" + link + ";}"
    // Invariant: plain-text body direction supplies the fallback for lines without a strong
    // directional character.
    + "</style></head><body" + baseDirectionAttribute(palette) + ">"
    + body + "</body></html>"
}

function imageLinkIndex(url) {
  var text = String(url || "")
  if (text.indexOf(IMAGE_LINK_PREFIX) !== 0) return 0
  var index = Number(text.substring(IMAGE_LINK_PREFIX.length))
  return index > 0 ? Math.floor(index) : 0
}

.pragma library
.import "Html.js" as Html

// Invariant: imported signature HTML passes both the shared sanitizer and a stricter signature policy.

var MAX_HTML_BYTES = 256 * 1024
var MAX_IMAGE_BYTES = 512 * 1024
var MAX_DATA_IMAGES = 8

// Invariant: signatures forbid executable, embedded, interactive, and remote-loading content while preserving safe formatting.
var FORBIDDEN_ELEMENTS = ["script", "style", "iframe", "frame", "frameset", "object", "embed", "applet",
  "form", "input", "button", "select", "textarea", "option", "svg", "math", "template", "link", "meta",
  "base", "video", "audio", "source", "track", "canvas", "noscript"]
var FORBIDDEN_ATTRIBUTES = ["action", "formaction", "background", "srcset", "poster", "xlink:href",
  "data", "codebase", "usemap", "ping", "manifest", "longdesc", "profile"]

var RASTERS = [
  { mime: "image/png", magic: [0x89, 0x50, 0x4e, 0x47] },
  { mime: "image/jpeg", magic: [0xff, 0xd8, 0xff] },
  { mime: "image/gif", magic: [0x47, 0x49, 0x46, 0x38] },
  { mime: "image/webp", magic: [0x52, 0x49, 0x46, 0x46], at12: [0x57, 0x45, 0x42, 0x50] }
]

function base64Prefix(data, count) {
  var text = String(data || "").replace(/[^A-Za-z0-9+\/=]/g, "")
  var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var bytes = []
  var bits = 0
  var value = 0
  for (var characterIndex = 0; characterIndex < text.length && bytes.length < count; characterIndex++) {
    var character = text.charAt(characterIndex)
    if (character === "=") break
    var index = alphabet.indexOf(character)
    if (index < 0) return []
    value = (value << 6) | index
    bits += 6
    if (bits >= 8) {
      bits -= 8
      bytes.push((value >> bits) & 0xff)
    }
  }
  return bytes
}

// Invariant: inspect raster bytes rather than trust a declared image type; SVG must not be admitted as PNG.
function rasterKind(base64) {
  var head = base64Prefix(base64, 16)
  for (var rasterIndex = 0; rasterIndex < RASTERS.length; rasterIndex++) {
    var raster = RASTERS[rasterIndex]
    var ok = head.length >= raster.magic.length
    for (var headIndex = 0; ok && headIndex < raster.magic.length; headIndex++) if (head[headIndex] !== raster.magic[headIndex]) ok = false
    if (ok && raster.at12) {
      ok = head.length >= 16
      for (var signatureIndex = 0; ok && signatureIndex < 4; signatureIndex++) if (head[8 + signatureIndex] !== raster.at12[signatureIndex]) ok = false
    }
    if (ok) return raster.mime
  }
  return ""
}

function base64Bytes(base64) {
  var text = String(base64 || "").replace(/[^A-Za-z0-9+\/=]/g, "")
  var padding = text.length > 0 && text.charAt(text.length - 1) === "=" ? (text.charAt(text.length - 2) === "=" ? 2 : 1) : 0
  return Math.floor(text.length * 3 / 4) - padding
}

function importImage(base64, options) {
  var settings = options || {}
  var limit = Math.max(1, Math.floor(Number(settings.maxImageBytes) || MAX_IMAGE_BYTES))
  var mime = rasterKind(base64)
  if (mime === "") return { html: "", plain: "", problem: "That file is not a PNG, JPEG, GIF or WebP image" }
  var size = base64Bytes(base64)
  if (size > limit) return { html: "", plain: "", problem: "That image is larger than " + Math.round(limit / 1024) + " KB" }
  var clean = String(base64 || "").replace(/[^A-Za-z0-9+\/=]/g, "")
  return { html: "<p><img src=\"data:" + mime + ";base64," + clean + "\"></p>", plain: "", dropped: 0, images: 1, problem: "" }
}

function dataImageOk(value, limit) {
  var match = /^data:(image\/(?:png|jpe?g|gif|webp));base64,([A-Za-z0-9+\/=]+)$/i.exec(String(value || ""))
  if (!match) return false
  if (base64Bytes(match[2]) > limit) return false
  var kind = rasterKind(match[2])
  return kind !== "" && (kind === match[1].toLowerCase() || (kind === "image/jpeg" && /jpe?g/i.test(match[1])))
}

function hrefOk(value) {
  var url = String(value || "").trim()
  if (/^mailto:[^\s<>"]+$/i.test(url)) return true
  var match = /^https?:\/\/([^\/?#:]+)/i.exec(url)
  return !!match && Html.isPublicHost(match[1])
}

function signatureAttributes(node, name, context) {
  var attributes = []
  var list = Array.isArray(node.attrs) ? node.attrs : []
  for (var attributeIndex = 0; attributeIndex < list.length; attributeIndex++) {
    var attribute = list[attributeIndex]
    var attributeName = String(attribute.name || "").toLowerCase()
    var value = String(attribute.value === undefined ? "" : attribute.value)
    if (!signatureAttributeAllowed(attributeName, value, name, context)) {
      context.dropped++
      continue
    }
    attributes.push({ name: attributeName, value: value })
  }
  return attributes
}

function signatureAttributeAllowed(attributeName, value, elementName, context) {
  if (attributeName.indexOf("on") === 0 || FORBIDDEN_ATTRIBUTES.indexOf(attributeName) >= 0) return false
  if (attributeName === "href") return hrefOk(value)
  if (attributeName === "src") {
    if (elementName !== "img" || !dataImageOk(value, context.imageLimit) || context.images >= MAX_DATA_IMAGES) return false
    context.images++
    return true
  }
  // Invariant: signature styles cannot fetch resources, execute content, or hide words.
  if (attributeName === "style")
    return !/url\s*\(|expression\s*\(|@import|behavior\s*:|javascript:|display\s*:\s*none|visibility\s*:\s*hidden|opacity\s*:\s*0(?![.\d])|font-size\s*:\s*0(?![.\d])|font-size\s*:\s*0?\.\d|text-indent\s*:\s*-/i.test(value)
  return true
}

function prune(node, context) {
  var kept = []
  for (var childIndex = 0; childIndex < node.children.length; childIndex++) {
    var child = node.children[childIndex]
    if (child.type === "text") {
      kept.push(child)
      continue
    }
    if (child.type !== "element") {
      context.dropped++
      continue
    }
    var name = String(child.name || "").toLowerCase()
    if (FORBIDDEN_ELEMENTS.indexOf(name) >= 0) {
      context.dropped++
      continue
    }
    var attributes = signatureAttributes(child, name, context)
    child.attrs = attributes
    child.name = name
    if (name === "img" && !attributes.some(function(attribute) { return attribute.name === "src" })) {
      context.dropped++
      continue
    }
    prune(child, context)
    kept.push(child)
  }
  node.children = kept
}

function sourceRemovals(source) {
  var text = String(source || "")
  var count = 0
  var patterns = [/<\s*(script|style|iframe|object|embed|form|input|svg|template|link|meta)\b/gi,
    /\son[a-z]+\s*=/gi, /javascript\s*:/gi, /url\s*\(/gi, /\sbackground\s*=/gi]
  for (var patternIndex = 0; patternIndex < patterns.length; patternIndex++) {
    var found = text.match(patterns[patternIndex])
    if (found) count += found.length
  }
  return count
}

function importHtml(html, options) {
  var settings = options || {}
  var source = String(html === undefined || html === null ? "" : html)
  if (source.length > Math.max(1, Math.floor(Number(settings.maxHtmlBytes) || MAX_HTML_BYTES)))
    return { html: "", plain: "", dropped: 0, images: 0, problem: "That file is too large for a signature" }
  var cleaned = Html.sanitize(source, { allowRemoteImages: false, keepColors: true })
  // Docs: count non-image removals from the source because Html reports only blocked images.
  var context = { dropped: sourceRemovals(source) + cleaned.blockedImages, images: 0,
    imageLimit: Math.max(1, Math.floor(Number(settings.maxImageBytes) || MAX_IMAGE_BYTES)) }
  var document = Html.parse(cleaned.html)
  prune(document, context)
  var text = Html.serialize(document)
  var read = Html.readTree(document)
  var plain = String(read && read.text !== undefined ? read.text : read || "").replace(/[ \t]+\n/g, "\n").trim()
  if (text.trim() === "" || (plain === "" && context.images === 0))
    return { html: "", plain: "", dropped: context.dropped, images: 0, problem: "Nothing in that file can be a signature" }
  return { html: text, plain: plain, dropped: context.dropped, images: context.images, problem: "" }
}

function importNote(result) {
  if (!result) return ""
  if (result.problem) return result.problem
  var parts = []
  if (result.images > 0) parts.push(result.images === 1 ? "1 image" : result.images + " images")
  if (result.dropped > 0) parts.push(result.dropped + " unsafe or unsupported " + (result.dropped === 1 ? "part" : "parts") + " removed")
  return parts.length === 0 ? "Imported" : "Imported: " + parts.join(", ")
}

// Invariant: convert stored data images to CID parts for receiving clients that suppress data URLs.
function inlineParts(html, prefix) {
  var text = String(html || "")
  var parts = []
  var stem = String(prefix || "sig")
  var out = text.replace(/src="data:(image\/(?:png|jpe?g|gif|webp));base64,([A-Za-z0-9+\/=]+)"/gi,
    function(all, mime, data) {
      var id = stem + (parts.length + 1) + "@omamail"
      parts.push({ cid: id, mimeType: mime.toLowerCase(), data: data })
      return "src=\"cid:" + id + "\""
    })
  return { html: out, parts: parts }
}

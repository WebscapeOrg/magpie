.pragma library

// Shared Node/QML fixtures and timers measure JavaScript preparation only.
// Each synthetic card nests nine layout tables to exercise flattening limits.
function outlookMail(cards) {
  var out = "<html><head><title>Newsletter</title><style>.x{color:red}</style></head><body>"
    + "<div style=\"display:none;font-size:1px\">preheader text nobody reads</div>"
  for (var cardIndex = 0; cardIndex < cards; cardIndex++) {
    var open = ""
    var close = ""
    for (var depth = 0; depth < 9; depth++) {
      open += "<table width=\"" + (600 - depth * 10) + "\" align=\"center\" cellpadding=\"0\""
        + " bgcolor=\"#ffffff\"><tr><td style=\"padding:0\">"
      close = "</td></tr></table>" + close
    }
    out += open
      + "<img src=\"https://cdn.example.com/hero" + cardIndex + ".png\" width=\"540\" height=\"200\" alt=\"a>b\">"
      + "<h2 style=\"color:#111;margin:0 0 8px\">Headline " + cardIndex + "</h2>"
      + "<p style=\"margin:0 12px;color:#555\">Body copy &amp; more of it, "
      + "<a href=\"https://example.com/" + cardIndex + "\">read on</a>.</p>"
      + "<img src=\"https://track.example.com/p" + cardIndex + ".gif\" width=\"1\" height=\"1\">"
      + close
  }
  return out + "</body></html>"
}

function kibibytes(measured) {
  return (measured.length / 1024).toFixed(0)
}

function pad(text, width) {
  var out = String(text)
  while (out.length < width) out = " " + out
  return out
}

// Milliseconds per run, over enough runs to outlast the clock's resolution.
function timed(run) {
  var started = Date.now()
  var runs = 0
  while (Date.now() - started < 250 || runs < 3) {
    run()
    runs++
  }
  return (Date.now() - started) / runs
}

// Parse once, prepare all three content modes, then build the reader document.
function openOnce(html, source, palette) {
  var ready = html.sanitize(source,
    { allowRemoteImages: false, withPlainText: true, withReader: true })
  html.readerDocumentFor(ready.reader.document, palette)
  return ready
}

function refusedBy(size, limits) {
  if (size.length > limits.richText) return "too long (" + kibibytes(size) + " KiB)"
  if (size.tags > limits.elements) return "too many elements (" + size.tags + ")"
  if (size.tables > limits.tables) return "too many tables (" + size.tables + ")"
  if (size.tableDepth > limits.tableDepth) return "tables too deep (" + size.tableDepth + ")"
  return ""
}

function run(html, log) {
  var palette = {
    foreground: "#cacccc", background: "#101315", link: "#7aa2f7", quote: "#707880",
    maxImageWidth: 380, compact: true
  }

  log("  " + pad("source", 8) + pad("to Qt", 9) + pad("elements", 10)
    + pad("reading", 9) + pad("open", 10) + pad("relayout", 10) + "   verdict")
  log("  " + pad("", 68).replace(/ /g, "-"))

  var sizes = [6, 24, 90, 240]
  for (var caseIndex = 0; caseIndex < sizes.length; caseIndex++) {
    var source = outlookMail(sizes[caseIndex])
    var ready = openOnce(html, source, palette)

    var open = timed(function() { openOnce(html, source, palette) })
    // A drag walks through widths; the document is not reparsed for any of them.
    var step = 0
    var relayout = timed(function() {
      palette.maxImageWidth = 300 + (step++ % 30) * 20
      html.readerDocumentFor(ready.reader.document, palette)
    })
    palette.maxImageWidth = 380

    // Reader and formatted documents have independent complexity budgets.
    var refused = ready.reader.tooHeavy
      ? refusedBy(ready.reader.complexity, html.limits)
      : (ready.tooHeavy ? "formatted view only (" + refusedBy(ready.complexity, html.limits) + ")" : "")
    log("  " + pad(kibibytes(source) + " KiB", 8)
      + pad(kibibytes(ready.html) + " KiB", 9)
      + pad(ready.complexity.tags, 10)
      + pad(ready.reader.complexity.tags, 9)
      + pad(open.toFixed(2) + "ms", 10)
      + pad(relayout.toFixed(2) + "ms", 10)
      + (refused === "" ? "" : "   refused: " + refused))
  }

  log("")
  log("  source    the synthetic HTML input")
  log("  to Qt     what the renderer is given for the formatted view")
  log("  elements  the formatted view's element count")
  log("  reading   the rebuilt reading document's, off the same parse")
  log("  open      one parse: sanitise, rebuild for reading, read as text,")
  log("            then build the document reading mode draws")
  log("  relayout  one width step of a splitter drag, no parse")
  log("  verdict   which bound refused reading mode; the reader shows the plain text")
  log("            instead, so such a row is the cost of finding that out. A row")
  log("            marked \"formatted view only\" is one reading mode draws and the")
  log("            sender's own layout is too heavy for")
}

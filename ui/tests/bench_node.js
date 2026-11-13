const { load } = require("./load")

const html = load("message/Html.js")
const bench = load("tests/bench_cases.js")

// Invariant: Reached through plain functions rather than through the module object, so
// this and the QML runner hand Html.js over the same way.
const api = {
  sanitize: function (source, options) { return html.sanitize(source, options) },
  readerDocumentFor: function (document, palette) {
    return html.readerDocumentFor(document, palette)
  },
  limits: {
    richText: html.MAX_RICH_TEXT,
    elements: html.MAX_ELEMENTS,
    tables: html.MAX_TABLES,
    tableDepth: html.MAX_TABLE_DEPTH
  }
}

console.log("V8 — node " + process.version)
bench.run(api, console.log)

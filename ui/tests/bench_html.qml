import QtQml

import "../message/Html.js" as Html
import "bench_cases.js" as Bench

QtObject {
  Component.onCompleted: {
    console.log("QML — " + Qt.platform.os)

    Bench.run({
      sanitize: function(source, options) { return Html.sanitize(source, options) },
      documentFor: function(document, palette) { return Html.documentFor(document, palette) },
      readerDocumentFor: function(document, palette) {
        return Html.readerDocumentFor(document, palette)
      },
      limits: {
        richText: Html.MAX_RICH_TEXT,
        elements: Html.MAX_ELEMENTS,
        tables: Html.MAX_TABLES,
        tableDepth: Html.MAX_TABLE_DEPTH
      }
    }, function(line) { console.log(line) })
    Qt.exit(0)
  }

}

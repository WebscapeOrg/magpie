import QtQuick

QtObject {
  property var source: ({})
  readonly property var value: ({
    id: String(source.id || "omamail"),
    name: String(source.name || "Magpie Mail"),
    version: String(source.version || ""),
    barWidget: source.barWidget || ({defaults: ({})})
  })
}

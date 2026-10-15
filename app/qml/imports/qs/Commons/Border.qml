pragma Singleton
import QtQuick

QtObject {
  function controlSpec(state, foreground, accent) {
    return state === "selected"
      ? ({ color: Style.selectedStateColor(foreground, accent), width: Style.normalBorderWidth })
      : ({ color: Style.normalBorderFor(foreground, accent), width: Style.normalBorderWidth })
  }
  function none() { return flat("transparent", 0) }
  function top(spec) { return spec && spec.width ? spec.width : 0 }
  function bottom(spec) { return top(spec) }
  function left(spec) { return top(spec) }
  function right(spec) { return top(spec) }
  function controlHasWidth(state, foreground, accent) { return top(controlSpec(state, foreground, accent)) > 0 }
  function localOrSurfaceSpec(_surface, _key, color, fallback, width) { return flat(color || fallback, width) }
  function flat(color, width) { return ({ color: color, width: width }) }
}

pragma Singleton
import QtQuick

QtObject {
  function controlSpec(state, foreground, _accent) {
    return ({ color: foreground, width: state === "selected" ? 0 : 1 })
  }
  function none() { return ({width:0, color:"transparent"}) }
  function top(spec) { return spec ? spec.width : 0 }
  function bottom(spec) { return top(spec) }
  function left(spec) { return top(spec) }
  function right(spec) { return top(spec) }
  function localOrSurfaceSpec(_surface, _key, color, _fallback, width) { return flat(color,width) }
  function controlHasWidth(state, foreground, accent) { return top(controlSpec(state,foreground,accent)) > 0 }
  function flat(color, width) { return ({ color: color, width: width }) }
}

pragma Singleton
import QtQuick
import qs.Commons as Commons

QtObject {
  readonly property real cornerRadius: 2
  readonly property real normalBorderWidth: 1
  readonly property int focusBorderWidth: 1
  readonly property color normalBorderColor: normalBorderFor(Commons.Color.foreground, Commons.Color.accent)
  readonly property var font: ({
    family: "monospace", iconFamily: "monospace", title: 22, heading: 18, body: 12, bodySmall: 11, caption: 10,
    icon: 14, iconSmall: 11, iconLarge: 18
  })
  // Invariant: popup rows need the shell's nonzero height so pointer events
  // reach the menu instead of the controls underneath it.
  readonly property var spacing: ({
    controlPaddingX: 10, controlPaddingY: 6, inputPaddingY: 7, tooltipPaddingX:8, tooltipPaddingY:5, huge:24, labelGap:4, dropdownWidth:240, lg:8, numberFieldWidth:120,
    controlHeight: 28, controlGap: 8, sm: 3, md: 6, popupRowHeight: 28
  })

  // Invariant: match the shell's rounded scaling. At scale 7/6, space(4) is 5
  // and space(8) is 9; unrounded fixtures hide one-pixel layout errors.
  property real spacingScale: 1
  function space(value) {
    var scaledPixels = Number(value) * spacingScale
    return scaledPixels <= 0 ? 0 : Math.max(1, Math.round(scaledPixels))
  }
  function controlFill(_focused, _hot, _foreground, _accent) { return "transparent" }
  function focusFillFor(_foreground, accent) { return accent }
  function hoverStateColor(foreground, _accent) { return foreground }
  function hoverFillFor(_foreground, accent) { return accent }
  function selectedFillFor(_foreground, accent) { return accent }
  function selectedStateColor(foreground, _accent) { return foreground }
  function selectionFillFor(_foreground, accent) { return accent }
  function pressedFillFor(_foreground, accent) { return accent }
  function normalFillFor(_foreground, _accent) { return "transparent" }
  function normalBorderFor(foreground, _accent) { return foreground }
  function hoverBorderFor(_foreground, accent) { return accent }
}

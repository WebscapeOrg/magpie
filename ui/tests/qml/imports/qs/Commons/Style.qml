pragma Singleton
import QtQuick

QtObject {
  readonly property real cornerRadius: 2
  readonly property real normalBorderWidth: 1
  readonly property var font: ({
    family: "monospace", iconFamily: "monospace", title: 22, heading: 18, body: 14, bodySmall: 13, caption: 11,
    icon: 16, iconSmall: 14, iconLarge: 18
  })
  // Invariant: popup rows need the shell's nonzero height so pointer events
  // reach the menu instead of the controls underneath it.
  readonly property var spacing: ({
    controlPaddingX: 8, controlPaddingY: 5, inputPaddingY: 5, tooltipPaddingX:8, tooltipPaddingY:5, huge:24, labelGap:6, dropdownWidth:240, lg:8, numberFieldWidth:96,
    controlHeight: 30, controlGap: 6, sm: 3, md: 6, popupRowHeight: 28
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

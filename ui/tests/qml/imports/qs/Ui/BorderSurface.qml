import QtQuick

Rectangle {
  property var borderSpec: null
  property real padding: 0
  property real topPadding: padding
  property real rightPadding: padding
  property real bottomPadding: padding
  property real leftPadding: padding
  readonly property real borderTop: borderSpec && borderSpec.width ? borderSpec.width : 0
  readonly property real borderRight: borderTop
  readonly property real borderBottom: borderTop
  readonly property real borderLeft: borderTop
  readonly property real contentTopInset: topPadding + borderTop
  readonly property real contentRightInset: rightPadding + borderRight
  readonly property real contentBottomInset: bottomPadding + borderBottom
  readonly property real contentLeftInset: leftPadding + borderLeft
}

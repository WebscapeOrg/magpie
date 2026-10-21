import QtQuick
import qs.Ui
import "../settings"
import QtQuick.Controls
import qs.Commons

BorderSurface {
  id: root

  property string text: ""
  property string iconText: ""
  property string tooltipText: ""

  property bool selected: false
  property bool active: false
  property bool hasCursor: false
  property bool focusable: false
  property bool bordered: false

  property color foreground: Color.foreground
  property color background: "transparent"
  property color accent: Color.accent

  property string fontFamily: MailStyle.family
  property real fontSize: MailStyle.body
  property real iconSize: Style.font.icon
  property real iconRotation: 0
  property bool iconSpinning: false
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.controlPaddingY
  property bool leftAlign: false

  leftPadding: horizontalPadding
  rightPadding: horizontalPadding
  topPadding: verticalPadding
  bottomPadding: verticalPadding

  property color tooltipBackground: Color.tooltip.background
  property color tooltipForeground: Color.tooltip.text
  property color tooltipBorder: Color.tooltip.border

  signal clicked()
  signal rightClicked()
  signal hovered(bool isHovered)

  activeFocusOnTab: focusable
  Accessible.role: Accessible.Button
  Accessible.name: text || tooltipText
  Accessible.onPressAction: if (root.enabled) root.clicked()
  function acceptsActivation(event) {
    return root.enabled && root.activeFocus && root.focusable
      && (event.modifiers & ~Qt.KeypadModifier) === Qt.NoModifier
      && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)
  }
  Keys.onShortcutOverride: function(event) {
    if (root.acceptsActivation(event)) event.accepted = true
  }
  Keys.onPressed: function(event) {
    if (!root.acceptsActivation(event)) return
    event.accepted = true
    root.clicked()
  }

  // Invariant: reserve the largest possible border so hover and focus do not relayout neighboring
  // controls.
  implicitWidth: row.implicitWidth + horizontalPadding * 2 + _reservedBorderLeft + _reservedBorderRight
  implicitHeight: row.implicitHeight + verticalPadding * 2 + _reservedBorderTop + _reservedBorderBottom
  radius: Style.cornerRadius

  readonly property bool hot: mouseArea.containsMouse || hasCursor
  readonly property bool _showFocusRing: focusable && activeFocus
  readonly property color _selectedColor: Style.selectedStateColor(root.foreground, root.accent)
  readonly property var _tooltipBorderSpec: Border.localOrSurfaceSpec("tooltip", "border", root.tooltipBorder, Color.tooltip.border, Math.max(1, Style.normalBorderWidth))
  readonly property var _focusBorderSpec: Border.controlSpec("focus", root.foreground, root.accent)
  readonly property var _hoverBorderSpec: Border.controlSpec("hover-cursor", root.foreground, root.accent)
  readonly property var _selectedBorderSpec: Border.controlSpec("selected", root.foreground, root.accent)
  readonly property var _normalBorderSpec: Border.controlSpec("normal", root.foreground, root.accent)
  readonly property real _reservedBorderTop: Math.max(
    focusable ? Border.top(_focusBorderSpec) : 0,
    Border.top(_hoverBorderSpec),
    Border.top(_selectedBorderSpec),
    bordered ? Border.top(_normalBorderSpec) : 0)
  readonly property real _reservedBorderRight: Math.max(
    focusable ? Border.right(_focusBorderSpec) : 0,
    Border.right(_hoverBorderSpec),
    Border.right(_selectedBorderSpec),
    bordered ? Border.right(_normalBorderSpec) : 0)
  readonly property real _reservedBorderBottom: Math.max(
    focusable ? Border.bottom(_focusBorderSpec) : 0,
    Border.bottom(_hoverBorderSpec),
    Border.bottom(_selectedBorderSpec),
    bordered ? Border.bottom(_normalBorderSpec) : 0)
  readonly property real _reservedBorderLeft: Math.max(
    focusable ? Border.left(_focusBorderSpec) : 0,
    Border.left(_hoverBorderSpec),
    Border.left(_selectedBorderSpec),
    bordered ? Border.left(_normalBorderSpec) : 0)
  readonly property real _reservedContentLeftInset: _reservedBorderLeft + leftPadding
  readonly property var _borderSpec: _showFocusRing ? _focusBorderSpec
    : hot                      ? _hoverBorderSpec
    : selected                 ? (Border.controlHasWidth("selected") ? _selectedBorderSpec : (bordered ? _normalBorderSpec : Border.none()))
    : bordered                 ? _normalBorderSpec
    : Border.none()

  color: mouseArea.pressed ? Style.pressedFillFor(root.foreground, root.accent)
    : _showFocusRing       ? Style.focusFillFor(root.foreground, root.accent)
    : hot                  ? Style.hoverFillFor(root.foreground, root.accent)
    : selected             ? Style.selectedFillFor(root.foreground, root.accent)
    : active               ? Style.selectedFillFor(root.foreground, root.accent)
    : background

  borderSpec: _borderSpec

  Behavior on color { ColorAnimation { duration: 120 } }

  ToolTip {
    visible: root.tooltipText !== "" && (mouseArea.containsMouse || root.activeFocus)
    text: root.tooltipText
    delay: 400
    padding: 0
    background: BorderSurface {
      color: root.tooltipBackground
      borderSpec: root._tooltipBorderSpec
      radius: 0
    }
    contentItem: Text {
      textFormat: Text.PlainText
      text: root.tooltipText
      color: root.tooltipForeground
      font.family: root.fontFamily
      font.pixelSize: MailStyle.bodySmall
      leftPadding: Border.left(root._tooltipBorderSpec) + Style.spacing.controlPaddingX
      rightPadding: Border.right(root._tooltipBorderSpec) + Style.spacing.controlPaddingX
      topPadding: Border.top(root._tooltipBorderSpec) + Style.spacing.controlPaddingY
      bottomPadding: Border.bottom(root._tooltipBorderSpec) + Style.spacing.controlPaddingY
    }
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: root.leftAlign ? parent.left : undefined
    anchors.leftMargin: root.leftAlign ? root._reservedContentLeftInset : 0
    anchors.horizontalCenter: root.leftAlign ? undefined : parent.horizontalCenter
    spacing: Style.spacing.controlGap

    Text {

      textFormat: Text.PlainText
      visible: root.iconText !== ""
      text: root.iconText
      color: root.selected ? root._selectedColor : root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.iconSize
      rotation: root.iconSpinning ? 0 : root.iconRotation
      transformOrigin: Item.Center
      anchors.verticalCenter: parent.verticalCenter

      RotationAnimation on rotation {
        from: 0
        to: 360
        duration: 900
        loops: Animation.Infinite
        running: root.iconSpinning
      }
    }

    Text {

      textFormat: Text.PlainText
      visible: root.text !== ""
      text: root.text
      color: root.selected ? root._selectedColor : root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
      font.bold: root.selected
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(mouse) {
      if (root.focusable) root.forceActiveFocus()
      if (mouse.button === Qt.RightButton) root.rightClicked()
      else root.clicked()
    }
  }

  HoverHandler {
    onHoveredChanged: root.hovered(hovered)
  }
}

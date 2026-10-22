import QtQuick

Item {
  property QtObject bar: null
  property Component iconComponent: null
  property string tooltipText: ""
  property real slotSize: 24
  property real opticalSize: 20
  implicitWidth: slotSize
  implicitHeight: slotSize
  // Invariant: The shell button signal carries its mouse button; a parameterless fake would hide primary versus secondary routing failures.
  property bool active: false
  property color foreground: Qt.rgba(1, 1, 1, 1)
  signal pressed(int button)
  signal wheelMoved(int delta)
}

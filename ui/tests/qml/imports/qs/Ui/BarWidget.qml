import QtQuick

// Invariant: The shell BarWidget shim must not invent barForeground; doing so hides the real foreground binding failure.
Item {
  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: 32
}

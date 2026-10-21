import QtQuick

// Invariant: header controls retain pointer priority; native system movement must not retain a QML
// pointer grab.
MouseArea {
  id: root
  required property var nativeWindow
  objectName: "app-title-bar-drag-area"
  acceptedButtons: Qt.NoButton
  hoverEnabled: false
  readonly property bool dragsTheWindow: windowMoveHandler.target === null

  DragHandler {
    id: windowMoveHandler
    enabled: root.enabled
    target: null
    dragThreshold: 0
    acceptedButtons: Qt.LeftButton
    onActiveChanged: {
      if (active && root.nativeWindow) root.nativeWindow.startSystemMove()
    }
  }
}

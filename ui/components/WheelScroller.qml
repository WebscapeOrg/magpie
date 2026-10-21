import QtQuick
import "../account/Model.js" as Model

// Invariant: attach the handler directly to the Flickable; visual children would be reparented into
// scrolling content and miss wheel events.
WheelHandler {
  id: root

  required property Flickable view

  blocking: true
  grabPermissions: PointerHandler.CanTakeOverFromAnything
  acceptedDevices: PointerDevice.AllDevices
  orientation: Qt.Vertical

  onWheel: function(event) {
    if (!root.view) return
    root.view.contentY = Model.wheelScrollByPixels(root.view.contentY,
      Model.wheelPixels(event.angleDelta.y, event.pixelDelta.y),
      root.view.contentHeight, root.view.height,
      root.view.originY, root.view.topMargin, root.view.bottomMargin)
    // Invariant: cancel an active drag flick before applying wheel motion so its deceleration
    // cannot fight the new position.
    root.view.cancelFlick()
  }
}

import QtQuick

Item {
  id: root
  visible: false
  width: 0
  height: 0

  property var callbacks: []

  function call(callback) {
    if (typeof callback !== "function" || callbacks.indexOf(callback) >= 0) return
    callbacks = callbacks.concat([callback])
    if (!timer.running) timer.start()
  }

  Timer {
    id: timer
    interval: 0
    onTriggered: {
      var pending = root.callbacks
      root.callbacks = []
      for (var index = 0; index < pending.length; index++) {
        try { pending[index]() }
        catch (error) { console.warn("Deferred provider callback failed") }
      }
    }
  }
}

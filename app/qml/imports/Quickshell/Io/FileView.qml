import QtQuick
import Quickshell

QtObject {
  id: root

  property string path: ""
  property bool watchChanges: false
  property bool printErrors: false
  property bool atomicWrites: false
  property var store: Quickshell.fileStore
  property string _text: ""
  property string _watchedPath: ""
  property var _watchedStore: null
  // Invariant: synchronous operations report through their result; the store
  // also emits failed, which must not report the same failure twice.
  property bool _requestActive: false

  signal loaded()
  signal fileChanged()
  signal loadFailed()

  function report(error) {
    if (printErrors && String(error || "") !== "") console.warn(String(error))
  }

  function updateWatch() {
    releaseWatch()
    if (!store || typeof store.watch !== "function" || !watchChanges || path === "") return
    _watchedStore = store
    _watchedPath = path
    _watchedStore.watch(_watchedPath, true)
  }

  function releaseWatch() {
    if (_watchedStore && _watchedPath !== "") _watchedStore.watch(_watchedPath, false)
    _watchedStore = null
    _watchedPath = ""
  }

  function reload() {
    if (!store || typeof store.read !== "function" || path === "") {
      loadFailed()
      return
    }
    _requestActive = true
    var result = store.read(path) || ({})
    _requestActive = false
    if (!result.ok) {
      report(result.error)
      loadFailed()
      return
    }
    _text = String(result.text || "")
    loaded()
  }

  function text() { return _text }

  function setText(value) {
    _text = String(value || "")
    if (!store || typeof store.write !== "function" || path === "") {
      loadFailed()
      return
    }
    _requestActive = true
    var result = store.write(path, _text, atomicWrites) || ({})
    _requestActive = false
    if (!result.ok) {
      report(result.error)
      loadFailed()
    }
  }

  onPathChanged: {
    updateWatch()
    reload()
  }
  onWatchChangesChanged: updateWatch()
  onStoreChanged: {
    updateWatch()
    reload()
  }

  property Connections storeConnections: Connections {
    target: root.store
    ignoreUnknownSignals: true
    function onChanged(changedPath) {
      if (String(changedPath) === root.path) root.fileChanged()
    }
    function onFailed(failedPath, error) {
      if (root._requestActive || String(failedPath) !== root.path) return
      root.report(error)
      root.loadFailed()
    }
  }

  Component.onCompleted: {
    updateWatch()
    reload()
  }
  Component.onDestruction: releaseWatch()
}

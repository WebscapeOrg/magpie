import QtQuick

QtObject {
  property string path: ""
  property bool watchChanges: false
  property bool printErrors: false
  property bool atomicWrites: false
  signal loaded()
  signal fileChanged()
  signal loadFailed(int error)

  function reload() {}
  property string contents: ""
  function text() { return contents }
  function setText(_value) {}
}

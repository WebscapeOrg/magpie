import QtQuick
import QtTest
import "../../components" as Components

TestCase {
  id: testCase
  name: "ComposeGeometry"
  when: windowShown
  width: 900
  height: 600
  visible: true
  Component {
    id: composeComponent
    Components.ComposeView {
      width: 900
      height: 600
      service: null
      opened: true
      textColor: Qt.rgba(1, 1, 1, 1)
      backgroundColor: Qt.rgba(0.06, 0.06, 0.06, 1)
      accentColor: Qt.rgba(1, 0.5, 0, 1)
      dimColor: Qt.rgba(0.6, 0.6, 0.6, 1)
      dimmerColor: Qt.rgba(0.4, 0.4, 0.4, 1)
      popupBackgroundColor: Qt.rgba(0.06, 0.06, 0.06, 1)
      popupBorderColor: Qt.rgba(0.4, 0.4, 0.4, 1)
      panelFontFamily: "monospace"
    }
  }
  function test_body_tracks_small_and_large_viewports_without_binding_loops() {
    failOnWarning(/Binding loop detected/)
    var compose = createTemporaryObject(composeComponent, testCase, {width: 0, height: 0})
    verify(compose)
    var editor = findChild(compose, "compose-body-editor")
    var viewport = findChild(compose, "compose-body")
    for (var dimensions of [[900,600], [0,0], [360,200], [900,600]]) {
      compose.width = dimensions[0]
      compose.height = dimensions[1]
      editor.text = "Line one\nLine two\nLine three"
      wait(0)
      verify(editor.height >= viewport.height)
      verify(editor.height >= editor.contentHeight)
    }
    mouseClick(editor, 5, 5)
    verify(editor.activeFocus)
  }
}

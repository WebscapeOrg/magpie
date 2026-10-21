import QtQuick
import QtTest
import "../../components" as Components

TestCase {
  id: testCase
  name: "MessageListGeometry"
  when: windowShown
  width: 600
  height: 400
  QtObject {
    id: mail
    property var messages: []
    property bool listLoaded: true
    property bool hasMore: false
    property bool listLoading: false
  }
  Component {
    id: listComponent
    Components.MessageList {
      service: mail
      height: 200
      textColor: Qt.rgba(1, 1, 1, 1)
      accentColor: Qt.rgba(1, 0.5, 0, 1)
      dimColor: Qt.rgba(0.6, 0.6, 0.6, 1)
      urgentColor: Qt.rgba(1, 0.2, 0.2, 1)
      panelFontFamily: "monospace"
    }
  }
  function test_transient_negative_height_keeps_a_valid_cache_buffer() {
    var list = createTemporaryObject(listComponent, testCase)
    verify(list)
    compare(list.cacheBuffer, 200)
    failOnWarning(/Cannot set a negative cache buffer/)
    list.height = -20
    compare(list.cacheBuffer, 0)
    list.height = 300
    compare(list.cacheBuffer, 300)
  }
}

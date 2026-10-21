import QtQuick
import QtTest
import "../../components" as Components

Rectangle {
  id: host
  color: "white"
  width: 180
  height: 140
  Components.MagpieLogo {
    id: logo
    anchors.centerIn: parent
    foreground: Qt.rgba(0.6,0.6,0.6,1)
    accent: Qt.rgba(0.9,0.25,0.25,1)
  }
  TestCase {
    name: "MagpieLogo"
    when: windowShown
    function test_ink_uses_the_supplied_foreground() {
      logo.foreground = Qt.rgba(0.1, 0.2, 0.3, 1)
      wait(50)
      var rendered = grabImage(logo)
      var x = Math.floor(logo.width * 39 / 64)
      var y = Math.floor(logo.height * 24 / 64)
      verify(Math.abs(rendered.red(x, y) - 26) <= 1)
      verify(Math.abs(rendered.green(x, y) - 51) <= 1)
      verify(Math.abs(rendered.blue(x, y) - 77) <= 1)
      logo.foreground = Qt.rgba(0.8, 0.9, 1, 1)
      wait(50)
      rendered = grabImage(logo)
      verify(Math.abs(rendered.red(x, y) - 204) <= 1)
    }
    function test_identity_is_static_and_labeled() {
      compare(logo.animated, false)
      compare(logo.Accessible.name, "Magpie")
      verify(String(logo.children[0].source).endsWith("magpie.svg"), "identity uses the monochrome vector asset")
      verify(logo.width > 0 && logo.height > 0)
    }
  }
}

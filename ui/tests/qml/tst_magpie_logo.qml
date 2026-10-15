import QtQuick
import QtTest
import "../../components" as Components

Item {
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
    function test_identity_is_static_and_labeled() {
      compare(logo.animated, false)
      compare(logo.Accessible.name, "Magpie")
      verify(String(logo.children[0].source).endsWith("magpie.svg"), "identity uses the monochrome vector asset")
      verify(logo.width > 0 && logo.height > 0)
    }
  }
}

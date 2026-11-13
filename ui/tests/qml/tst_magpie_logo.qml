import QtQuick
import QtTest
import qs.Commons
import qs.Commons as Commons
import "../../components" as Components

Rectangle {
  id: host
  color: Commons.Color.background
  width: 180
  height: 140
  Components.MagpieLogo {
    id: logo
    anchors.centerIn: parent
  }
  TestCase {
    name: "MagpieLogo"
    when: windowShown
    function test_identity_is_apples_envelope_and_labeled() {
      tryCompare(logo.image, "status", Image.Ready)
      compare(logo.Accessible.name, "Magpie Mail")
      verify(String(logo.image.source).endsWith("magpie-mail.png"), "identity uses Apple's ✉️ drawing")
      compare(logo.image.sourceSize.width, 160)
      verify(logo.width > 0 && logo.height > 0)
    }
    function test_it_draws_the_envelope_in_its_own_colours() {
      tryCompare(logo.image, "status", Image.Ready)
      var rendered = grabImage(logo)
      var x = Math.floor(logo.width / 2), y = Math.floor(logo.height / 2)
      verify(rendered.red(x, y) > 200 && rendered.green(x, y) > 200 && rendered.blue(x, y) > 200, "the envelope's middle is near white, not tinted by the theme")
    }
  }
}

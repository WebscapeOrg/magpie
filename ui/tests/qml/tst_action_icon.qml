import QtQuick
import QtTest
import "../../components" as Components
import "../../components/Icons.js" as Icons

Rectangle {
  id: stage
  width: 160
  height: 160
  color: Qt.rgba(0, 0, 0, 1)

  Component {
    id: iconComponent
    Components.ActionIcon { iconSize: 48; color: Qt.rgba(1, 1, 1, 1) }
  }

  TestCase {
    name: "ActionIcon"
    when: windowShown

    function ink(image) {
      var count = 0
      for (var y = 0; y < image.height; y++)
        for (var x = 0; x < image.width; x++)
          if (image.red(x, y) > 0) count++
      return count
    }

    function test_bundled_icons_render_data() {
      return Icons.names().map(function(name) { return {tag: name, name: name} })
    }

    function test_bundled_icons_render(data) {
      var icon = createTemporaryObject(iconComponent, stage, {name: data.name})
      verify(icon)
      waitForRendering(icon)
      verify(ink(grabImage(icon)) > 0, data.name + " renders without an icon font")
    }

    function test_selected_star_and_theme_change_pixels() {
      var icon = createTemporaryObject(iconComponent, stage, {name: "star"})
      waitForRendering(icon)
      var outline = ink(grabImage(icon))
      icon.filled = true
      waitForRendering(icon)
      verify(ink(grabImage(icon)) > outline, "the selected star fills its outline")
      icon.color = "transparent"
      waitForRendering(icon)
      compare(ink(grabImage(icon)), 0, "transparent theme colors stay transparent")
    }

    function test_unknown_name_renders_nothing() {
      var icon = createTemporaryObject(iconComponent, stage, {name: "https://example.org/icon.svg"})
      waitForRendering(icon)
      compare(ink(grabImage(icon)), 0)
      compare(icon.imageSource, "")
    }
  }
}

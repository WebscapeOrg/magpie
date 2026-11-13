import QtQuick 2.15
import QtTest 1.3
import QtQuick.Window
import "../../components" as Components

Item {
  width: 400
  height: 300

  Loader {
    id: popoverLoader
    anchors.fill: parent
    Component.onCompleted: setSource("../../components/ImagePopover.qml", ({
      textColor: Qt.rgba(1, 1, 1, 1),
      dimColor: Qt.rgba(0.67, 0.67, 0.67, 1),
      popupBackgroundColor: Qt.rgba(0.13, 0.13, 0.13, 1),
      popupBorderColor: Qt.rgba(0.47, 0.47, 0.47, 1),
      panelFontFamily: "monospace"
    }))
  }

  Components.SenderAvatar {
    id: avatar
    width: 40
    height: 40
    sender: ({display: "Synthetic Sender"})
    foreground: Qt.rgba(1, 1, 1, 1)
    accent: Qt.rgba(0.7, 0.8, 0.9, 1)
    fontFamily: "monospace"
  }

  TestCase {
    name: "ImagePopover"
    when: windowShown

    function popover() {
      tryVerify(function() { return popoverLoader.status === Loader.Ready }, 1000)
      return popoverLoader.item
    }

    function test_avatar_retains_only_the_pixels_needed_for_its_display() {
      avatar.imageData = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAHgAAAB4CAIAAAC2BqGFAAAA60lEQVR4nO3QAQkAIADAMPuZyRrmtYXCHTzA2Zhr60Lj+cEngQbdCjToVqBBtwINuhVo0K1Ag24FGnQr0KBbgQbdCjToVqBBtwINuhVo0K1Ag24FGnQr0KBbgQbdCjToVqBBtwINuhVo0K1Ag24FGnQr0KBbgQbdCjToVqBBtwINuhVo0K1Ag24FGnQr0KBbgQbdCjToVqBBtwINuhVo0K1Ag24FGnQr0KBbgQbdCjToVqBBtwINuhVo0K1Ag24FGnQr0KBbgQbdCjToVqBBtwINuhVo0K1Ag24FGnQr0KBbgQbdCjToVqBBtzqYOOv1wt5mmgAAAABJRU5ErkJggg=="
      var picture = findChild(avatar, "sender-avatar-image")
      tryCompare(picture, "status", Image.Ready)
      compare(picture.sourceSize.width, Math.ceil(avatar.width * Screen.devicePixelRatio))
      compare(picture.sourceSize.height, Math.ceil(avatar.height * Screen.devicePixelRatio))
      compare(picture.width, avatar.width)
      compare(picture.height, avatar.height)
    }

    function test_a_remote_url_is_not_an_image_source() {
      var sheet = popover()
      sheet.show("https://cdn.example.com/a.png")
      compare(sheet.source, "", "Qt must not be handed a remote image URL")
      compare(sheet.refused, true)
      compare(sheet.requested, "https://cdn.example.com/a.png")
    }

    function test_prepared_raster_bytes_are_shown() {
      var sheet = popover()
      var data = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
      sheet.showPrepared("https://cdn.example.com/a.png", data)
      compare(sheet.source, data)
      compare(sheet.refused, false)
    }

    function test_svg_data_is_not_a_picture() {
      var sheet = popover()
      sheet.show("data:image/svg+xml;base64,AAA")
      compare(sheet.source, "")
      compare(sheet.refused, true)
    }

    function test_svg_disguised_as_png_is_not_a_picture() {
      var data = "data:image/png;base64,PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnPjwvU3ZnPg=="
      var sheet = popover()
      sheet.show(data)
      compare(sheet.source, "")
      compare(sheet.refused, true)
    }
  }
}

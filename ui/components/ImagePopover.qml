import QtQuick
import "../settings"
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "../message/Html.js" as Html

Item {
  id: root

  required property color textColor
  required property color dimColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  property string source: ""
  property string requested: ""
  // Invariant: Qt fetches Image sources directly; accept only prepared raster data, never a sender
  // URL.
  property bool refused: false

  anchors.fill: parent
  z: 60

  function show(url) {
    showPrepared(url, url)
  }

  function showPrepared(requestedUrl, prepared) {
    var wanted = String(requestedUrl || "")
    if (wanted === "") return
    requested = wanted
    var data = String(prepared || "")
    refused = !Html.isRasterDataImage(data)
    source = refused ? "" : data
    sheet.open()
  }

  function close() { sheet.close() }

  QQC.Popup {
    id: sheet
    parent: root
    modal: true
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    padding: MailStyle.space(8)
    x: Math.round((root.width - width) / 2)
    y: Math.round((root.height - height) / 2)
    width: frame.implicitWidth + padding * 2
    height: frame.implicitHeight + padding * 2

    onClosed: {
      root.source = ""
      root.requested = ""
      root.refused = false
    }

    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }

    Column {
      id: frame
      spacing: MailStyle.space(6)

      // Invariant: bound the image against the window, not the popup sized from that image.
      Image {
        id: picture
        source: root.source
        asynchronous: true
        cache: false
        fillMode: Image.PreserveAspectFit
        width: Math.max(MailStyle.space(120),
          Math.min(implicitWidth, root.width - MailStyle.space(80)))
        height: status === Image.Ready
          ? Math.min(implicitHeight, root.height - MailStyle.space(120))
          : MailStyle.space(120)

        Text {
          anchors.centerIn: parent
          width: picture.width - MailStyle.space(20)
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          visible: root.refused || picture.status !== Image.Ready
          text: root.refused
            ? "That image is not a picture this can show"
            : (picture.status === Image.Error ? "That image could not be loaded" : "Loading")
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
        }
      }

      Text {
        width: picture.width
        text: root.requested
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        // Invariant: sender-controlled source labels must remain plain text to prevent Qt resource
        // loading.
        textFormat: Text.PlainText
        elide: Text.ElideMiddle
      }
    }
  }
}

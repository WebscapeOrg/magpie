import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import "../message/AttachmentPreview.js" as Preview
import "../message/Message.js" as Mail

Widgets.Button {
  id: root
  objectName: "attachment-open-button"

  property var attachment: null
  required property color textColor
  required property color dimColor
  required property color dimmerColor
  required property string panelFontFamily
  property bool saving: false
  property string previewSource: ""
  property string previewState: ""
  property bool previewActive: false
  readonly property bool controlFocused: activeFocus || saveButton.activeFocus
  readonly property string filename: String(attachment && attachment.filename || "attachment")
  readonly property string fileLabel: Preview.fileLabel(attachment)
  readonly property real detailsHeight: Math.max(sizeLabel.implicitHeight, saveButton.height)
  readonly property real previewHeight: Math.max(0, height - filenameLabel.implicitHeight
    - detailsHeight - MailStyle.space(16))

  signal openRequested(var attachment)
  signal saveRequested(var attachment)
  signal previewRequested()

  function requestPreview() {
    if (previewActive && previewState === "" && Preview.supported(attachment)) previewRequested()
  }
  onPreviewActiveChanged: { if (previewActive) previewDelay.restart(); else previewDelay.stop() }
  onAttachmentChanged: previewDelay.restart()
  onPreviewStateChanged: if (previewState === "") previewDelay.restart()
  Component.onCompleted: previewDelay.restart()
  Timer { id: previewDelay; interval: 75; onTriggered: root.requestPreview() }

  implicitWidth: MailStyle.space(180)
  implicitHeight: MailStyle.space(112)
  foreground: root.textColor
  fontFamily: root.panelFontFamily
  horizontalPadding: 0
  verticalPadding: 0
  bordered: true
  focusable: true
  Accessible.role: Accessible.Button
  Accessible.name: "Open attachment " + filename
  Accessible.description: fileLabel + ", " + Mail.formatSize(attachment ? attachment.size : 0)
  Keys.onShortcutOverride: function(event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)
      event.accepted = true
  }
  Accessible.onPressAction: root.openRequested(root.attachment)
  tooltipText: filename + (previewState === "unavailable" ? " · Preview unavailable" : "")
  onClicked: root.openRequested(root.attachment)

  Item {
    id: preview
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: MailStyle.space(6)
    height: root.previewHeight
    clip: true

    Image {
      id: picture
      objectName: "attachment-thumbnail"
      anchors.fill: parent
      source: Preview.rasterSource(root.previewSource)
      sourceSize.width: 384
      sourceSize.height: 384
      fillMode: Image.PreserveAspectFit
      smooth: true
      mipmap: true
      asynchronous: true
      cache: false
      Accessible.ignored: true
    }

    Row {
      anchors.centerIn: parent
      spacing: MailStyle.space(6)
      visible: picture.status !== Image.Ready
      ActionIcon {
        anchors.verticalCenter: parent.verticalCenter
        name: "attachment"
        iconSize: Math.min(MailStyle.space(24), preview.height)
        color: root.dimColor
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.fileLabel
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        color: root.dimColor
      }
    }
  }

  Text {
    id: filenameLabel
    objectName: "attachment-filename"
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: details.top
    anchors.leftMargin: MailStyle.space(6)
    anchors.rightMargin: MailStyle.space(6)
    textFormat: Text.PlainText
    text: root.filename
    elide: Text.ElideMiddle
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
  }

  Item {
    id: details
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: MailStyle.space(4)
    height: root.detailsHeight

    Text {
      id: sizeLabel
      anchors.left: parent.left
      anchors.right: saveButton.left
      anchors.leftMargin: MailStyle.space(2)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.previewState === "loading" ? "Loading preview"
        : root.fileLabel + " · " + Mail.formatSize(root.attachment ? root.attachment.size : 0)
      elide: Text.ElideRight
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
    }

    IconButton {
      id: saveButton
      objectName: "attachment-save-button"
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      size: Math.max(Style.spacing.controlHeight, MailStyle.space(24))
      iconName: "download"
      iconSize: Style.font.iconSmall
      tooltipText: root.saving ? "Saving" : "Save " + root.filename + " to Downloads"
      foreground: root.dimColor
      hoverColor: root.textColor
      busy: root.saving
      onClicked: if (!root.saving) root.saveRequested(root.attachment)
    }
  }
}

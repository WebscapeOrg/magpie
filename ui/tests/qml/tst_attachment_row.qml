import QtQuick 2.15
import QtTest 1.3

Item {
  width: 500
  height: 240

  Loader {
    id: attachmentLoader
    anchors.left: parent.left
    anchors.right: parent.right
    Component.onCompleted: setSource("../../components/AttachmentCard.qml", ({
      textColor: Qt.rgba(1, 1, 1, 1),
      dimColor: Qt.rgba(0.67, 0.67, 0.67, 1),
      dimmerColor: Qt.rgba(0.47, 0.47, 0.47, 1),
      panelFontFamily: "monospace"
    }))
    onLoaded: {
      item.attachment = ({
        filename: "Quarterly report.pdf",
        mimeType: "application/pdf",
        size: 1536,
        attachmentId: "att-7"
      })
    }
  }

  SignalSpy {
    id: openSpy
    target: attachmentLoader.item
    signalName: "openRequested"
  }

  TestCase {
    name: "AttachmentCard"
    when: windowShown

    function test_filename_opens_the_listed_attachment() {
      tryCompare(attachmentLoader, "status", Loader.Ready)
      var link = attachmentLoader.item
      compare(link.objectName, "attachment-open-button",
        "the attachment filename must be an identifiable control")

      openSpy.clear()
      mouseClick(link, link.width / 2, link.height / 2)
      compare(openSpy.count, 1)
      compare(openSpy.signalArguments[0][0].attachmentId, "att-7")
    }
  }
}

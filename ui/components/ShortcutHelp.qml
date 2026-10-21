import QtQuick
import "../settings"
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../keys/Keymap.js" as Keymap
import "../account/Model.js" as Model

Rectangle {
  id: root

  required property color textColor
  required property color backgroundColor
  required property color dimColor
  required property string panelFontFamily
  property var hiddenBindings: []

  signal dismissed()

  function scrollBy(steps) {
    if (!scroller.interactive) return
    scroller.contentY = Model.clampContentY(
      scroller.contentY + steps * MailStyle.space(20),
      Model.contentYBounds(scroller.originY, scroller.contentHeight,
        scroller.height, scroller.topMargin, scroller.bottomMargin))
  }

  readonly property real columnWidth: MailStyle.space(330)
  readonly property int columnCount: Math.max(1, Math.min(3,
    Math.floor((width - MailStyle.space(60)) / columnWidth)))

  readonly property var columns: Keymap.helpColumns(columnCount, hiddenBindings)

  color: Qt.rgba(backgroundColor.r, backgroundColor.g, backgroundColor.b, 0.96)

  MouseArea {
    anchors.fill: parent
    onClicked: root.dismissed()
  }

  Flickable {
    id: scroller

    WheelScroller { view: scroller }
    // Invariant: the Flickable fills the sheet so its scrollbar stays at the window edge, not an
    // interior column.
    anchors.fill: parent
    anchors.margins: MailStyle.space(20)
    contentWidth: width
    contentHeight: holder.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    // Invariant: a Flickable consumes presses; distinguish a dismissing tap from a scrolling drag.
    TapHandler {
      onTapped: root.dismissed()
    }

    // Invariant: a Flickable reparents children; center the sheet against a stable holder width
    // after reparenting.
    Item {
      id: holder
      width: scroller.width
      implicitHeight: Math.max(column.implicitHeight, scroller.height)

      Column {
        id: column
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(scroller.width,
          root.columnCount * root.columnWidth + (root.columnCount - 1) * MailStyle.space(28))
        spacing: MailStyle.space(6)

        Text {
          text: "Keyboard shortcuts"
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.subtitle
          font.bold: true
        }

        Item {
          width: parent.width
          implicitHeight: MailStyle.space(6)
        }

        Row {
          width: parent.width
          spacing: MailStyle.space(28)

          Repeater {
            model: root.columns

            Column {
              id: sheetColumn
              required property var modelData
              width: (column.width - (root.columnCount - 1) * MailStyle.space(28))
                / root.columnCount
              spacing: MailStyle.space(6)

              Repeater {
                model: sheetColumn.modelData

                Column {
                  id: group
                  required property var modelData
                  width: sheetColumn.width
                  spacing: MailStyle.space(6)

                  Item {
                    width: parent.width
                    implicitHeight: MailStyle.space(8)
                  }

                  Text {
                    text: group.modelData.name
                    textFormat: Text.PlainText
                    color: root.dimColor
                    font.family: root.panelFontFamily
                    font.pixelSize: MailStyle.caption
                    font.bold: true
                  }

                  Repeater {
                    model: group.modelData.rows

                    Item {
                      required property var modelData
                      width: group.width
                      implicitHeight: MailStyle.space(20)

                      Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.round(parent.width * 0.54)
                        text: Keymap.keycapLabel(modelData.keys)
                        color: root.textColor
                        font.family: root.panelFontFamily
                        font.pixelSize: MailStyle.caption
                        elide: Text.ElideRight
                      }

                      Text {
                        anchors.left: parent.left
                        anchors.leftMargin: Math.round(parent.width * 0.54) + MailStyle.space(5)
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.action
                        color: root.dimColor
                        font.family: root.panelFontFamily
                        font.pixelSize: MailStyle.caption
                        elide: Text.ElideRight
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

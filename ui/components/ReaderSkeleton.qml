import QtQuick
import "../settings"
import qs.Commons
import qs.Ui

Item {
  id: root

  required property color textColor
  required property string panelFontFamily

  // Performance: one animation drives all bars rather than adding one GUI-thread timer per bar.
  property real pulse: 0.5

  SequentialAnimation on pulse {
    running: root.visible
    loops: Animation.Infinite
    NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
    NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
  }

  Column {
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: MailStyle.space(14)
    spacing: MailStyle.space(8)

    Bar { widthFactor: 0.82; barHeight: MailStyle.space(13) }
    Bar { widthFactor: 0.46; barHeight: MailStyle.space(13) }

    Item { width: 1; height: MailStyle.space(4) }

    Bar { widthFactor: 0.38; barHeight: MailStyle.space(9) }
    Bar { widthFactor: 0.52; barHeight: MailStyle.space(8) }

    Item { width: 1; height: MailStyle.space(10) }

    PanelSeparator {
      width: parent.width
      foreground: root.textColor
    }

    Item { width: 1; height: MailStyle.space(6) }

    Repeater {
      model: [0.96, 0.99, 0.72, 0.0, 0.94, 0.88, 0.97, 0.54, 0.0, 0.92, 0.63]

      Item {
        required property var modelData
        width: parent.width
        implicitHeight: modelData === 0.0 ? MailStyle.space(10) : MailStyle.space(15)

        Bar {
          visible: modelData !== 0.0
          widthFactor: modelData
          barHeight: MailStyle.space(8)
        }
      }
    }
  }

  component Bar: Rectangle {
    property real widthFactor: 1.0
    property real barHeight: MailStyle.space(8)

    width: Math.max(1, parent.width * widthFactor)
    height: barHeight
    radius: Style.cornerRadius
    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b,
      0.06 + 0.05 * root.pulse)
  }
}

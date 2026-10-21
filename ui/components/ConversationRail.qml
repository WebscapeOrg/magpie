import QtQuick
import "../settings"
import QtQuick.Controls
import qs.Commons
import "../account/Model.js" as Model

Item {
  id: root

  required property var stops
  required property string caption
  required property color textColor
  required property color backgroundColor
  required property color accentColor
  required property color dimColor
  required property color dimmerColor
  required property string panelFontFamily

  signal memberActivated(string id)
  signal memberMenuRequested(string id, real sceneX, real sceneY)

  implicitWidth: MailStyle.space(200)

  // Performance: one animation drives all skeletons instead of creating one timer per bar.
  property real pulse: 0.5

  SequentialAnimation on pulse {
    running: root.visible && root.hasSkeleton
    loops: Animation.Infinite
    NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
    NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
  }

  readonly property bool hasSkeleton: {
    var list = root.stops || []
    for (var i = 0; i < list.length; i++) {
      if (!list[i].known) return true
    }
    return false
  }

  function boundsFor(id) {
    var wanted = String(id || "")
    for (var i = 0; i < stopColumn.children.length; i++) {
      var stop = stopColumn.children[i]
      if (!stop || stop.memberId !== wanted) continue
      return {
        y: stop.y, height: stop.height,
        node: { top: stop.y + stop.nodeTop, bottom: stop.y + stop.nodeBottom,
          centerX: stop.axis },
        line: { top: stop.y + stop.lineTop, bottom: stop.y + stop.lineBottom,
          x: stop.lineX, width: stop.lineWidth }
      }
    }
    return null
  }

  function reveal(id) {
    var bounds = boundsFor(id)
    if (!bounds) return
    railFlick.contentY = Model.contentYToReveal(railFlick.contentY, railFlick.height,
      bounds.y, bounds.height, railFlick.contentHeight, MailStyle.space(8))
  }

  Rectangle {
    id: edge
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: 1
    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.12)
  }

  Text {
    id: captionText
    objectName: "railCaption"
    anchors.top: parent.top
    anchors.left: edge.right
    anchors.right: parent.right
    anchors.leftMargin: MailStyle.space(12)
    anchors.rightMargin: MailStyle.space(10)
    anchors.topMargin: MailStyle.space(14)
    textFormat: Text.PlainText
    text: root.caption
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    elide: Text.ElideRight
  }

  Flickable {
    id: railFlick
    objectName: "conversationRailFlick"
    anchors.top: captionText.bottom
    anchors.topMargin: MailStyle.space(8)
    anchors.left: edge.right
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    contentWidth: width
    contentHeight: stopColumn.implicitHeight + MailStyle.space(16)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: stopColumn
      width: railFlick.width
      spacing: 0

      Repeater {
        model: root.stops

        Stop {}
      }
    }
  }

  component Stop: Rectangle {
    id: stop

    required property var modelData
    required property int index
    readonly property string memberId: String(modelData.id || "")
    readonly property bool first: index === 0
    readonly property bool last: index === (root.stops || []).length - 1
    readonly property real nodeTop: node.y
    readonly property real nodeBottom: node.y + node.height
    readonly property real lineTop: first ? nodeBottom : 0
    readonly property real lineBottom: last ? nodeTop : height
    // Invariant: every stop shares one pixel-aligned axis, including larger selected nodes, so
    // timeline segments remain continuous.
    readonly property real axis: MailStyle.space(10) + MailStyle.space(11) / 2
    readonly property real lineWidth: Math.max(1, MailStyle.space(1))
    readonly property real lineX: Math.round(axis - lineWidth / 2)

    width: stopColumn.width
    implicitHeight: stopBody.implicitHeight + MailStyle.space(14)
    height: implicitHeight
    radius: Style.cornerRadius
    color: modelData.open
      ? Style.selectedFillFor(root.textColor, root.accentColor)
      : (hover.containsMouse
        ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent")

    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(event) {
        if (event.button === Qt.RightButton) {
          var scene = mapToGlobal(event.x, event.y)
          root.memberMenuRequested(stop.memberId, scene.x, scene.y)
        } else {
          root.memberActivated(stop.memberId)
        }
      }
    }

    Rectangle {
      id: segment
      objectName: "rail-segment"
      x: stop.lineX
      y: stop.lineTop
      width: stop.lineWidth
      height: Math.max(0, stop.lineBottom - stop.lineTop)
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.14)
    }

    Rectangle {
      id: node
      x: stop.axis - width / 2
      y: MailStyle.space(13)
      width: modelData.open ? MailStyle.space(11) : MailStyle.space(9)
      height: width
      radius: width / 2
      color: modelData.unread ? root.accentColor : root.backgroundColor
      border.width: modelData.unread ? 0 : Math.max(1, MailStyle.space(modelData.open ? 2 : 1))
      border.color: modelData.open ? root.textColor : root.dimColor
    }

    Column {
      id: stopBody
      anchors.left: parent.left
      anchors.leftMargin: node.x + MailStyle.space(22)
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)

      Item {
        width: parent.width
        implicitHeight: Math.max(dateText.implicitHeight, flagIcon.height,
          mailboxText.implicitHeight, dateBar.visible ? dateBar.height : 0)

        Text {
          id: dateText
          visible: stop.modelData.known
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: stop.modelData.time
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
        }

        Bar {
          id: dateBar
          visible: !stop.modelData.known
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(1, parent.width * 0.34)
          height: MailStyle.space(8)
        }

        ActionIcon {
          id: flagIcon
          visible: stop.modelData.flagged
          anchors.left: stop.modelData.known ? dateText.right : dateBar.right
          anchors.leftMargin: MailStyle.space(5)
          anchors.verticalCenter: parent.verticalCenter
          name: "star"
          filled: true
          color: root.accentColor
          iconSize: Style.font.iconSmall
          fontFamily: root.panelFontFamily
        }

        Text {
          id: mailboxText
          visible: stop.modelData.mailbox !== ""
          anchors.left: flagIcon.visible ? flagIcon.right
            : (stop.modelData.known ? dateText.right : dateBar.right)
          anchors.leftMargin: MailStyle.space(8)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: stop.modelData.mailbox
          color: root.dimmerColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          elide: Text.ElideRight
        }
      }

      Item {
        width: parent.width
        implicitHeight: Math.max(sender.implicitHeight, senderBar.visible ? senderBar.height : 0)

        Text {
          id: sender
          visible: stop.modelData.known
          anchors.left: parent.left
          anchors.right: openMark.visible ? openMark.left : parent.right
          anchors.rightMargin: openMark.visible ? MailStyle.space(5) : 0
          // Invariant: sender names must remain plain text to prevent Qt resource loading.
          textFormat: Text.PlainText
          text: stop.modelData.sender
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          font.bold: stop.modelData.unread
          elide: Text.ElideRight
        }

        Bar {
          id: senderBar
          visible: !stop.modelData.known
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(1, parent.width * 0.62)
          height: MailStyle.space(9)
        }

        // Invariant: the selected stop has a visible word as well as a theme-dependent fill.
        Text {
          id: openMark
          visible: stop.modelData.open && stop.modelData.known
          anchors.right: parent.right
          anchors.baseline: sender.baseline
          textFormat: Text.PlainText
          text: "open"
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
        }
      }
    }
  }

  component Bar: Rectangle {
    radius: Style.cornerRadius
    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b,
      0.06 + 0.05 * root.pulse)
  }
}

import QtQuick
import "../controls" as Widgets
import "../settings"

// The line above the Inbox about The Point (C-051), beside the offline-mail line: how many messages
// Magpie is working through, or a lasting problem that stops every new Point with its fix beside it.
// Invariant: nothing at all while there is neither.
Item {
  id: root
  required property var tools
  required property color textColor
  required property color accentColor
  required property color dimColor
  required property string panelFontFamily
  readonly property string holdText: tools ? tools.holdText : ""
  readonly property int writing: tools ? tools.writingCount : 0
  readonly property bool shown: holdText !== "" || writing > 0
  visible: shown
  implicitHeight: shown ? Math.max(line.implicitHeight, resume.shown ? resume.implicitHeight : 0) : 0
  height: implicitHeight

  Rectangle {
    id: pulseDot
    objectName: "point-progress-dot"
    readonly property bool shown: root.holdText === "" && root.writing > 0
    visible: shown
    Accessible.ignored: true
    // Centred on the first line, so it stays beside the words when the line wraps.
    y: line.y + (line.contentHeight / Math.max(1, line.lineCount) - height) / 2
    width: MailStyle.space(7); height: width; radius: width / 2
    color: root.accentColor
    SequentialAnimation on opacity {
      running: pulseDot.visible
      loops: Animation.Infinite
      NumberAnimation { to: 0.3; duration: 900; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
    }
  }

  Text {
    id: line
    objectName: "point-progress"
    Accessible.role: Accessible.StaticText
    Accessible.name: text
    x: pulseDot.shown ? pulseDot.width + MailStyle.space(8) : 0
    width: Math.max(0, root.width - x - (resume.shown ? resume.width + MailStyle.space(10) : 0))
    anchors.verticalCenter: parent.verticalCenter
    text: root.holdText !== "" ? root.holdText
      : root.writing === 1 ? "Magpie is reading 1 message"
      : "Magpie is reading " + root.writing + " messages"
    textFormat: Text.PlainText
    // A problem reads like the offline-mail line; progress is quieter.
    color: root.holdText !== "" ? root.textColor : root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    wrapMode: Text.WordWrap
  }

  Widgets.Button {
    id: resume
    objectName: "point-resume"
    readonly property bool shown: !!root.tools && root.tools.hold === "paused"
    visible: shown
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    text: "Resume"
    foreground: root.textColor
    accent: root.accentColor
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.caption
    focusable: true
    onClicked: root.tools.setPaused(false)
  }
}

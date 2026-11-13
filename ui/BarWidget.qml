import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "components"
import "bar/Status.js" as Status

BarWidget {
  id: root

  moduleName: "magpie-mail"

  property string statusPath: {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    return runtime ? runtime + "/magpie-mail/status.json" : ""
  }
  property var activationCommand: ["magpie-mail"]
  property var barStatus: null
  property bool launchFailed: false

  readonly property bool connected: !!barStatus && barStatus.ready
  readonly property int unreadTotal: connected ? barStatus.unreadTotal : 0
  readonly property bool windowOpen: !!barStatus && barStatus.windowOpen
  readonly property string countText: Status.displayCount(unreadTotal)
  readonly property string barTooltip: Status.tooltip(barStatus, launchFailed)
  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property real baseSlot: Style.font.iconLarge + Style.space(9)

  function refreshStatus() {
    barStatus = Status.snapshot(statusFile.text(), Date.now())
  }

  function openWindow() {
    if (launchProcess.running) return false
    launchFailed = false
    launchProcess.command = activationCommand
    launchProcess.running = true
    return true
  }

  FileView {
    id: statusFile
    objectName: "bar-status-file"
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onLoaded: root.refreshStatus()
    onFileChanged: reload()
    onLoadFailed: root.refreshStatus()
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      statusFile.reload()
      root.refreshStatus()
    }
  }

  Process {
    id: launchProcess
    objectName: "bar-launch-process"
    command: root.activationCommand
    onExited: function(exitCode) {
      root.launchFailed = exitCode !== 0
      statusFile.reload()
    }
  }

  readonly property bool drawsIcon: settings.showBarIcon !== false
    && (!barStatus || barStatus.showBarIcon)
  visible: drawsIcon
  implicitWidth: drawsIcon ? button.implicitWidth : 0
  implicitHeight: drawsIcon ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.barTooltip
    Accessible.name: root.barTooltip
    slotSize: root.baseSlot + (root.countText !== ""
      ? Style.space(root.vertical ? 16 : 34) : 0)
    opticalSize: slotSize

    iconComponent: Component {
      Item {
        Item {
          anchors.centerIn: parent
          visible: true
          width: horizontalLogo.width + (horizontalCount.visible
            ? Style.space(4) + horizontalCount.implicitWidth : 0)
          height: Math.max(horizontalLogo.height, horizontalCount.implicitHeight)

          MagpieLogo {
            id: horizontalLogo
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.font.iconLarge
            height: width
            opacity: root.connected ? 1 : 0.55
            Accessible.ignored: true
          }
          Text {
            id: horizontalCount
            objectName: "bar-count-horizontal"
            anchors.left: horizontalLogo.right
            anchors.leftMargin: visible ? Style.space(4) : 0
            anchors.verticalCenter: horizontalLogo.verticalCenter
            visible: root.countText !== ""
            text: root.countText
            textFormat: Text.PlainText
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
            Accessible.ignored: true
          }
        }

      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.openWindow()
    }
  }

  Rectangle {
    id: openIndicator
    objectName: "bar-open-indicator"
    readonly property bool vertical: root.vertical
    visible: root.windowOpen
    color: Commons.Color.accent
    radius: Math.min(width, height) / 2
    width: vertical ? Style.space(2) : Style.space(10)
    height: vertical ? Style.space(10) : Style.space(2)
    x: vertical
      ? (root.bar.position === "left" ? root.width - width - Style.space(2) : Style.space(2))
      : Math.round((root.width - width) / 2)
    y: vertical
      ? Math.round((root.height - height) / 2)
      : (root.bar && root.bar.position === "top"
        ? root.height - height - Style.space(2) : Style.space(2))
  }
}

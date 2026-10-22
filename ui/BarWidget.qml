import QtQuick
import "settings"
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "components"
import "bar"
import "bar/Bridge.js" as BarBridge

BarWidget {
  id: root

  moduleName: "magpie"

  readonly property var directService: bar && bar.shell
    ? bar.shell.serviceFor("magpie") : null
  readonly property var gmail: directService
    || (bridgeApi && bridgeState ? bridgedStatus : null)
  property var bridgeApi: null
  property var bridgeState: null
  property string bridgeStateText: ""

  function syncBridge() {
    var api = BarBridge.current()
    var state = api ? api.snapshot() : null
    var serialized = JSON.stringify(state)
    // Performance: Preserve preview delegate identity when its contents are unchanged.
    if (serialized !== bridgeStateText) {
      bridgeStateText = serialized
      bridgeState = state
    }
    bridgeApi = api
  }

  // Invariant: The bar bridge exposes presentation data and actions without account or authentication objects.
  QtObject {
    id: bridgedStatus
    readonly property bool ready: !!root.bridgeState && root.bridgeState.ready
    readonly property bool windowOpen: !!root.bridgeState && root.bridgeState.windowOpen
    readonly property bool showBarIcon: !root.bridgeState || root.bridgeState.showBarIcon
    readonly property int unreadTotal: root.bridgeState ? root.bridgeState.unreadTotal : 0
    readonly property string barTooltip: root.bridgeState ? root.bridgeState.barTooltip : "Magpie"
    readonly property string contentDirection: root.bridgeState ? root.bridgeState.contentDirection : ""
    readonly property var barMessages: root.bridgeState ? root.bridgeState.barMessages : []
    readonly property var barEvents: root.bridgeState ? root.bridgeState.barEvents : []
    function applySettings(values) {
      if (root.bridgeApi) root.bridgeApi.applySettings(values)
    }
    function refresh() {
      if (root.bridgeApi) root.bridgeApi.refresh()
    }
    function refreshCalendarPreview() {
      if (root.bridgeApi) root.bridgeApi.refreshCalendarPreview()
    }
  }

  // Invariant: JS library registration is not reactive; polling discovers service replacement.
  Timer {
    interval: 1000
    running: !root.directService
    repeat: true
    triggeredOnStart: true
    onTriggered: root.syncBridge()
  }

  // Invariant: barForeground belongs to qs.Ui.Panel; the BarWidget receives its foreground through bar.
  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  property bool previewOpen: false
  property bool popoutSwitchClosing: false

  function close() { previewOpen = false }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }

  // Docs: The shell injects settings into the bar widget, which forwards them to the shared Service.
  function pushSettings() {
    if (gmail && typeof gmail.applySettings === "function") gmail.applySettings(settings)
  }

  onSettingsChanged: pushSettings()
  onGmailChanged: pushSettings()
  onBridgeApiChanged: if (!directService) pushSettings()
  onPreviewOpenChanged: {
    if (previewOpen && gmail && typeof gmail.refreshCalendarPreview === "function")
      root.gmail.refreshCalendarPreview()
  }
  Component.onCompleted: {
    syncBridge()
    pushSettings()
  }

  function openWindow() {
    close()
    if (!bar || !bar.shell) return
    if (typeof bar.shell.toggle === "function") bar.shell.toggle("magpie", "{}")
    else if (typeof bar.shell.summon === "function") bar.shell.summon("magpie", "{}")
  }

  function openMessage(accountId, messageId) {
    close()
    if (!bar || !bar.shell) return
    var payload = JSON.stringify({ accountId: accountId, messageId: messageId })
    if (typeof bar.shell.summon === "function") bar.shell.summon("magpie", payload)
    else if (typeof bar.shell.toggle === "function") bar.shell.toggle("magpie", payload)
  }

  function openEvent(eventData) {
    close()
    if (!bar || !bar.shell) return
    var event = eventData || ({})
    var payload = JSON.stringify({
      view: "calendar", eventId: String(event.uid || ""),
      eventStart: event.start ? Number(event.start.ms) : 0
    })
    if (typeof bar.shell.summon === "function") bar.shell.summon("magpie", payload)
    else if (typeof bar.shell.toggle === "function") bar.shell.toggle("magpie", payload)
  }

  // Invariant: Hiding the icon must retain this widget because it supplies persisted settings to Service.
  readonly property bool drawsIcon: !gmail || gmail.showBarIcon

  visible: drawsIcon
  implicitWidth: drawsIcon ? button.implicitWidth : 0
  implicitHeight: drawsIcon ? button.implicitHeight : 0

  BarIconButton {
    id: button
    visible: root.drawsIcon
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.gmail ? root.gmail.barTooltip : "Magpie"

    // Invariant: Component children resolve their own root identifiers; capture bar properties outside iconComponent.
    readonly property bool connected: !!root.gmail && root.gmail.ready
    readonly property bool windowOpen: root.previewOpen
      || (!!root.gmail && root.gmail.windowOpen)
    readonly property bool hasUnread: !!root.gmail && root.gmail.unreadTotal > 0

    iconComponent: Component {
      Item {
        MagpieLogo {
          id: bird
          readonly property bool crossed: !button.connected
          readonly property bool dot: button.connected && button.hasUnread
          anchors.centerIn: parent
          width: Style.font.iconLarge
          height: width
          foreground: button.foreground
          accent: button.foreground
          opacity: button.connected ? 1 : 0.5
        }
        ActionIcon {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          visible: !button.connected
          name: "close"
          color: button.foreground
          iconSize: Style.font.iconSmall
          Accessible.name: "Mail offline"
        }
        Rectangle {
          anchors.right: parent.right
          anchors.top: parent.top
          width: Style.space(4)
          height: width
          radius: width / 2
          visible: bird.dot
          color: Commons.Color.accent
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) {
        root.openWindow()
        return
      }
      if (buttonCode === Qt.MiddleButton) {
        if (root.gmail) root.gmail.refresh()
        return
      }
      root.previewOpen = !root.previewOpen
    }
  }

  Rectangle {
    id: openIndicator
    readonly property bool vertical: !!root.bar && root.bar.vertical
    visible: button.windowOpen
    color: Commons.Color.accent
    radius: Math.min(width, height) / 2
    width: vertical ? MailStyle.space(2) : MailStyle.space(10)
    height: vertical ? MailStyle.space(10) : MailStyle.space(2)
    x: vertical
      ? (root.bar.position === "left" ? root.width - width - MailStyle.space(2) : MailStyle.space(2))
      : Math.round((root.width - width) / 2)
    y: vertical
      ? Math.round((root.height - height) / 2)
      : (root.bar && root.bar.position === "top"
        ? root.height - height - MailStyle.space(2) : MailStyle.space(2))
  }

  KeyboardPanel {
    id: previewPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.previewOpen
    contentWidth: fittedContentWidth(MailStyle.space(360))
    contentHeight: fittedContentHeight(preview.implicitHeight, MailStyle.space(540))

    BarPreview {
      id: preview
      width: parent ? parent.width : 0
      messages: root.gmail ? root.gmail.barMessages : []
      events: root.gmail ? root.gmail.barEvents : []
      textColor: Commons.Color.popups.text
      backgroundColor: Commons.Color.popups.background
      accentColor: Commons.Color.accent
      dimColor: Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g,
        Commons.Color.popups.text.b, 0.62)
      panelFontFamily: MailStyle.family
      contentDirection: root.gmail ? root.gmail.contentDirection : ""
      onMessageRequested: function(accountId, messageId) {
        root.openMessage(accountId, messageId)
      }
      onCallRequested: function(url) {
        root.close()
        Qt.openUrlExternally(url)
      }
      onEventRequested: function(eventData) { root.openEvent(eventData) }
    }
  }
}

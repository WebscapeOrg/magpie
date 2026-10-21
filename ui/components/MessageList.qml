import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui
import "../account/Model.js" as Model
import "../account/Unified.js" as Unified
import "../agent/Agent.js" as Agent

ListView {
  id: root

  required property var service
  required property color textColor
  required property color accentColor
  required property color dimColor
  required property color urgentColor
  required property string panelFontFamily
  property string snoozeId: ""
  property string cursorId: ""
  // Invariant: checked IDs live above recycled rows so list reloads preserve the selection.
  property var checkedIds: []
  property bool ctrlHeld: false

  signal messageActivated(string id)
  signal checkToggled(string id)
  signal checkRangeRequested(string id)
  signal agentRequested(string id, real sceneX, real sceneY)
  // Invariant: route row actions through the window so an action on a checked row applies to the
  // selection.
  signal snoozeRequested(string id, real sceneX, real sceneY)
  signal rowActionRequested(string id, string action)
  signal menuRequested(string id, real sceneX, real sceneY)

  width: parent ? parent.width : 0
  spacing: MailStyle.space(2)

  clip: true
  boundsBehavior: Flickable.StopAtBounds
  reuseItems: true
  cacheBuffer: Math.max(0, height)
  topMargin: MailStyle.space(6)
  bottomMargin: MailStyle.space(6)
  model: root.service ? root.service.messages.length : 0

  function updateVisibleRows() {
    if (!visible || !service || !service.inboxTools) return
    var first = indexAt(1, contentY + 1)
    var last = indexAt(1, contentY + height - 1)
    if (first < 0) first = 0
    if (last < first) last = Math.min(count - 1, first + 20)
    service.inboxTools.visibleRows = service.messages.slice(Math.max(0, first - 2), last + 3)
  }
  onContentYChanged: { Qt.callLater(updateVisibleRows); loadMoreSoon() }
  onContentHeightChanged: loadMoreSoon()
  onCountChanged: Qt.callLater(updateVisibleRows)
  onVisibleChanged: Qt.callLater(updateVisibleRows)
  Component.onCompleted: Qt.callLater(updateVisibleRows)

  function reveal(id) {
    var index = Model.indexById(root.service.messages, id)
    if (index >= 0) positionViewAtIndex(index, ListView.Contain)
  }

  function boundsFor(id) {
    var index = Model.indexById(root.service.messages, id)
    var item = itemAtIndex(index)
    return item ? ({y:item.y, height:item.height}) : null
  }

  delegate: MessageRow {
      width: root.width
      required property int index
      // Invariant: the summary array and count can update between bindings; recycled rows need an
      // empty summary during that transition.
      readonly property var modelData: root.service.messages[index] || ({})
      readonly property var overviewDetails: root.service.inboxTools
        ? root.service.inboxTools.overviewFor(modelData) : ({})


      attachmentIndicatorEnabled: !!root.service.backend && root.service.backend.ready
        && Number(root.service.backend.apiVersion) >= 8
      snoozeOpen: root.snoozeId === modelData.id
      avatarData: root.service.inboxTools ? root.service.inboxTools.avatarFor(modelData) : ""
      overview: root.service.inboxTools ? String(overviewDetails.text || "") : ""
      overviewReason: root.service.inboxTools ? (root.service.inboxTools.available === false ? (!root.service.backend || !root.service.backend.ready ? "mail backend is disconnected" : "backend update required") : String(overviewDetails.reason || "")) : ""
      overviewState: root.service.inboxTools ? (root.service.inboxTools.available === false ? "unavailable" : root.service.inboxTools.paused === true ? "paused" : String(overviewDetails.state || "")) : ""
      onUnreadRequested: root.rowActionRequested(modelData.id, "markUnread")
      onSnoozeRequested: function(x,y) { root.snoozeRequested(modelData.id,x,y) }
      summary: modelData
      textColor: root.textColor
      accentColor: root.accentColor
      dimColor: root.dimColor
      urgentColor: root.urgentColor
      panelFontFamily: root.panelFontFamily
      agentState: Agent.glyphState(root.service.agentJobs[modelData.id])
      agentProgress: Agent.progressText(root.service.agentJobs[modelData.id])
      agentAttention: root.service.agentAttentionByMessage[modelData.id] === true
      hasCursor: root.cursorId === modelData.id
      selected: root.service.selectedId === modelData.id
      checked: root.checkedIds.indexOf(modelData.id) >= 0
      selectionActive: root.checkedIds.length > 0
      ctrlHeld: root.ctrlHeld
      canArchive: root.service.canArchive
      conversations: Unified.rowIsConversation(modelData)
      contentDirection: root.service.contentDirection
      onActivated: root.messageActivated(modelData.id)
      onCheckToggled: root.checkToggled(modelData.id)
      onCheckRangeRequested: root.checkRangeRequested(modelData.id)
      onAgentRequested: function(sceneX, sceneY) { root.agentRequested(modelData.id, sceneX, sceneY) }
      onStarToggled: root.rowActionRequested(modelData.id, "star")
      onArchiveRequested: root.rowActionRequested(modelData.id, "archive")
      onTrashRequested: root.rowActionRequested(modelData.id, "trash")
      onMenuRequested: function(sceneX, sceneY) {
        root.menuRequested(modelData.id, sceneX, sceneY)
      }
    }

  footer: Column {
    width: root.width
  ListSkeleton {
    width: parent.width
    visible: Model.showInitialListSkeleton(root.service.listLoading,
      root.service.messages.length)
    textColor: root.textColor
  }

  Item {
    width: parent.width
    visible: root.service.messages.length === 0
      && !Model.showInitialListSkeleton(root.service.listLoading, 0)
    implicitHeight: MailStyle.space(70)

    Text {
      anchors.centerIn: parent
      width: parent.width - MailStyle.space(20)
      horizontalAlignment: Text.AlignHCenter
      text: root.service.listLoaded
          ? (root.service.searchQuery !== "" ? "Nothing matches that search" : "Nothing here")
          : ""
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  Item {
    width: parent.width
    visible: root.service.hasMore
    implicitHeight: MailStyle.space(40)

    Widgets.Button {
      objectName: "load-more"
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(8)
      anchors.verticalCenter: parent.verticalCenter
      visible: root.service.hasMore
      text: root.service.listLoading ? "Loading" : "Load more"
      foreground: root.textColor
      bordered: false
      fontSize: MailStyle.caption
      enabled: !root.service.listLoading
      onClicked: root.service.loadMore()
    }
  }

  }

  property var scroller: root
  property int loadStartCount: -1
  property int lastAutoCount: -1

  function loadMoreIfAtFoot() {
    if (!root.scroller || !root.service) return false
    var atFoot = root.scroller.atYEnd || root.scroller.contentY + root.scroller.height >= root.scroller.contentHeight - 1
    if (!atFoot || !root.service.hasMore || root.service.listLoading || !root.count || root.lastAutoCount === root.count) return false
    root.lastAutoCount = root.count
    root.service.loadMore()
    return true
  }

  function loadMoreSoon() { Qt.callLater(root.loadMoreIfAtFoot) }

  function continueAfterLoad(startCount) {
    Qt.callLater(function() {
      if (!root.service || root.service.messages.length <= startCount) return
      root.loadMoreIfAtFoot()
    })
  }

  Connections {
    target: root.scroller
    function onAtYEndChanged() { root.loadMoreSoon() }
  }

  Connections {
    target: root.service
    function onMessagesChanged() { root.lastAutoCount = -1; Qt.callLater(root.updateVisibleRows) }
    function onListLoadingChanged() {
      if (root.service.listLoading) {
        root.loadStartCount = root.service.messages.length
        return
      }
      var startCount = root.loadStartCount
      root.loadStartCount = -1
      if (startCount >= 0) root.continueAfterLoad(startCount)
    }
  }
}

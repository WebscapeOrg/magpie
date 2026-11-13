import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui
import "../account/Model.js" as Model
import "../account/Unified.js" as Unified
import "../search/Presentation.js" as SearchPresentation
import "../account/SyncHealth.js" as SyncHealth

ListView {
  id: root

  required property var service
  property color backgroundColor: "transparent"
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
  readonly property int searchGeneration: service && service.searchGeneration !== undefined
    ? service.searchGeneration : 0
  readonly property bool searchActive: !!service && (service.searchActive === true
    || SearchPresentation.active(service.searchStatus))
  property var viewportIds: []
  property var viewportAnchor: null
  property int viewportRevision: 0
  property bool restoringViewport: false

  signal pointDetailsRequested(string id)
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
  property bool motionEnabled: true
  // The first bundles answer can lag the list by a moment; the rows wait for it so none visibly jumps.
  readonly property bool bundlesLoading: root.service.listLoading
    || (!!root.service.inboxTools && !!root.service.inboxTools.bundles && root.service.inboxTools.bundles.holding === true)
  readonly property var projectedRows: root.service ? root.service.messages || [] : []
  readonly property string accountScope: String(root.service ? root.service.activeAccountId || "" : "")
  property string previousAccountScope: ""
  onProjectedRowsChanged: reconcileRows()
  onAccountScopeChanged: reconcileRows()
  ListModel { id: listedRows }
  model: listedRows
  function rowKey(row) { return JSON.stringify([row.accountId || root.accountScope, row.id || ""]) }
  function reconcileRows() {
    if (!listedRows) return
    if (previousAccountScope !== accountScope) listedRows.clear()
    previousAccountScope = accountScope
    var rows = projectedRows
    for (var i = 0; i < rows.length; i++) {
      var key = rowKey(rows[i]), found = -1
      for (var j = i; j < listedRows.count; j++) if (listedRows.get(j).entryKey === key) { found = j; break }
      if (found < 0) listedRows.insert(i, {entryKey:key, record:JSON.stringify(rows[i])})
      else {
        if (found !== i) listedRows.move(found, i, 1)
        var record = JSON.stringify(rows[i])
        if (listedRows.get(i).record !== record) listedRows.setProperty(i, "record", record)
      }
    }
    if (listedRows.count > rows.length) listedRows.remove(rows.length, listedRows.count - rows.length)
  }
  move: Transition {
    NumberAnimation { properties: "x,y"; duration: root.motionEnabled ? 500 : 0; easing.type: Easing.OutCubic }
  }
  moveDisplaced: Transition {
    NumberAnimation { properties: "x,y"; duration: root.motionEnabled ? 500 : 0; easing.type: Easing.OutCubic }
  }
  addDisplaced: Transition {
    NumberAnimation { properties: "x,y"; duration: root.motionEnabled ? 500 : 0; easing.type: Easing.OutCubic }
  }

  function updateVisibleRows() {
    if (!visible || !service || !service.inboxTools) return
    var first = indexAt(1, contentY + 1)
    var last = indexAt(1, contentY + height - 1)
    if (first < 0) first = 0
    if (last < first) last = Math.min(count - 1, first + 20)
    service.inboxTools.visibleRows = service.messages.slice(Math.max(0, first - 2), last + 3)
  }
  onContentYChanged: { rememberViewport(); Qt.callLater(updateVisibleRows); loadMoreSoon() }
  onContentHeightChanged: loadMoreSoon()
  onCountChanged: Qt.callLater(updateVisibleRows)
  onVisibleChanged: Qt.callLater(updateVisibleRows)
  Component.onCompleted: {
    reconcileRows()
    viewportIds = SearchPresentation.rowIds(searchActive && service ? service.messages : [])
    Qt.callLater(rememberViewport)
    Qt.callLater(updateVisibleRows)
  }
  onSearchGenerationChanged: resetSearchViewport()

  function rememberViewport() {
    if (restoringViewport || !searchActive || !viewportIds.length) return
    var index = indexAt(1, contentY + 1)
    if (index < 0) index = indexAt(1, contentY + topMargin + spacing + 1)
    var item = itemAtIndex(index)
    if (!item || index < 0 || index >= viewportIds.length) return
    viewportAnchor = {id: viewportIds[index], index: index, offset: item.y - contentY,
      generation: searchGeneration, ids: viewportIds}
  }

  function resetSearchViewport() {
    viewportAnchor = null
    restoringViewport = true
    var revision = ++viewportRevision
    Qt.callLater(function() {
      if (revision !== root.viewportRevision) return
      root.forceLayout()
      root.positionViewAtBeginning()
      root.contentY = root.originY - root.topMargin
      root.restoringViewport = false
      root.rememberViewport()
    })
  }

  function preserveSearchViewport() {
    if (!searchActive) { viewportIds = []; viewportAnchor = null; return }
    var anchor = viewportAnchor
      && viewportAnchor.generation === searchGeneration ? viewportAnchor : null
    viewportIds = SearchPresentation.rowIds(service ? service.messages : [])
    restoringViewport = true
    var revision = ++viewportRevision
    Qt.callLater(function() {
      if (revision !== root.viewportRevision) return
      root.forceLayout()
      var index = SearchPresentation.anchorIndex(anchor, root.viewportIds)
      if (index < 0) {
        root.positionViewAtBeginning()
        root.contentY = root.originY - root.topMargin
      }
      else {
        root.positionViewAtIndex(index, ListView.Beginning)
        root.forceLayout()
        var item = root.itemAtIndex(index)
        if (item) {
          var minimum = root.originY - root.topMargin
          var maximum = Math.max(minimum, root.originY + root.contentHeight - root.height + root.bottomMargin)
          root.contentY = Math.max(minimum, Math.min(maximum, item.y - anchor.offset))
        }
      }
      root.restoringViewport = false
      root.rememberViewport()
    })
  }

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
      required property string entryKey
      required property string record
      readonly property var modelData: JSON.parse(record)
      readonly property var overviewDetails: root.service.inboxTools
        ? root.service.inboxTools.overviewFor(modelData) : ({})


      attachmentIndicatorEnabled: !!root.service.backend && root.service.backend.ready
        && Number(root.service.backend.apiVersion) >= 8
      snoozeOpen: root.snoozeId === modelData.id
      avatarData: root.service.inboxTools ? root.service.inboxTools.avatarFor(modelData) : ""
      overview: root.service.inboxTools && root.service.inboxTools.descriptionsEnabled !== false ? String(overviewDetails.text || "") : ""
      writing: !!root.service.inboxTools && root.service.inboxTools.status(modelData) === "writing"
      departing: !!root.service.inboxTools && root.service.inboxTools.departingId === modelData.id
      motionEnabled: root.motionEnabled
      backgroundColor: root.backgroundColor
      pendingCount: root.service.inboxTools && root.service.inboxTools.stack && root.service.inboxTools.stack.currentId === modelData.id
        ? root.service.inboxTools.stack.count : 0
      onUnreadRequested: root.rowActionRequested(modelData.id, "markUnread")
      onSnoozeRequested: function(sceneX, sceneY) { root.snoozeRequested(modelData.id, sceneX, sceneY) }
      summary: modelData
      interactionScope: JSON.stringify([root.accountScope, root.projectedRows.map(root.rowKey).indexOf(entryKey), pendingCount > 0])
      ownerAccountId: String(modelData.accountId || root.service.activeAccountId || "")
      textColor: root.textColor
      accentColor: root.accentColor
      dimColor: root.dimColor
      urgentColor: root.urgentColor
      panelFontFamily: root.panelFontFamily
      hasCursor: root.cursorId === modelData.id
      selected: root.service.selectedId === modelData.id
      checked: root.checkedIds.indexOf(modelData.id) >= 0
      selectionActive: root.checkedIds.length > 0
      ctrlHeld: root.ctrlHeld
      canArchive: root.service.canArchive
      conversations: Unified.rowIsConversation(modelData)
      contentDirection: String(root.service.contentDirection || "auto")
      onPointDetailsRequested: root.pointDetailsRequested(modelData.id)
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
      onBundleApproveRequested: if (root.service.inboxTools && root.service.inboxTools.bundles) root.service.inboxTools.bundles.approve(modelData.id)
      onBundleDismissRequested: if (root.service.inboxTools && root.service.inboxTools.bundles) root.service.inboxTools.bundles.dismiss(modelData.id)
    }

  footer: Column {
    width: root.width
  ListSkeleton {
    width: parent.width
    visible: Model.showInitialListSkeleton(root.bundlesLoading,
      root.service.messages.length)
    textColor: root.textColor
  }

  Item {
    width: parent.width
    visible: root.service.messages.length === 0
      && !Model.showInitialListSkeleton(root.bundlesLoading, 0)
    implicitHeight: Math.max(MailStyle.space(70), emptyLabel.implicitHeight + MailStyle.space(20))

    Text {
      id: emptyLabel
      objectName: "message-list-empty"
      anchors.centerIn: parent
      width: parent.width - MailStyle.space(20)
      horizontalAlignment: Text.AlignHCenter
      readonly property var syncText: SyncHealth.emptyFor(root.service.localMailbox,
        root.service.searchQuery !== "", root.service.listLoading)
      text: syncText !== null ? syncText
        : SearchPresentation.emptyText(root.service.searchStatus, root.service.listLoading,
          root.service.listLoaded, root.service.searchQuery !== "")
      textFormat: Text.PlainText
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
    if (!root.scroller || !root.service || root.restoringViewport) return false
    var atFoot = root.scroller.atYEnd || root.scroller.contentY + root.scroller.height >= root.scroller.originY + root.scroller.contentHeight - 1
    if (!atFoot || !root.service.hasMore || root.service.listLoading || !(root.service.rawMessages || root.service.messages).length || root.lastAutoCount === (root.service.rawMessages || root.service.messages).length) return false
    root.lastAutoCount = (root.service.rawMessages || root.service.messages).length
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
    function onMessagesChanged() {
      root.preserveSearchViewport()
      root.lastAutoCount = -1
      Qt.callLater(root.updateVisibleRows)
    }
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

import QtQuick
import "../controls" as Widgets
import "../settings"
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../account/Model.js" as Model

Item {
  id: root

  required property var service
  required property color textColor
  required property color accentColor
  required property color dimColor
  required property string panelFontFamily
  property bool collapsed: false
  property bool calendarSelected: false
  property string menuLabelPath: ""

  signal mailboxSelected(string key)
  signal labelSelected(string labelId, string name)
  signal folderToggled(string path)
  signal labelMenuRequested(string labelId, string path, real sceneX, real sceneY)
  signal calendarRequested()

  // Invariant: the sidebar and keyboard router share one numbered row projection.
  property var slots: []
  property bool numbersVisible: false

  readonly property var userLabels: root.service
    ? Model.labelTree(root.service.labels, root.service.collapsedFolders) : []

  PanelSeparator {
    id: edge
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: 1
    foreground: root.textColor
  }

  Flickable {
    id: flick

    WheelScroller { view: flick }
    anchors.left: parent.left
    anchors.right: edge.left
    anchors.top: parent.top
    anchors.bottom: footer.top
    contentWidth: width
    contentHeight: column.implicitHeight + MailStyle.space(12)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: column
      x: MailStyle.space(6)
      y: MailStyle.space(6)
      width: flick.width - MailStyle.space(12)
      spacing: MailStyle.space(1)

      Repeater {
        // Invariant: display only the resolved mailboxes supported by this account’s provider.
        model: root.service ? root.service.mailboxes : []

        Entry {
          required property var modelData
          label: modelData.label
          icon: modelData.icon
          count: 0
          selected: !root.calendarSelected && !!root.service
            && root.service.mailboxKey === modelData.key
            && root.service.searchQuery === "" && root.service.rawQuery === ""
          slotNumber: Model.slotNumberOf(root.slots, "mailbox", modelData.key)
          onActivated: root.mailboxSelected(modelData.key)
        }
      }

      Item {
        width: parent.width
        implicitHeight: MailStyle.space(12)
        visible: root.userLabels.length > 0

        PanelSeparator {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          foreground: root.textColor
        }
      }

      Widgets.PanelSectionHeader {
        visible: root.userLabels.length > 0 && !root.collapsed
        leftPadding: MailStyle.space(8)
        bottomPadding: MailStyle.space(3)
        text: "LABELS"
        foreground: root.textColor
        fontFamily: root.panelFontFamily
      }

      Repeater {
        model: root.userLabels

        Entry {
          required property var modelData
          label: modelData.name
          icon: modelData.selectable && !!root.service
            && (root.service.monitoredLabelIds || []).indexOf(modelData.id) >= 0 ? "eye" : "label"
          depth: modelData.depth
          foldable: modelData.hasChildren
          expanded: modelData.expanded
          selectable: modelData.selectable
          fullPath: modelData.path
          monitored: modelData.selectable && !!root.service
            && (root.service.monitoredLabelIds || []).indexOf(modelData.id) >= 0
          onMenuRequested: function(sceneX, sceneY) {
            root.labelMenuRequested(modelData.selectable ? modelData.id : "", modelData.path, sceneX, sceneY)
          }
          slotNumber: modelData.selectable ? Model.slotNumberOf(root.slots, "label", modelData.id) : 0
          count: modelData.unread
          selected: root.menuLabelPath === modelData.path
            || (modelData.selectable && !root.calendarSelected && !!root.service
              && root.service.rawQuery !== ""
              && root.service.rawLabelId === modelData.id)
          onActivated: {
            if (modelData.selectable) root.labelSelected(modelData.id, modelData.rawName)
            else root.folderToggled(modelData.path)
          }
          onFoldRequested: root.folderToggled(modelData.path)
        }
      }
    }
  }

  Column {
    id: footer
    anchors.left: parent.left
    anchors.right: edge.left
    anchors.bottom: parent.bottom

    Entry {
      x: MailStyle.space(6)
      label: "Calendar"
      icon: "calendar"
      selected: root.calendarSelected
      onActivated: root.calendarRequested()
    }

    Item {
      width: parent.width
      height: MailStyle.space(6)
    }

  }

  component Entry: Rectangle {
    id: entry
    required property string label
    property string icon: ""
    property int count: 0
    property bool selected: false
    property int slotNumber: 0
    property int depth: 0
    property bool foldable: false
    property bool expanded: true
    property bool selectable: true
    property string fullPath: ""
    signal activated()
    signal foldRequested()
    signal menuRequested(real sceneX, real sceneY)
    property bool monitored: false

    // Invariant: rows after the ninth have no digit shortcut; Ctrl+0 resets zoom.
    readonly property bool showsNumber: root.numbersVisible && slotNumber > 0
    readonly property string numberText: String(slotNumber)

    width: column.width
    implicitHeight: MailStyle.space(28)
    radius: Style.cornerRadius
    color: entry.selected
      ? Style.selectedFillFor(root.textColor, root.accentColor)
      : (hover.hovered ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent")

    ActionIcon {
      id: glyph
      anchors.left: parent.left
      anchors.leftMargin: root.collapsed
        ? (parent.width - width) / 2 : MailStyle.space(8) + entry.depth * MailStyle.space(12)
      anchors.verticalCenter: parent.verticalCenter
      name: entry.icon
      iconSize: Style.font.icon
      color: entry.selected ? root.textColor
        : (entry.selectable ? root.dimColor
          : Qt.rgba(root.dimColor.r, root.dimColor.g, root.dimColor.b, root.dimColor.a * 0.6))
      objectName: "mailbox-entry-icon"
    }

    Item {
      id: fold
      objectName: "fold"
      visible: entry.foldable && !root.collapsed && !entry.showsNumber
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(4)
      anchors.verticalCenter: parent.verticalCenter
      width: MailStyle.space(18)
      height: MailStyle.space(22)

      ActionIcon {
        anchors.centerIn: parent
        name: entry.expanded ? "chevronDown" : "chevronRight"
        iconSize: Style.font.iconSmall
        color: foldHover.hovered ? root.textColor : root.dimColor
      }

      HoverHandler { id: foldHover }
      TapHandler { onTapped: entry.foldRequested() }
    }

    Rectangle {
      id: slotChip
      objectName: "mailbox-shortcut-chip"
      visible: entry.showsNumber
      anchors.verticalCenter: root.collapsed ? undefined : parent.verticalCenter
      anchors.top: root.collapsed ? parent.top : undefined
      anchors.topMargin: MailStyle.space(1)
      anchors.right: parent.right
      anchors.rightMargin: root.collapsed ? MailStyle.space(1) : MailStyle.space(6)
      width: MailStyle.space(root.collapsed ? 10 : 16)
      height: width
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.textColor, root.accentColor)

      Text {
        anchors.centerIn: parent
        text: entry.numberText
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: root.collapsed ? MailStyle.caption * 0.8 : MailStyle.caption
        font.bold: true
      }
    }

    Text {
      visible: !root.collapsed
      anchors.left: glyph.right
      anchors.leftMargin: MailStyle.space(9)
      anchors.right: slotChip.visible ? slotChip.left
        : (badge.visible ? badge.left : (fold.visible ? fold.left : parent.right))
      anchors.rightMargin: MailStyle.space(6)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: entry.label
      color: entry.selected ? root.textColor
        : (entry.selectable ? root.dimColor
          : Qt.rgba(root.dimColor.r, root.dimColor.g, root.dimColor.b, root.dimColor.a * 0.6))
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      font.bold: entry.selected
      elide: Text.ElideRight
    }

    Text {
      id: badge
      visible: entry.count > 0 && !root.collapsed && !entry.showsNumber
      anchors.right: fold.visible ? fold.left : parent.right
      anchors.rightMargin: fold.visible ? MailStyle.space(2) : MailStyle.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: Model.badgeText(entry.count, 999)
      color: root.accentColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      font.bold: true
    }

    Rectangle {
      visible: entry.count > 0 && root.collapsed && !entry.showsNumber
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(3)
      anchors.top: parent.top
      anchors.topMargin: MailStyle.space(4)
      width: MailStyle.space(5)
      height: width
      radius: width / 2
      color: root.accentColor
    }

    HoverHandler { id: hover }
    // Invariant: nested fold and row handlers see the same tap; folding must not also open the
    // mailbox.
    TapHandler {
      onTapped: function(eventPoint) {
        var at = eventPoint.position
        if (fold.visible && at.x >= fold.x && at.x < fold.x + fold.width
            && at.y >= fold.y && at.y < fold.y + fold.height) return
        entry.activated()
      }
    }
    TapHandler {
      acceptedButtons: Qt.RightButton
      onTapped: {
        var scene = entry.mapToGlobal(0, entry.height)
        entry.menuRequested(scene.x, scene.y)
      }
    }

    Widgets.PanelToolTip {
      objectName: "label-tooltip"
      visible: hover.hovered
      text: (entry.fullPath !== "" ? entry.fullPath : entry.label)
        + (entry.count > 0 ? " · " + entry.count : "")
      fontFamily: root.panelFontFamily
    }
  }
}

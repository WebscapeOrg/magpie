import QtQuick
import "../controls" as Widgets
import "../settings"
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "../compose/Recipients.js" as Recipients

Item {
  id: root

  required property var contacts
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  readonly property bool opened: menu.opened
  property string searchQuery: ""

  readonly property var filteredContacts: Recipients.filter(
    root.contacts || [],
    root.searchQuery,
    100)

  signal contactChosen(var contact, string target)

  anchors.fill: parent
  z: 60

  property real anchorX: 0
  property real anchorY: 0

  function openAt(sceneX, sceneY) {
    var local = root.mapFromGlobal(sceneX, sceneY)
    anchorX = local.x
    anchorY = local.y
    searchField.text = ""
    root.searchQuery = ""
    menu.open()
    place()
    searchField.forceActiveFocus()
  }

  function open() {
    anchorX = Math.max(0, root.width - menu.width - MailStyle.space(16))
    anchorY = MailStyle.space(70)
    searchField.text = ""
    root.searchQuery = ""
    menu.open()
    place()
    searchField.forceActiveFocus()
  }

  function close() {
    menu.close()
  }

  // Invariant: outside-press closes the popup before the trigger’s release; retain close time to
  // avoid immediately reopening it.
  property double closedAt: 0

  function toggleAt(sceneX, sceneY) {
    if (menu.opened) {
      close()
      return
    }
    if (Date.now() - closedAt < 250) return
    openAt(sceneX, sceneY)
  }

  function place() {
    if (!menu.visible) return
    var menuX = Math.max(MailStyle.space(8), Math.min(anchorX, root.width - menu.width - MailStyle.space(8)))
    var menuY = Math.max(MailStyle.space(8), Math.min(anchorY, root.height - menu.implicitHeight - MailStyle.space(8)))
    menu.x = menuX
    menu.y = menuY
  }

  QQC.Popup {
    id: menu
    width: Math.min(MailStyle.space(340), root.width - MailStyle.space(24))
    implicitHeight: Math.min(contentColumn.implicitHeight + MailStyle.space(16), MailStyle.space(420))
    padding: MailStyle.space(8)
    modal: false
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    onHeightChanged: root.place()
    onOpened: root.place()
    onClosed: root.closedAt = Date.now()

    background: Rectangle {
      radius: Style.cornerRadius
      color: Qt.rgba(root.popupBackgroundColor.r, root.popupBackgroundColor.g,
        root.popupBackgroundColor.b, 1)
      border.width: 1
      border.color: root.popupBorderColor
    }

    contentItem: Column {
      id: contentColumn
      spacing: MailStyle.space(8)

      Row {
        width: parent.width
        spacing: MailStyle.space(8)

        Text {
          text: "Contacts"
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: "(" + (root.contacts ? root.contacts.length : 0) + ")"
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Widgets.TextField {
        id: searchField
        width: parent.width
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "Search contacts..."
        onTextChanged: root.searchQuery = text
      }

      ListView {
        id: contactsList

        WheelScroller { view: contactsList }
        width: parent.width
        implicitHeight: Math.min(contentHeight, MailStyle.space(280))
        clip: true
        model: root.filteredContacts
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        delegate: Rectangle {
          id: contactRow
          required property var modelData
          required property int index

          width: contactsList.width
          implicitHeight: MailStyle.space(44)
          radius: Style.cornerRadius
          color: contactHover.hovered
            ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent"

          Rectangle {
            id: avatar
            anchors.left: parent.left
            anchors.leftMargin: MailStyle.space(6)
            anchors.verticalCenter: parent.verticalCenter
            width: MailStyle.space(26)
            height: width
            radius: width / 2
            color: Style.selectedFillFor(root.textColor, root.accentColor)

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: {
                var name = String(contactRow.modelData.name || contactRow.modelData.email || "")
                return name.length > 0 ? name.charAt(0).toUpperCase() : "?"
              }
              color: root.textColor
              font.family: root.panelFontFamily
              font.pixelSize: MailStyle.caption
              font.bold: true
            }
          }

          Column {
            anchors.left: avatar.right
            anchors.leftMargin: MailStyle.space(8)
            anchors.right: actionPills.left
            anchors.rightMargin: MailStyle.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: MailStyle.space(1)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: String(contactRow.modelData.name || contactRow.modelData.email || "")
              color: root.textColor
              font.family: root.panelFontFamily
              font.pixelSize: MailStyle.bodySmall
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              visible: String(contactRow.modelData.name || "") !== ""
              width: parent.width
              textFormat: Text.PlainText
              text: String(contactRow.modelData.email || "")
              color: root.dimColor
              font.family: root.panelFontFamily
              font.pixelSize: MailStyle.caption
              elide: Text.ElideMiddle
            }
          }

          Row {
            id: actionPills
            anchors.right: parent.right
            anchors.rightMargin: MailStyle.space(6)
            anchors.verticalCenter: parent.verticalCenter
            spacing: MailStyle.space(3)

            Widgets.Button {
              text: "+ To"
              bordered: false
              fontSize: MailStyle.caption
              foreground: root.accentColor
              onClicked: {
                root.contactChosen(contactRow.modelData, "to")
                menu.close()
              }
            }

            Widgets.Button {
              text: "+ Cc"
              bordered: false
              fontSize: MailStyle.caption
              foreground: root.dimColor
              onClicked: {
                root.contactChosen(contactRow.modelData, "cc")
                menu.close()
              }
            }

            Widgets.Button {
              text: "+ Bcc"
              bordered: false
              fontSize: MailStyle.caption
              foreground: root.dimColor
              onClicked: {
                root.contactChosen(contactRow.modelData, "bcc")
                menu.close()
              }
            }
          }

          HoverHandler { id: contactHover }
          TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: {
              root.contactChosen(contactRow.modelData, "to")
              menu.close()
            }
          }
        }
      }

      Text {
        visible: root.filteredContacts.length === 0
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "No contacts found"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        topPadding: MailStyle.space(12)
        bottomPadding: MailStyle.space(12)
      }
    }
  }
}

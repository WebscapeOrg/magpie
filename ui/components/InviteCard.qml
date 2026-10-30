import QtQuick
import "../settings"
import qs.Commons
import qs.Ui
import "../message/Calendar.js" as Calendar

Rectangle {
  id: root

  property var invite: null

  required property color textColor
  required property color accentColor
  required property color dimColor
  required property color dimmerColor
  required property string panelFontFamily

  signal openRequested(string url)
  signal calendarRequested()

  readonly property bool cancelled: !!invite
    && (invite.method === "CANCEL" || String(invite.status || "") === "CANCELLED")

  visible: !!invite
  implicitHeight: visible ? column.implicitHeight + MailStyle.space(24) : 0
  radius: Style.cornerRadius
  color: Style.normalFillFor(root.textColor, root.accentColor)
  border.width: 1
  border.color: Style.normalBorderFor(root.textColor, root.accentColor)

  Column {
    id: column
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: MailStyle.space(12)
    spacing: MailStyle.space(6)


    Row {
      spacing: MailStyle.space(6)

      ActionIcon {
        anchors.verticalCenter: parent.verticalCenter
        name: "calendar"
        iconSize: Style.font.iconSmall
        color: root.dimColor
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.invite ? Calendar.headline(root.invite) : ""
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }
    }

    // Invariant: organizer-controlled summaries must remain plain text to prevent Qt resource
    // loading.
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.invite ? String(root.invite.summary || "(no title)") : ""
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.body
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: {
        if (!root.invite) return ""
        var when = Calendar.formatWhen(root.invite)
        var span = Calendar.formatDuration(root.invite)
        return span === "" ? when : when + " · " + span
      }
      visible: text !== ""
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.invite ? String(root.invite.recurrence || "") : ""
      visible: text !== ""
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }


    Item { width: 1; height: MailStyle.space(2); visible: whereRow.visible }

    Row {
      id: whereRow
      width: parent.width
      spacing: MailStyle.space(6)
      visible: !!root.invite && String(root.invite.location || "") !== ""

      ActionIcon {
        anchors.verticalCenter: parent.verticalCenter
        name: "pin"
        iconSize: Style.font.iconSmall
        color: root.dimmerColor
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.font.iconSmall - MailStyle.space(6)
        textFormat: Text.PlainText
        text: root.invite ? String(root.invite.location || "") : ""
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        elide: Text.ElideRight
      }
    }


    Row {
      width: parent.width
      spacing: MailStyle.space(6)
      visible: !!root.invite && !!root.invite.organizer
        && String(root.invite.organizer.email || "") !== ""

      ActionIcon {
        anchors.verticalCenter: parent.verticalCenter
        name: "people"
        iconSize: Style.font.iconSmall
        color: root.dimmerColor
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.font.iconSmall - MailStyle.space(6)
        textFormat: Text.PlainText
        text: {
          if (!root.invite || !root.invite.organizer) return ""
          var host = String(root.invite.organizer.name || root.invite.organizer.email)
          var guests = Calendar.attendeeSummary(root.invite)
          return guests === "" ? host : host + " · " + guests
        }
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        elide: Text.ElideRight
      }
    }

    // Invariant: cap the visible guest list so large invitations do not occupy the entire message
    // viewport.
    Column {
      width: parent.width
      spacing: MailStyle.space(2)
      visible: guests.count > 0

      Repeater {
        id: guests
        model: {
          if (!root.invite) return []
          var list = root.invite.attendees || []
          return list.length > 6 ? list.slice(0, 6) : list
        }

        Text {
          required property var modelData
          width: parent.width
          leftPadding: Style.font.iconSmall + MailStyle.space(6)
          textFormat: Text.PlainText
          text: String(modelData.name || modelData.email) + " — "
            + Calendar.partstatLabel(modelData.partstat)
            + (modelData.optional ? " (optional)" : "")
          color: root.dimmerColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          elide: Text.ElideRight
        }
      }
    }

    Text {
      width: parent.width
      leftPadding: Style.font.iconSmall + MailStyle.space(6)
      visible: !!root.invite && (root.invite.attendees || []).length > 6
      text: root.invite
        ? "and " + ((root.invite.attendees || []).length - 6) + " more"
        : ""
      color: root.dimmerColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
    }


    Item { width: 1; height: MailStyle.space(4); visible: joinButton.visible || calendarButton.visible }

    IconTextButton {
      id: joinButton
      visible: !!root.invite && String(root.invite.meetLink || "") !== "" && !root.cancelled
      iconName: "video"
      text: root.invite && String(root.invite.meetLink || "").indexOf("meet.google.com") > 0
        ? "Join with Google Meet..."
        : "Join the call..."
      foreground: root.textColor
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      fontSize: MailStyle.caption
      onClicked: if (root.invite) root.openRequested(String(root.invite.meetLink || ""))
    }


    IconTextButton {
      id:calendarButton
      text:"Open invitation in Skylark..."
      foreground:root.textColor
      accent:root.accentColor
      fontFamily:root.panelFontFamily
      onClicked:root.calendarRequested()
    }
  }
}

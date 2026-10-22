import QtQuick
import QtQuick.Controls as QQC
import "../controls" as Widgets
import "../settings"
import qs.Commons
import "Snooze.js" as Snooze
import "Menu.js" as Menu
Item {
  id: root
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily
  property var tools: null
  property string messageId: ""
  property var choices: []
  property bool custom: false
  property bool scheduled: false
  property real anchorX: 0
  property real anchorY: 0
  readonly property bool opened: popup.opened
  property int validationRevision: 0
  readonly property var chosenTime: {
    validationRevision
    return Snooze.parse(dateField.text,hour.value,minute.value,currentTime())
  }
  function currentTime() { return Date.now() }
  signal snoozed(string id, double until)
  anchors.fill: parent
  z: 60
  function openAt(id,sceneX,sceneY) {
    messageId = id; choices = Snooze.options(new Date()); custom = false; scheduled = false
    var local = mapFromGlobal(sceneX,sceneY); anchorX = local.x; anchorY = local.y
    dateField.text = Qt.formatDate(choices[0].date,"yyyy-MM-dd"); hour.value = 8; minute.value = 0
    popup.open(); place()
  }
  function openScheduled() {
    scheduled = true; custom = false
    anchorX = (width-popup.width)/2; anchorY = (height-popup.implicitHeight)/2
    popup.open(); place()
  }
  function place() {
    if (!popup.visible) return
    var at = Menu.position(anchorX,anchorY,popup.width,popup.implicitHeight,width,height)
    popup.x = at.x; popup.y = at.y
  }
  function choose(date) {
    if (!date) return
    if (date.getTime() <= currentTime()) {
      custom = true
      dateField.text = Qt.formatDate(date, "yyyy-MM-dd")
      hour.value = date.getHours()
      minute.value = date.getMinutes()
      validationRevision++
      return
    }
    popup.close()
    snoozed(messageId,date.getTime())
  }
  QQC.Popup {
    id: popup
    objectName: "snooze-popup"
    width: Math.min(root.width-MailStyle.space(24),MailStyle.space(390))
    implicitHeight: Math.min(content.implicitHeight + padding * 2,root.height - MailStyle.space(24))
    padding: MailStyle.space(12)
    modal: false
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    onHeightChanged: root.place()
    onOpened: Qt.callLater(function() { if (!root.scheduled) firstChoice.forceActiveFocus() })
    background: Rectangle { radius: Style.cornerRadius; color: root.popupBackgroundColor; border.color: root.popupBorderColor }
    contentItem: QQC.ScrollView {
      id: snoozeScroll
      clip: true
      contentWidth: availableWidth
      Column {
      id: content
      width: snoozeScroll.availableWidth
      spacing: MailStyle.space(8)
      Text { text: root.scheduled ? "Snoozed mail" : "Snooze until..."; textFormat: Text.PlainText; color: root.textColor; font.family: root.panelFontFamily; font.pixelSize: MailStyle.body; font.bold: true }
      Column {
        width: parent.width
        visible: !root.custom && !root.scheduled
        Repeater {
          model: root.choices
          Widgets.Button {
            required property var modelData
            width: parent.width
            text: modelData.label + "    " + Qt.formatDateTime(modelData.date,"ddd, HH:mm")
            foreground: root.textColor; accent: root.accentColor; fontFamily: root.panelFontFamily; fontSize: MailStyle.bodySmall; bordered: false; focusable: true
            onClicked: root.choose(modelData.date)
          }
        }
        Widgets.Button {
          id: firstChoice
          objectName: "snooze-custom"
          width: parent.width
          text: "Select date and time..."
          foreground: root.textColor; accent: root.accentColor; fontFamily: root.panelFontFamily; fontSize: MailStyle.bodySmall; bordered: false; focusable: true
          onClicked: { root.custom = true; dateField.forceActiveFocus() }
        }
      }
      Column {
        width: parent.width
        visible: root.custom && !root.scheduled
        spacing: MailStyle.space(8)
        Text { textFormat: Text.PlainText; text: "Date (YYYY-MM-DD)"; color: root.dimColor; font.family: root.panelFontFamily; font.pixelSize: MailStyle.caption }
        Widgets.TextField { id: dateField; objectName: "snooze-date"; width: parent.width; foreground: root.textColor; font.family: root.panelFontFamily; font.pixelSize: MailStyle.body; Accessible.name: "Snooze date, year month day" }
        Text { textFormat: Text.PlainText; text: "Local time"; color: root.dimColor; font.family: root.panelFontFamily; font.pixelSize: MailStyle.caption }
        Row {
          spacing: MailStyle.space(8)
          TimeField { id: hour; objectName: "snooze-hour"; from: 0; to: 23; value: 8; editable: true; Accessible.name: "Hour"; font.family: root.panelFontFamily; font.pixelSize: MailStyle.body }
          Text { textFormat: Text.PlainText; text: ":"; color: root.textColor; font.pixelSize: MailStyle.body }
          TimeField { id: minute; objectName: "snooze-minute"; from: 0; to: 59; value: 0; editable: true; Accessible.name: "Minute"; font.family: root.panelFontFamily; font.pixelSize: MailStyle.body }
        }
        Text { textFormat: Text.PlainText; width: parent.width; visible: !root.chosenTime; text: "Choose a valid date and time in the future."; color: root.dimColor; wrapMode: Text.WordWrap; font.family: root.panelFontFamily; font.pixelSize: MailStyle.caption }
        Widgets.Button { objectName: "snooze-submit"; text: "Snooze"; foreground: root.textColor; accent: root.accentColor; fontFamily: root.panelFontFamily; fontSize: MailStyle.body; enabled: !!root.chosenTime; focusable: true; onClicked: root.choose(root.chosenTime) }
      }
      Column {
        width: parent.width
        visible: root.scheduled
        spacing: MailStyle.space(8)
        Repeater {
          model: root.tools ? root.tools.snoozes : []
          Column {
            required property var modelData
            width: parent.width
            spacing: MailStyle.space(4)
            Text { width: parent.width; textFormat: Text.PlainText; text: String(modelData.subject || "Snoozed message"); elide: Text.ElideRight; color: root.textColor; font.family: root.panelFontFamily; font.pixelSize: MailStyle.bodySmall }
            Text { width: parent.width; textFormat: Text.PlainText; text: String(modelData.accountId || "") + " · " + Qt.formatDateTime(new Date(modelData.until),"d MMM, HH:mm"); elide: Text.ElideRight; color: root.dimColor; font.family: root.panelFontFamily; font.pixelSize: MailStyle.caption }
            Widgets.Button {
              text: "Return to Inbox"
              Accessible.name: "Return to Inbox: " + String(modelData.subject || "Snoozed message")
              foreground: root.textColor; accent: root.accentColor; fontFamily: root.panelFontFamily; fontSize: MailStyle.caption; focusable: true
              onClicked: { root.tools.wake(modelData); popup.close() }
            }
          }
        }
        Text { textFormat: Text.PlainText; visible: !root.tools || !root.tools.snoozes.length; text: "No snoozed messages"; color: root.dimColor; font.family: root.panelFontFamily; font.pixelSize: MailStyle.body }
      }
      Widgets.Button { text: "Cancel"; foreground: root.dimColor; fontFamily: root.panelFontFamily; fontSize: MailStyle.caption; bordered: false; focusable: true; onClicked: popup.close() }
      }
    }
  }
  component TimeField: QQC.SpinBox {
    palette.base: root.popupBackgroundColor
    palette.window: root.popupBackgroundColor
    palette.text: root.textColor
    palette.button: root.popupBackgroundColor
    palette.buttonText: root.textColor
    palette.light: root.popupBorderColor
    palette.dark: root.popupBorderColor
    palette.mid: root.popupBorderColor
    palette.highlight: root.accentColor
    palette.highlightedText: root.popupBackgroundColor
    textFromValue: function(value) { return value < 10 ? "0" + value : String(value) }
  }
}

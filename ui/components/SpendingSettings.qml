import QtQuick
import "../settings"
import qs.Commons
import qs.Ui
import "../inbox/Spending.js" as Spending

// Settings → AI spending: what sender pictures painted on this computer cost today, this week and
// this month, as the iPhone and iPad show for their own spending.
// Invariant: the periods start on this computer's clock and calendar, and every amount is labelled
// with its period for screen readers.
Column {
  id: root
  required property var service
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily
  property var reply: null
  property var periodStarts: null
  property string error: ""
  readonly property bool ready: !!service && !!service.backend && service.backend.ready === true
    && Number(service.backend.apiVersion) >= 8
  visible: reply !== null || error !== ""
  spacing: MailStyle.space(6)

  function load() {
    if (!ready) return
    var starts = Spending.starts(new Date(), Qt.locale().firstDayOfWeek)
    service.backend.call("ai.spending", starts, function(result, failure) {
      if (!failure && result) { root.periodStarts = starts; root.reply = result; root.error = ""; return }
      // An engine without the page keeps the section hidden.
      if (failure && (failure.code === -32012 || failure.code === -32601)) { root.reply = null; root.error = ""; return }
      if (root.reply === null) root.error = "Magpie Mail could not read what it has spent. It tries again in a minute."
    })
  }
  onReadyChanged: load()
  Component.onCompleted: load()
  Timer {
    objectName: "settings-spending-refresh"
    interval: 60000
    repeat: true
    running: root.ready && root.visible
    onTriggered: root.load()
  }

  Text {
    width: parent.width
    text: "AI SPENDING"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }
  // One column per period, caption above amount. The feature is named in the note below and in
  // each amount's spoken label.
  Row {
    id: table
    objectName: "settings-spending-table"
    visible: root.reply !== null
    width: parent.width
    spacing: MailStyle.space(16)
    Repeater {
      model: Spending.PERIODS
      Column {
        required property var modelData
        width: Math.max(0, (table.width - table.spacing * 2) / 3)
        spacing: MailStyle.space(2)
        Accessible.role: Accessible.StaticText
        Accessible.name: "Sender pictures, " + modelData.phrase + ": "
          + Spending.money(Spending.amount(root.reply, modelData.id, "pictures"))
        Text {
          width: parent.width
          text: modelData.title
          textFormat: Text.PlainText
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          wrapMode: Text.Wrap
          Accessible.ignored: true
        }
        Text {
          objectName: "settings-spending-" + modelData.id
          width: parent.width
          text: Spending.money(Spending.amount(root.reply, modelData.id, "pictures"))
          textFormat: Text.PlainText
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          wrapMode: Text.Wrap
          Accessible.ignored: true
        }
      }
    }
  }
  Text {
    objectName: "settings-spending-note"
    width: parent.width
    topPadding: table.visible ? MailStyle.space(4) : 0
    textFormat: Text.PlainText
    text: root.error !== "" ? root.error : Spending.footer(root.reply, root.periodStarts, new Date())
    color: root.error !== "" ? root.accentColor : root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }
}

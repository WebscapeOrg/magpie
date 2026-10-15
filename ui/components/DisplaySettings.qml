import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import "../settings"

Column {
  id: root
  required property var service
  required property color textColor
  required property color dimColor
  required property color accentColor
  spacing: MailStyle.space(12)

  readonly property var preferences: service && service.displayPreferences ? service.displayPreferences : MailStyle.preferences
  readonly property var families: {
    var result = ["System UI font"]
    var installed = Qt.fontFamilies()
    for (var i = 0; i < installed.length; i++) result.push(installed[i])
    return result
  }

  Text {
    text: "Layout and fonts"
    color: root.textColor
    font.family: MailStyle.family
    font.pixelSize: MailStyle.subtitle
    font.bold: true
  }

  Controls.ButtonGroup { id: layouts }
  Repeater {
    model: ["Single pane", "Split view"]
    Controls.RadioButton {
      required property string modelData
      text: modelData
      checked: root.preferences.layout === modelData
      Controls.ButtonGroup.group: layouts
      font.family: MailStyle.family
      font.pixelSize: MailStyle.body
      palette.windowText: root.textColor
      palette.buttonText: root.textColor
      palette.highlight: root.accentColor
      onClicked: if (root.service) root.service.setDisplayPreference("layout", modelData)
    }
  }

  Text {
    width: parent.width
    text: "Single pane opens a message in place of the list. Back returns to the list. Font sizes are in points. Changes save automatically."
    wrapMode: Text.WordWrap
    color: root.dimColor
    font.family: MailStyle.family
    font.pixelSize: MailStyle.caption
  }

  Repeater {
    model: [{key: "interface", title: "Interface"}, {key: "list", title: "Message list"}, {key: "message", title: "Message body"}]
    Column {
      id: region
      required property var modelData
      width: root.width
      spacing: MailStyle.space(6)
      readonly property string family: root.preferences[modelData.key + "Family"]
      Text {
        text: region.modelData.title
        color: root.textColor
        font.family: MailStyle.family
        font.pixelSize: MailStyle.body
        font.bold: true
      }
      Controls.ComboBox {
        objectName: region.modelData.key + "-font"
        width: parent.width
        model: root.families
        currentIndex: Math.max(0, root.families.indexOf(region.family || "System UI font"))
        font.family: MailStyle.family
        font.pixelSize: MailStyle.body
        palette.base: Color.popups.background
        palette.button: Color.popups.background
        palette.window: Color.popups.background
        palette.text: root.textColor
        palette.buttonText: root.textColor
        palette.highlight: root.accentColor
        Accessible.name: region.modelData.title + " font"
        onActivated: if (root.service) root.service.setDisplayPreference(region.modelData.key + "Family", currentIndex === 0 ? "" : currentText)
      }
      Row {
        spacing: MailStyle.space(10)
        Controls.SpinBox {
          objectName: region.modelData.key + "-size"
          from: 8
          to: 36
          value: root.preferences[region.modelData.key + "Size"]
          editable: true
          font.family: MailStyle.family
          font.pixelSize: MailStyle.body
          palette.base: Color.popups.background
        palette.button: Color.popups.background
        palette.window: Color.popups.background
        palette.text: root.textColor
          palette.buttonText: root.textColor
          palette.highlight: root.accentColor
          Accessible.name: region.modelData.title + " font size in points"
          onValueModified: if (root.service) root.service.setDisplayPreference(region.modelData.key + "Size", value)
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "pt"
          color: root.dimColor
          font.family: MailStyle.family
          font.pixelSize: MailStyle.body
        }
      }
      Text {
        width: parent.width
        text: "The quick brown fox jumps over the lazy dog."
        wrapMode: Text.WordWrap
        color: root.textColor
        font.family: region.family || "sans-serif"
        font.pointSize: root.preferences[region.modelData.key + "Size"]
        Accessible.name: region.modelData.title + " font preview"
      }
    }
  }
}

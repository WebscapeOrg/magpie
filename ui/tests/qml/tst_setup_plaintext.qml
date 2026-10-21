import QtQuick
import QtTest
import "../../components" as Views

Item {
  width: 700
  height: 900
  QtObject {
    id: auth
    property bool loggedIn: false
    property bool loginBusy: false
    property bool toolsChecked: true
    property bool credentialsPresent: true
    property bool credentialsWriteBusy: false
    property var missingTools: []
    property string lastError: ""
    property string clientId: "client"
    property string clientDescription: "client"
    property string credentialsPath: "/synthetic/credentials.json"
    property var credentials: null
    property var settings: ({username: "", aliases: [], imapHost: "", imapPort: 993, smtpHost: "", smtpPort: 465})
  }
  QtObject {
    id: service
    property var auth: auth
    property string accountAddress: ""
    property string accountEmail: ""
    property string accountName: ""
    property string accountSenderName: ""
    property bool backendCanNameSender: false
    property string signInProgress: ""
  }
  Views.ImapSetupPage {
    id: imap
    width: 600
    service: service
    textColor: "#eeeeee"
    dimColor: "#aaaaaa"
    dangerColor: "#ff6666"
    accentColor: "#e9a35f"
    panelFontFamily: "monospace"
  }
  Views.SetupPage {
    id: gmail
    width: 600
    service: service
    textColor: "#eeeeee"
    dimColor: "#aaaaaa"
    dangerColor: "#ff6666"
    accentColor: "#e9a35f"
    panelFontFamily: "monospace"
  }
  TestCase {
    name: "SetupPlainText"
    when: windowShown
    readonly property string markup: '<a href="https://example.test/">setup</a>'
    function labelContaining(item, value) {
      if (item.text !== undefined && String(item.text).indexOf(value) >= 0 && item.textFormat !== undefined) return item
      var children = item.children || []
      for (var childIndex = 0; childIndex < children.length; childIndex++) {
        var label = labelContaining(children[childIndex], value)
        if (label) return label
      }
      return null
    }
    function init() {
      auth.lastError = ""
      auth.clientDescription = "client"
      auth.credentialsPath = "/synthetic/credentials.json"
      service.signInProgress = ""
    }
    function test_imap_server_error_is_literal() {
      auth.lastError = markup
      compare(findChild(imap, "imap-error").textFormat, Text.PlainText)
    }
    function test_gmail_runtime_values_are_literal_data() {
      return [{tag: "progress", field: "signInProgress", serviceField: true},
        {tag: "client", field: "clientDescription", serviceField: false},
        {tag: "path", field: "credentialsPath", serviceField: false}]
    }
    function test_gmail_runtime_values_are_literal(data) {
      var owner = data.serviceField ? service : auth
      owner[data.field] = markup
      var label = labelContaining(gmail, markup)
      verify(label)
      compare(label.textFormat, Text.PlainText)
    }
  }
}

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
  }
  QtObject {
    id: service
    property var auth: auth
    property string accountAddress: ""
    property string accountEmail: ""
    property string accountName: ""
    property string signInProgress: ""
  }
  Views.SetupPage {
    id: gmail
    width: 600
    service: service
    textColor: Qt.rgba(238/255, 238/255, 238/255, 1)
    dimColor: Qt.rgba(170/255, 170/255, 170/255, 1)
    dangerColor: Qt.rgba(255/255, 102/255, 102/255, 1)
    accentColor: Qt.rgba(233/255, 163/255, 95/255, 1)
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
    function test_gmail_runtime_values_are_literal_data() {
      return [{tag: "error", field: "lastError", serviceField: false},
        {tag: "progress", field: "signInProgress", serviceField: true},
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

import QtQuick
import QtTest
import "../../components" as Omamail

Item {
  width: 720
  height: Math.max(500, page.height + 32)
  QtObject {
    id: runtime
    property string state: "ready"
    property string installedVersion: "0.9.0"
    property string requiredVersion: "0.9.0"
    property string error: ""
    property string developmentExecutable: ""
    property bool development: false
    property bool busy: false
    property bool canInstall: false
    property bool cliInstalled: false
    property int installs: 0
    property int checks: 0
    function refresh() { checks++ }
    function enableCli() { installs++; cliInstalled=true }
    function disableCli() { cliInstalled=false }
  }
  Omamail.BackendSetup {
    id: page
    width: 680
    runtime: runtime
    textColor: Qt.rgba(1,1,1,1)
    dimColor: Qt.rgba(0.6,0.6,0.6,1)
    accentColor: Qt.rgba(0.5,0.6,1,1)
    panelFontFamily: "monospace"
  }
  TestCase {
    name: "BackendSetup"
    when: windowShown
    SignalSpy { id: diagnosis; target: page; signalName: "diagnosisRequested" }
    function test_diagnosis_does_not_require_a_ready_backend() {
      runtime.state = "error"
      page.diagnosisAvailable = true
      diagnosis.clear()
      var button = findChild(page, "backend-diagnose")
      verify(waitForRendering(page))
      verify(button.visible && button.enabled)
      mouseClick(button)
      compare(diagnosis.count, 1)
      page.diagnosing = true
      compare(button.enabled, false)
      page.diagnosing = false
      page.diagnosisAvailable = false
      runtime.state = "ready"
    }
    function init() {
      runtime.error = ""
      runtime.installedVersion = "0.9.0"
      runtime.developmentExecutable = ""
      runtime.development = false
      runtime.cliInstalled=false
      runtime.installs=0
      runtime.busy=false
      page.visible=true
      wait(0)
    }
    function renderedText(item, value) {
      if (item.text !== undefined && item.text === value && item.textFormat !== undefined) return item
      var children = item.children || []
      for (var childIndex = 0; childIndex < children.length; childIndex++) {
        var match = renderedText(children[childIndex], value)
        if (match) return match
      }
      return null
    }
    function test_runtime_values_are_literal_text_data() {
      return [{tag: "error", field: "error"}, {tag: "version", field: "installedVersion"},
        {tag: "development-path", field: "developmentExecutable"}]
    }
    function test_runtime_values_are_literal_text(data) {
      var markup = '<a href="https://example.test/">runtime</a>'
      var original = runtime[data.field]
      runtime[data.field] = markup
      runtime.development = data.field === "developmentExecutable"
      var expected = data.field === "error" ? markup
        : data.field === "installedVersion" ? "Backend " + markup + " is installed."
        : "Development executable: " + markup + ". Build the required version, then check again."
      var label = renderedText(page, expected)
      verify(label)
      compare(label.textFormat, Text.PlainText)
      for (var x = 1; x < label.width; x += 3) compare(label.linkAt(x, label.height / 2), "")
      runtime[data.field] = original
      runtime.development = false
    }
    function test_check_is_ghost_beside_version() {
      var check=findChild(page,"backend-refresh")
      var version=findChild(page,"backend-version-label")
      compare(check.text,"Check")
      compare(check.bordered,false)
      compare(check.parent,version.parent)
      verify(check.x>=version.x+version.width)
    }
    function test_install_changes_button_and_hint() {
      var button=findChild(page,"backend-install-cli")
      compare(button.text,"Install CLI")
      verify(button.enabled)
      mouseClick(button)
      compare(runtime.installs,1)
      compare(button.text,"Remove CLI")
      verify(button.enabled)
      verify(findChild(page,"backend-cli-note").text.indexOf("is linked")>=0)
      mouseClick(button)
      compare(runtime.installs,1)
      compare(button.text,"Install CLI")
      verify(!runtime.cliInstalled)
    }
    function test_existing_link_and_reopen() {
      runtime.cliInstalled=true
      var button=findChild(page,"backend-install-cli")
      compare(button.text,"Remove CLI")
      verify(button.enabled)
      page.visible=false
      var before=runtime.checks
      page.visible=true
      compare(runtime.checks,before+1)
    }
  }
}

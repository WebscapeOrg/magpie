import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui

Column {
  id: root
  required property var runtime
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily
  property string backendError: ""
  property bool diagnosisAvailable: false
  property bool diagnosing: false
  signal diagnosisRequested()
  spacing: MailStyle.space(12)
  onVisibleChanged: {
    if (visible && runtime && !runtime.busy && typeof runtime.refresh === "function") runtime.refresh()
  }
  MagpieLogo {
    foreground: root.dimColor
    accent: root.accentColor
  }
  Text {
    text: "Mail backend"
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.heading
  }
  Row {
    width: parent.width
    height: Math.max(versionLabel.height, checkButton.height)
    spacing: MailStyle.space(8)
    Text {
      id: versionLabel
      textFormat: Text.PlainText
      objectName: "backend-version-label"
      width: Math.min(implicitWidth, Math.max(0, parent.width - checkButton.width - parent.spacing))
      y: (parent.height - height) / 2
      wrapMode: Text.WordWrap
      text: !root.runtime ? "Checking the mail backend"
        : root.runtime.busy ? "Working"
        : root.runtime.state === "ready" ? (root.runtime.bundled
          ? "Bundled backend " + root.runtime.installedVersion + " is ready."
          : "Backend " + root.runtime.installedVersion + " is installed.")
        : root.runtime.bundled ? "The bundled mail backend could not start."
        : "Magpie needs backend " + (root.runtime.requiredVersion || "matching this plugin")
          + (root.runtime.installedVersion ? ". Installed: " + root.runtime.installedVersion : ". It is not installed yet.")
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.body
    }
    Widgets.Button {
      id: checkButton
      objectName: "backend-refresh"
      y: (parent.height - height) / 2
      bordered: false
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      text: root.runtime && root.runtime.bundled ? "Retry" : "Check"
      enabled: !!root.runtime && !root.runtime.busy
      foreground: root.textColor
      onClicked: root.runtime.refresh()
    }
  }
  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: root.runtime && root.runtime.bundled
      ? "Included with this app. Reinstall this version if the bundled backend is missing or damaged."
      : root.runtime && root.runtime.development
      ? "Development executable: " + root.runtime.developmentExecutable + ". Build the required version, then check again."
      : "Required for the app’s mail features. The backend is installed and managed inside this plugin."
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.body
  }
  Text {
    width: parent.width
    visible: text !== ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    text: root.runtime && root.runtime.error ? root.runtime.error : root.backendError
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.body
  }
  Flow {
    width: parent.width
    spacing: MailStyle.space(8)
    Widgets.Button {
      bordered: true
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      objectName: "backend-install"
      visible: !!root.runtime && !root.runtime.bundled && !root.runtime.development
        && root.runtime.state !== "ready"
      enabled: !!root.runtime && root.runtime.canInstall
      text: root.runtime && root.runtime.installedVersion ? "Update backend" : "Install backend"
      foreground: root.accentColor
      onClicked: root.runtime.install()
    }
    IconButton {
      objectName: "backend-diagnose"
      visible: root.diagnosisAvailable
      enabled: !root.diagnosing
      iconName: "agent"
      iconSize: Style.font.iconSmall
      size: MailStyle.space(24)
      tooltipText: "Diagnose with AI..."
      Accessible.role: Accessible.Button
      Accessible.name: "Diagnose with AI..."
      foreground: root.textColor
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      onClicked: root.diagnosisRequested()
    }
  }
  Column {
    width: parent.width
    spacing: MailStyle.space(8)
    visible: !!root.runtime && !root.runtime.bundled && !root.runtime.development
      && root.runtime.state === "ready"
    Text {
      text: "CLI command"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.body
      font.bold: true
    }
    Widgets.Button {
      id: installCli
      objectName: "backend-install-cli"
      visible: !!root.runtime && !root.runtime.bundled && !root.runtime.development
        && root.runtime.state === "ready"
      bordered: true
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      text: root.runtime && root.runtime.cliInstalled ? "Remove CLI" : "Install CLI"
      enabled: !!root.runtime && !root.runtime.busy
      foreground: root.textColor
      onClicked: {
        if (root.runtime.cliInstalled) root.runtime.disableCli()
        else root.runtime.enableCli()
      }
    }
    Text {
      width: parent.width
      objectName: "backend-cli-note"
      visible: installCli.visible
      wrapMode: Text.WordWrap
      text: root.runtime && root.runtime.cliInstalled
        ? "omamail is linked in ~/.local/bin. Remove CLI deletes only this link; the mail backend stays installed."
        : "Optional. Links the installed backend to ~/.local/bin/omamail on your PATH for use in the terminal."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
    }
  }
}

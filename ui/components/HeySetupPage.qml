import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui

Column {
  id: root

  required property var service
  required property color textColor
  required property color dimColor
  required property color dangerColor
  required property color accentColor
  required property string panelFontFamily
  property int accountCount: 1

  signal removeRequested()

  readonly property var auth: service ? service.auth : null
  readonly property bool checked: !!auth && auth.toolsChecked
  readonly property bool installed: !!auth && auth.toolsPresent
  readonly property bool signedIn: !!auth && auth.loggedIn
  readonly property bool busy: !!auth && auth.loginBusy

  // Invariant: this is a displayed installation command, not permission to pipe a remote script
  // into a shell.
  readonly property string installCommand: "curl -fsSL https://hey.com/install-cli | bash"

  spacing: MailStyle.space(16)


  ProviderHero {
    width: parent.width
    providerId: "hey"
    title: "Add a HEY mailbox"
    detail: "HEY does not speak IMAP or POP. Magpie reads it through the HEY CLI, the client 37signals publish for exactly this — install it once, then sign in here."
    textColor: root.textColor
    dimColor: root.dimColor
    panelFontFamily: root.panelFontFamily
    onWebsiteRequested: if (root.service) root.service.openProviderWebsite("hey")
  }


  Column {
    width: parent.width
    visible: root.checked && !root.installed
    spacing: MailStyle.space(10)

    Row {
      spacing: 0

      Text {
        text: "Install the "
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        font.bold: true
      }

      LinkLabel {
        text: "HEY CLI"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        font.bold: true
        tooltipText: "Open the HEY CLI on GitHub"
        onActivated: if (root.service) root.service.openProviderClient("hey")
      }
    }

    Text {
      width: parent.width
      text: "Run this in a terminal:"
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }

    Rectangle {
      width: parent.width
      implicitHeight: commandText.implicitHeight + MailStyle.space(20)
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.textColor, root.accentColor)
      border.width: 1
      border.color: Style.hoverBorderFor(root.textColor, root.accentColor)

      TextEdit {
        id: commandText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: MailStyle.space(12)
        anchors.verticalCenter: parent.verticalCenter
        text: root.installCommand
        textFormat: TextEdit.PlainText
        readOnly: true
        selectByMouse: true
        wrapMode: TextEdit.WrapAnywhere
        color: root.textColor
        selectedTextColor: root.textColor
        selectionColor: Style.selectedFillFor(root.textColor, root.accentColor)
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
      }
    }

    Text {
      width: parent.width
      text: "Recent versions of Omarchy install it for you — omarchy-mise-install github:basecamp/hey-cli hey does the same thing. Either way it lands in ~/.local/bin."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }

    Widgets.Button {
      text: "Check again"
      foreground: root.textColor
      bordered: true
      fontSize: MailStyle.bodySmall
      onClicked: if (root.auth) root.auth.recheck()
    }
  }


  Column {
    width: parent.width
    visible: root.installed && !root.signedIn
    spacing: MailStyle.space(10)

    Text {
      width: parent.width
      text: "Sign in to HEY"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      font.bold: true
    }

    Text {
      width: parent.width
      text: "This opens HEY in your browser. The token comes back to the HEY CLI, which keeps it in your keyring and refreshes it — Magpie never holds it and never asks for your HEY password."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }

    Row {
      spacing: MailStyle.space(8)

      Widgets.Button {
        visible: !root.busy
        text: "Sign in to HEY..."
        foreground: root.textColor
        bordered: true
        fontSize: MailStyle.bodySmall
        onClicked: if (root.service) root.service.signIn()
      }

      Widgets.Button {
        visible: root.busy
        text: "Cancel"
        foreground: root.textColor
        bordered: true
        fontSize: MailStyle.bodySmall
        onClicked: if (root.service) root.service.cancelSignIn()
      }

      Text {
        visible: root.busy
        anchors.verticalCenter: parent.verticalCenter
        text: "Waiting for the browser"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }
    }
  }


  Column {
    width: parent.width
    visible: root.signedIn
    spacing: MailStyle.space(4)

    Text {
      width: parent.width
      text: "Connected"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      font.bold: true
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.service && root.service.accountAddress !== ""
        ? root.service.accountAddress + " — signed in through the HEY CLI."
        : "Signed in through the HEY CLI."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }
  }

  Text {
    id: errorText
    width: parent.width
    visible: text !== ""
    textFormat: Text.PlainText
    text: root.auth ? root.auth.lastError : ""
    color: root.dangerColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }


  Column {
    width: parent.width
    spacing: MailStyle.space(4)

    Text {
      width: parent.width
      text: "What is different about HEY"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      font.bold: true
    }

    Text {
      width: parent.width
      text: "No star and no archive — HEY has neither. A thread is moved to Set Aside, Reply Later or Paper Trail instead, and those are mailboxes in the rail. No Sent either: the HEY CLI does not serve one yet. Reading, marking read, replying, searching, labels and reporting spam all work. A row here is one conversation rather than one message, and attachments and the Screener stay in HEY's own app."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }
  }

  Row {
    spacing: MailStyle.space(8)

    Widgets.Button {
      visible: root.signedIn
      text: "Sign out of HEY"
      foreground: root.textColor
      bordered: true
      fontSize: MailStyle.bodySmall
      onClicked: if (root.service) root.service.signOut()
    }

    Widgets.Button {
      visible: root.accountCount > 1
      text: "Remove account"
      foreground: root.dangerColor
      bordered: false
      fontSize: MailStyle.bodySmall
      onClicked: root.removeRequested()
    }
  }

  // Invariant: signing out affects the shared HEY CLI credential, including other applications that
  // use it.
  Text {
    width: parent.width
    visible: root.signedIn
    text: "Signing out signs the HEY CLI out, so anything else on this machine that uses it — the HEY terminal app, the bar plugin — is signed out too."
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }
}

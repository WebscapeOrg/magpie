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
  property bool secretVisible: false
  property bool detailVisible: false
  // Invariant: keep reopen state separate from the step’s done binding so saving can close it
  // again.
  property bool clientStepReopened: false

  signal removeRequested()

  readonly property var auth: service ? service.auth : null
  readonly property bool configured: !!auth && auth.credentialsPresent
  readonly property bool signedIn: !!auth && auth.loggedIn
  readonly property bool addingMailbox: configured && !signedIn
    && !!service && service.accountEmail === ""
  readonly property bool toolsMissing: !!auth && auth.toolsChecked && auth.missingTools.length > 0

  spacing: MailStyle.space(16)

  function syncFromStore() {
    nameField.syncFromStore()
    if (!auth) return
    clientIdField.text = String(auth.clientId || "")
    clientSecretField.text = auth.credentials ? String(auth.credentials.clientSecret || "") : ""
  }

  function saveName() {
    if (service && nameField.value() !== String(service.accountName || ""))
      service.configureCurrentAccount({ label: nameField.value() })
  }

  function signInNamed() {
    if (!service) return
    saveName()
    service.signIn()
  }

  function save() {
    if (!auth) return
    saveName()
    var secret = clientSecretField.text.trim()
    // Invariant: retain the saved client secret in the masked field; clearing it falsely implied
    // the credential was lost.
    auth.saveCredentials(clientIdField.text.trim() + (secret === "" ? "" : "\n" + secret))
  }

  Component.onCompleted: syncFromStore()

  Connections {
    target: root.auth
    ignoreUnknownSignals: true
    function onClientIdChanged() { root.syncFromStore() }
    function onCredentialsSaved() {
      root.syncFromStore()
      root.clientStepReopened = false
    }
  }


  ProviderHero {
    width: parent.width
    providerId: "gmail"
    title: root.addingMailbox ? "Add a Gmail mailbox" : "Connect your Gmail mailbox"
    detail: "Google issues Gmail API access per project, so this app signs in with an OAuth client you own. About two minutes, once."
    textColor: root.textColor
    dimColor: root.dimColor
    panelFontFamily: root.panelFontFamily
    onWebsiteRequested: if (root.service) root.service.openProviderWebsite("gmail")
  }

  // Invariant: the mailbox name sits outside the shared-client step because that step is already
  // complete when adding another Gmail account.
  AccountNameField {
    id: nameField
    service: root.service
    width: parent.width
    foreground: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
  }

  Rectangle {
    width: parent.width
    visible: root.toolsMissing
    implicitHeight: missingText.implicitHeight + MailStyle.space(20)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)
    border.width: 1
    border.color: Style.hoverBorderFor(root.textColor, root.accentColor)

    Text {
      id: missingText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: MailStyle.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: root.auth
        ? "Install " + root.auth.missingTools.join(", ")
          + " first — they run the sign-in listener and the keyring."
        : ""
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }
  }


  Step {
    number: "1"
    title: "Create a client in Google Cloud"
    done: root.configured && !root.clientStepReopened
    doneSummary: root.auth ? "Client connected · " + root.auth.clientDescription : ""
    reopenable: true

    Column {
      width: parent.width
      spacing: MailStyle.space(10)

      Text {
        width: parent.width
        text: "Create an OAuth client with application type Desktop app, and enable the Gmail API on the same project."
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }

      Row {
        spacing: MailStyle.space(8)

        Widgets.Button {
          text: "Open Google Cloud..."
          foreground: root.textColor
          bordered: true
          fontSize: MailStyle.bodySmall
          onClicked: root.service.openCloudConsole()
        }

        Widgets.Button {
          text: "Enable Gmail API..."
          foreground: root.textColor
          bordered: true
          fontSize: MailStyle.bodySmall
          onClicked: root.service.openGmailApiPage()
        }
      }

      Widgets.TextField {
        id: clientIdField
        width: parent.width
        foreground: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "Client ID — 000000-xxxx.apps.googleusercontent.com"
        onAccepted: clientSecretField.forceActiveFocus()
      }

      Item {
        width: parent.width
        implicitHeight: clientSecretField.implicitHeight

        Widgets.TextField {
          id: clientSecretField
          anchors.left: parent.left
          anchors.right: parent.right
          password: !root.secretVisible
          rightPadding: horizontalPadding + MailStyle.space(26)
          foreground: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          placeholderText: "Client secret — optional"
          onAccepted: root.save()
        }

        IconButton {
          anchors.right: parent.right
          anchors.rightMargin: MailStyle.space(4)
          anchors.verticalCenter: clientSecretField.verticalCenter
          visible: clientSecretField.text !== ""
          iconName: root.secretVisible ? "eyeOff" : "eye"
          tooltipText: root.secretVisible ? "Hide the secret" : "Show the secret"
          foreground: root.dimColor
          hoverColor: root.textColor
          iconSize: Style.font.iconSmall
          size: MailStyle.space(22)
          fontFamily: root.panelFontFamily
          onClicked: root.secretVisible = !root.secretVisible
        }
      }

      Widgets.Button {
        text: "Save client"
        foreground: root.textColor
        bordered: true
        fontSize: MailStyle.bodySmall
        enabled: !!root.auth && !root.auth.credentialsWriteBusy
        onClicked: root.save()
      }
    }
  }


  Step {
    number: "2"
    title: "Sign in"
    done: root.signedIn
    doneSummary: root.service ? "Signed in as " + root.service.accountEmail : ""
    waiting: !root.configured

    Column {
      width: parent.width
      spacing: MailStyle.space(10)

      // Invariant: a Google Cloud project left in Testing issues seven-day refresh tokens; keep
      // that setup constraint visible beside sign-in.
      Text {
        width: parent.width
        text: "Press \"Publish app\" on your project first, or Google expires the session every seven days. An \"unverified app\" warning is expected — you are the developer."
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }

      Row {
        spacing: MailStyle.space(8)

        Widgets.Button {
          text: "Sign in with Google..."
          foreground: root.textColor
          bordered: true
          fontSize: MailStyle.bodySmall
          enabled: !!root.auth && !root.auth.loginBusy
          onClicked: root.signInNamed()
        }

        Widgets.Button {
          text: "Consent screen..."
          foreground: root.dimColor
          bordered: false
          fontSize: MailStyle.bodySmall
          onClicked: root.service.openConsentScreen()
        }

        Widgets.Button {
          visible: !!root.auth && root.auth.loginBusy
          text: "Cancel"
          foreground: root.dimColor
          bordered: false
          fontSize: MailStyle.bodySmall
          onClicked: root.service.cancelSignIn()
        }
      }

      Text {
        width: parent.width
        visible: !!root.service && root.service.signInProgress !== ""
        text: root.service ? root.service.signInProgress : ""
        textFormat: Text.PlainText
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  Row {
    visible: root.signedIn || root.accountCount > 1
    spacing: MailStyle.space(8)
    anchors.left: parent.left
    anchors.leftMargin: signOutButton.visible ? 0 : -removeButton.horizontalPadding

    Widgets.Button {
      id: signOutButton
      visible: root.signedIn
      text: "Sign out"
      foreground: root.textColor
      bordered: true
      fontSize: MailStyle.bodySmall
      onClicked: if (root.service) root.service.signOut()
    }

    Widgets.Button {
      id: removeButton
      visible: root.accountCount > 1
      text: "Remove account"
      foreground: root.dangerColor
      bordered: false
      fontSize: MailStyle.bodySmall
      onClicked: root.removeRequested()
    }
  }


  Text {
    width: parent.width
    visible: !!root.auth && root.auth.lastError !== ""
    textFormat: Text.PlainText
    text: root.auth ? root.auth.lastError : ""
    color: root.dangerColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }

  PanelSeparator {
    width: parent.width
    foreground: root.textColor
  }

  Widgets.Button {
    id: detailToggle
    text: root.detailVisible ? "Hide the details" : "Need more detail?"
    foreground: root.dimColor
    bordered: false
    leftAlign: true
    anchors.left: parent.left
    anchors.leftMargin: -detailToggle.horizontalPadding
    fontSize: MailStyle.caption
    onClicked: root.detailVisible = !root.detailVisible
  }

  Text {
    width: parent.width
    visible: root.detailVisible
    textFormat: Text.PlainText
    text: "In Google Cloud, pick or create a project. Under APIs and Services, enable the Gmail API. "
      + "On the consent screen add the Gmail address you want to read as a test user, then press Publish app. "
      + "Under Credentials, create an OAuth client with application type Desktop app, and paste its client ID above.\n\n"
      + "Steps one and two have a CLI: run scripts/google-cloud-project.sh if you have gcloud. "
      + "The consent screen and the client itself are console-only.\n\n"
      + (root.auth ? "The client is saved to " + root.auth.credentialsPath + ", readable only by you. "
        + "You can also copy the JSON the console downloads to that path instead of pasting. " : "")
      + "The refresh token goes to GNOME Keyring; the access token never leaves memory."
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
  }

  component Step: Item {
    id: step
    required property string number
    required property string title
    property bool done: false
    property bool waiting: false
    property bool reopenable: false
    property string doneSummary: ""
    default property alias content: bodyHolder.data

    readonly property bool active: !done && !waiting

    width: root.width
    implicitHeight: stepColumn.implicitHeight
    opacity: step.waiting ? 0.45 : 1.0

    Item {
      id: marker
      anchors.left: parent.left
      anchors.top: parent.top
      width: MailStyle.space(20)
      implicitHeight: MailStyle.space(18)

      Text {
        anchors.left: parent.left
        anchors.top: parent.top
        visible: !step.done
        text: step.number
        color: step.active ? root.accentColor : root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        font.bold: step.active
      }

      ActionIcon {
        anchors.left: parent.left
        anchors.top: parent.top
        visible: step.done
        name: "check"
        iconSize: MailStyle.bodySmall
        color: root.accentColor
      }
    }

    Widgets.Button {
      id: reopen
      anchors.right: parent.right
      anchors.top: parent.top
      visible: step.done && step.reopenable
      text: "Change..."
      foreground: root.dimColor
      bordered: false
      fontSize: MailStyle.caption
      onClicked: root.clientStepReopened = true
    }

    Column {
      id: stepColumn
      anchors.left: marker.right
      anchors.right: reopen.visible ? reopen.left : parent.right
      anchors.top: parent.top
      spacing: MailStyle.space(8)

      Text {
        width: parent.width
        text: step.done && step.doneSummary !== "" ? step.doneSummary : step.title
        textFormat: Text.PlainText
        color: step.done ? root.dimColor : root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        font.bold: !step.done
        elide: Text.ElideRight
      }

      // Invariant: use the single child’s implicitHeight; childrenRect closes a sizing loop through
      // this holder.
      Item {
        id: bodyHolder
        width: parent.width
        visible: step.active
        implicitHeight: visible && children.length > 0 ? children[0].implicitHeight : 0
      }
    }
  }
}

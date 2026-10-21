import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui
import "../providers/JmapProtocol.js" as Jmap
import "../account/Accounts.js" as Accounts

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
  property bool serversVisible: false

  signal removeRequested()

  readonly property var auth: service ? service.auth : null
  readonly property bool signedIn: !!auth && auth.loggedIn === true
  readonly property bool busy: !!auth && auth.loginBusy === true
  readonly property bool toolsMissing: !!auth && auth.toolsChecked === true
    && auth.missingTools !== undefined && auth.missingTools.length > 0
  readonly property bool rejected: !!service && service.credentialsRejected === true
  readonly property int step: auth && auth.progressStep !== undefined ? auth.progressStep : 0

  readonly property var settings: auth && auth.settings ? auth.settings : null
  readonly property string host: settings ? Jmap.sessionHost(settings.sessionUrl) : ""
  readonly property string schemeLabel: settings ? Jmap.schemeLabel(settings.authScheme) : ""
  readonly property bool sendingRefused: signedIn && !!auth && auth.sendingOffered === false

  spacing: MailStyle.space(16)

  function syncFromStore() {
    nameField.syncFromStore()
    addressField.text = service ? service.accountAddress : ""
    var values = root.settings
    if (!values) return
    if (String(values.username || "") !== "") usernameField.text = String(values.username)
    if (String(values.sessionUrl || "") !== "") serverField.text = String(values.sessionUrl)
  }

  // Invariant: the window’s setup context owns focus; account state changes must not steal it.
  function clearSecret() {
    secretField.text = ""
  }

  function openServerField() {
    serversVisible = true
  }

  // Invariant: validate the address before accountId can turn an invalid address into a pending
  // mailbox.
  function validatedAddress() {
    var address = addressField.text.trim()
    if (Accounts.isValidEmail(address)) return address
    errorText.text = address === ""
      ? "Add the email address for this mailbox"
      : "That is not a full email address"
    return ""
  }

  // Invariant: persist editable server configuration before trying credentials so refusal does not
  // erase it.
  function settingsFrom(typedServer) {
    var values = root.settings || {}
    return {
      sessionUrl: typedServer,
      username: usernameField.text.trim(),
      authScheme: String(values.authScheme || ""),
      accountId: String(values.accountId || "")
    }
  }

  function plannedServer(address) {
    var plan = Jmap.discoveryPlan(address, serverField.text)
    if (plan.error !== "") {
      errorText.text = plan.error
      openServerField()
      return null
    }
    var first = plan.steps.length > 0 ? plan.steps[0] : null
    return first && first.kind === Jmap.STEP_TYPED ? first.url : ""
  }

  function signIn() {
    if (!service) return
    var address = validatedAddress()
    if (address === "") return
    var server = plannedServer(address)
    if (server === null) return
    errorText.text = ""
    service.configureCurrentAccountAndSignIn({
      provider: "jmap",
      email: address,
      jmap: settingsFrom(server),
      label: nameField.value()
    }, secretField.text)
  }

  // Invariant: saving server settings re-verifies the connection; persisted values alone do not
  // prove sign-in.
  function save() {
    signIn()
  }

  Component.onCompleted: {
    syncFromStore()
    if (rejected) clearSecret()
  }

  onRejectedChanged: if (rejected) clearSecret()

  Connections {
    target: root.auth
    ignoreUnknownSignals: true
    function onLastErrorChanged() {
      if (root.auth && root.auth.lastError !== "") errorText.text = root.auth.lastError
    }
    // Invariant: failed automatic discovery must expose the server field needed to continue.
    function onServerNeededChanged() {
      if (root.auth && root.auth.serverNeeded) root.openServerField()
    }
    // Invariant: successful discovery replaces the typed server with the session URL actually in
    // use.
    function onSessionVerified(result) {
      errorText.text = ""
      var url = result ? String(result.sessionUrl || "") : ""
      if (url !== "") serverField.text = url
    }
  }


  ProviderHero {
    width: parent.width
    providerId: "jmap"
    title: "Add a JMAP mailbox"
    detail: "Any mailbox on a server that speaks JMAP. It signs in with an app password or an API token, never your account password."
    textColor: root.textColor
    dimColor: root.dimColor
    panelFontFamily: root.panelFontFamily
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
      text: root.auth && root.auth.missingTools
        ? "Install " + root.auth.missingTools.join(", ")
          + " first — they hold the app password and talk to the server."
        : ""
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }
  }


  Column {
    width: parent.width
    spacing: MailStyle.space(10)

    AccountNameField {
      id: nameField
      service: root.service
      width: parent.width
      foreground: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      onAccepted: addressField.forceActiveFocus()
    }

    Widgets.TextField {
      id: addressField
      objectName: "jmap-address-field"
      width: parent.width
      foreground: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      placeholderText: "Email address — you@example.com"
      onAccepted: secretField.forceActiveFocus()
    }

    Rectangle {
      width: parent.width
      implicitHeight: noteText.implicitHeight + MailStyle.space(20)
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.textColor, root.accentColor)
      border.width: 1
      border.color: Style.hoverBorderFor(root.textColor, root.accentColor)

      Text {
        id: noteText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: MailStyle.space(12)
        anchors.verticalCenter: parent.verticalCenter
        text: "Most servers want an app password or an API token made for this client, not the password you sign in to the website with. Your provider's security settings are where to create one."
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }
    }

    Item {
      width: parent.width
      implicitHeight: secretField.implicitHeight

      Widgets.TextField {
        id: secretField
        objectName: "jmap-secret-field"
        anchors.left: parent.left
        anchors.right: parent.right
        password: !root.secretVisible
        rightPadding: horizontalPadding + MailStyle.space(26)
        foreground: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "App password, or API token"
        onAccepted: root.signIn()
      }

      IconButton {
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(4)
        anchors.verticalCenter: secretField.verticalCenter
        visible: secretField.text !== ""
        iconName: root.secretVisible ? "eyeOff" : "eye"
        tooltipText: root.secretVisible ? "Hide the app password" : "Show the app password"
        foreground: root.dimColor
        hoverColor: root.textColor
        iconSize: Style.font.iconSmall
        size: MailStyle.space(22)
        fontFamily: root.panelFontFamily
        onClicked: root.secretVisible = !root.secretVisible
      }
    }

    Text {
      id: errorText
      objectName: "jmap-error"
      width: parent.width
      visible: text !== "" && !root.rejected
      textFormat: Text.PlainText
      text: ""
      color: root.dangerColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }
  }


  Column {
    id: progress
    width: parent.width
    visible: root.busy
    spacing: MailStyle.space(6)

    readonly property var lines: [
      "Finding the server", "Checking the app password", "Reading your mailboxes"]

    Repeater {
      model: progress.lines

      Row {
        id: line
        required property string modelData
        required property int index

        readonly property bool done: root.step > index + 1
        readonly property bool running: root.step === index + 1

        spacing: MailStyle.space(8)

        ActionIcon {
          anchors.verticalCenter: parent.verticalCenter
          visible: line.done
          name: "check"
          iconSize: MailStyle.caption
          color: root.accentColor
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: !line.done
          text: "·"
          color: line.running ? root.accentColor : root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          font.bold: line.running
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: line.modelData
          color: line.running ? root.textColor : root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          font.bold: line.running
        }
      }
    }
  }


  Column {
    width: parent.width
    visible: root.signedIn && !root.rejected
    spacing: MailStyle.space(4)

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.host !== ""
        ? "Signed in · " + root.host + " · " + root.schemeLabel
        : "Signed in"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      font.bold: true
      elide: Text.ElideRight
    }

    // Invariant: lack of submission support does not invalidate a mailbox’s read capability.
    Text {
      width: parent.width
      visible: root.sendingRefused
      text: "Sending is not offered: this credential cannot submit mail."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }
  }


  Rectangle {
    width: parent.width
    visible: root.rejected
    implicitHeight: rejectedText.implicitHeight + MailStyle.space(20)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)
    border.width: 1
    border.color: Style.hoverBorderFor(root.textColor, root.accentColor)

    Text {
      id: rejectedText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: MailStyle.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: "The server rejected that app password or API token. Enter it again — it may have expired or been revoked."
      color: root.dangerColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }
  }


  Column {
    width: parent.width
    spacing: MailStyle.space(10)

    IconTextButton {
      objectName: "jmap-server-disclosure"
      iconName: root.serversVisible ? "chevronDown" : "chevronRight"
      text: root.serversVisible
        ? "Hide the server settings"
        : (root.host !== "" ? "Server settings — " + root.host : "Server settings")
      foreground: root.dimColor
      fontFamily: root.panelFontFamily
      fontSize: MailStyle.caption
      onClicked: root.serversVisible = !root.serversVisible
    }

    Column {
      width: parent.width
      visible: root.serversVisible
      spacing: MailStyle.space(8)

      Widgets.TextField {
        id: serverField
        objectName: "jmap-server-field"
        width: parent.width
        foreground: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "Server — mail.example.org, or the full session URL"
      }

      Widgets.TextField {
        id: usernameField
        objectName: "jmap-username-field"
        width: parent.width
        foreground: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "Username — only if it is not the address"
      }

      Text {
        width: parent.width
        text: "Left empty, the server is looked up from the address's domain. HTTPS only, and the credential goes to the server that answered and to the addresses inside its own session object."
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  Row {
    spacing: MailStyle.space(8)

    Widgets.Button {
      visible: !root.signedIn && !root.rejected
      text: root.busy ? "Checking" : "Connect the mailbox"
      enabled: !root.busy && addressField.text.trim() !== "" && secretField.text !== ""
      foreground: root.textColor
      bordered: true
      fontSize: MailStyle.bodySmall
      onClicked: root.signIn()
    }

    Widgets.Button {
      visible: root.rejected
      text: root.busy ? "Checking" : "Sign in again"
      enabled: !root.busy && secretField.text !== ""
      foreground: root.textColor
      bordered: true
      fontSize: MailStyle.bodySmall
      onClicked: root.signIn()
    }

    Widgets.Button {
      visible: root.signedIn && !root.rejected
      text: "Save changes"
      enabled: !root.busy
      foreground: root.textColor
      bordered: true
      fontSize: MailStyle.bodySmall
      onClicked: root.save()
    }

    // Invariant: sign-out must not race a credential write in progress.
    Widgets.Button {
      visible: root.signedIn && !root.rejected
      text: "Sign out"
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
}

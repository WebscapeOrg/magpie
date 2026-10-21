import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui
import "../providers/ImapProtocol.js" as Imap
import "../account/Accounts.js" as Accounts
import "../account/Aliases.js" as Aliases

Column {
  id: root

  required property var service
  required property color textColor
  required property color dimColor
  required property color dangerColor
  required property color accentColor
  required property string panelFontFamily
  property int accountCount: 1
  property bool passwordVisible: false
  property bool serversVisible: false

  signal removeRequested()

  readonly property var auth: service ? service.auth : null
  readonly property bool signedIn: !!auth && auth.loggedIn
  readonly property bool busy: !!auth && auth.loginBusy
  readonly property bool toolsMissing: !!auth && auth.toolsChecked && auth.missingTools.length > 0

  readonly property var suggestion: Imap.suggestedSettings(addressField.text)

  spacing: MailStyle.space(16)

  function currentSettings() {
    return Imap.setupSettings({
      address: addressField.text,
      imapHost: imapHostField.text.trim(),
      imapPort: imapPortField.text,
      smtpHost: smtpHostField.text.trim(),
      smtpPort: smtpPortField.text,
      username: usernameField.text,
      aliases: aliasesField.text
    })
  }

  // Invariant: automatically suggested servers must not overwrite fields the user edited.
  property bool serversTouched: false

  function applySuggestion() {
    if (serversTouched) return
    // Invariant: onTextChanged can precede the suggestion binding; derive from the field’s current
    // text.
    var current = Imap.suggestedSettings(addressField.text)
    imapHostField.text = current.imapHost
    imapPortField.text = String(current.imapPort)
    smtpHostField.text = current.smtpHost
    smtpPortField.text = String(current.smtpPort)
  }

  function syncFromStore() {
    nameField.syncFromStore()
    senderField.syncFromStore()
    if (!auth || !auth.settings) return
    var settings = auth.settings
    addressField.text = service ? service.accountAddress : ""
    if (settings.username !== "") {
      usernameField.text = settings.username
    }
    if (settings.aliases) {
      aliasesField.text = Aliases.format(settings.aliases)
    }
    if (settings.imapHost !== "") {
      imapHostField.text = settings.imapHost
      imapPortField.text = String(settings.imapPort)
      smtpHostField.text = settings.smtpHost
      smtpPortField.text = String(settings.smtpPort)
      // Invariant: persisted server settings are user choices and must not be overwritten by
      // address suggestions.
      serversTouched = true
    }
  }

  // Invariant: setupSettings omits the address; validate it before accountId can turn an invalid
  // address into a pending mailbox.
  function validatedAddress() {
    var address = addressField.text.trim()
    if (Accounts.isValidEmail(address)) return address
    errorText.text = address === ""
      ? "Add the email address for this mailbox"
      : "That is not a full email address"
    return ""
  }

  // Invariant: save configuration before trying credentials so rejected sign-in leaves an editable
  // mailbox.
  function save() {
    if (!service) return
    var address = validatedAddress()
    if (address === "") return
    var check = Imap.validateSettings(currentSettings())
    if (!check.ok) {
      errorText.text = check.error
      return
    }
    errorText.text = ""
    service.configureCurrentAccount({
      provider: "imap",
      email: address,
      imap: check.settings,
      label: nameField.value(),
      senderName: senderField.value()
    })
  }

  function signIn() {
    if (!service) return
    var address = validatedAddress()
    if (address === "") return
    var check = Imap.validateSettings(currentSettings())
    if (!check.ok) {
      errorText.text = check.error
      return
    }
    errorText.text = ""
    service.configureCurrentAccountAndSignIn({
      provider: "imap",
      email: address,
      imap: check.settings,
      label: nameField.value(),
      senderName: senderField.value()
    }, passwordField.text)
  }

  Component.onCompleted: syncFromStore()

  Connections {
    target: root.auth
    ignoreUnknownSignals: true
    function onLastErrorChanged() {
      if (root.auth && root.auth.lastError !== "") errorText.text = root.auth.lastError
    }
  }


  Column {
    width: parent.width
    spacing: MailStyle.space(4)

    Text {
      width: parent.width
      text: "Add a mailbox"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.heading
      font.bold: true
    }

    Text {
      width: parent.width
      text: "Any mailbox that speaks IMAP — Fastmail, iCloud, Zoho, a server of your own. The address is usually all it takes."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      wrapMode: Text.WordWrap
    }
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
          + " first — they hold the password and talk to the server."
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
      onAccepted: (senderField.available ? senderField : addressField).forceActiveFocus()
    }

    SenderNameField {
      id: senderField
      service: root.service
      width: parent.width
      foreground: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      onAccepted: addressField.forceActiveFocus()
    }

    Widgets.TextField {
      id: addressField
      objectName: "imap-address-field"
      width: parent.width
      foreground: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      placeholderText: "Email address — you@example.com"
      onTextChanged: root.applySuggestion()
      onAccepted: passwordField.forceActiveFocus()
    }

    Rectangle {
      width: parent.width
      visible: root.suggestion.note !== ""
      implicitHeight: noteColumn.implicitHeight + MailStyle.space(20)
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.textColor, root.accentColor)
      border.width: 1
      border.color: Style.hoverBorderFor(root.textColor, root.accentColor)

      Column {
        id: noteColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: MailStyle.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: MailStyle.space(6)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.suggestion.note
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          wrapMode: Text.WordWrap
        }

        LinkLabel {
          objectName: "imap-password-guide"
          visible: root.suggestion.guideUrl !== ""
          text: root.suggestion.guideLabel + "..."
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
          tooltipText: root.suggestion.guideUrl
          onActivated: if (root.service && typeof root.service.openExternal === "function")
            root.service.openExternal(root.suggestion.guideUrl)
        }
      }
    }

    Item {
      width: parent.width
      implicitHeight: passwordField.implicitHeight

      Widgets.TextField {
        id: passwordField
        anchors.left: parent.left
        anchors.right: parent.right
        password: !root.passwordVisible
        rightPadding: horizontalPadding + MailStyle.space(26)
        foreground: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "Password, or app password"
        onAccepted: root.signIn()
      }

      IconButton {
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(4)
        anchors.verticalCenter: passwordField.verticalCenter
        visible: passwordField.text !== ""
        iconName: root.passwordVisible ? "eyeOff" : "eye"
        tooltipText: root.passwordVisible ? "Hide the password" : "Show the password"
        foreground: root.dimColor
        hoverColor: root.textColor
        iconSize: Style.font.iconSmall
        size: MailStyle.space(22)
        fontFamily: root.panelFontFamily
        onClicked: root.passwordVisible = !root.passwordVisible
      }
    }

    Text {
      id: errorText
      objectName: "imap-error"
      textFormat: Text.PlainText
      width: parent.width
      visible: text !== ""
      text: ""
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
      iconName: root.serversVisible ? "chevronDown" : "chevronRight"
      text: root.serversVisible ? "Hide the server settings" : "Server settings"
      foreground: root.dimColor
      fontFamily: root.panelFontFamily
      fontSize: MailStyle.caption
      onClicked: root.serversVisible = !root.serversVisible
    }

    Column {
      width: parent.width
      visible: root.serversVisible
      spacing: MailStyle.space(8)

      Row {
        width: parent.width
        spacing: MailStyle.space(8)

        Widgets.TextField {
          id: imapHostField
          width: parent.width - imapPortField.width - parent.spacing
          foreground: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          placeholderText: "IMAP server"
          onTextEdited: root.serversTouched = true
        }

        Widgets.TextField {
          id: imapPortField
          width: MailStyle.space(90)
          foreground: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          placeholderText: "IMAP port"
          onTextEdited: root.serversTouched = true
        }
      }

      Row {
        width: parent.width
        spacing: MailStyle.space(8)

        Widgets.TextField {
          id: smtpHostField
          width: parent.width - smtpPortField.width - parent.spacing
          foreground: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          placeholderText: "SMTP server — leave empty to read only"
          onTextEdited: root.serversTouched = true
        }

        Widgets.TextField {
          id: smtpPortField
          width: MailStyle.space(90)
          foreground: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
          placeholderText: "SMTP port"
          onTextEdited: root.serversTouched = true
        }
      }

      Widgets.TextField {
        id: usernameField
        width: parent.width
        foreground: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "Username — only if it is not the address"
      }

      Widgets.TextField {
        id: aliasesField
        objectName: "imap-aliases-field"
        width: parent.width
        foreground: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        placeholderText: "Send-as aliases — comma-separated (e.g. alias@icloud.com (default))"
      }
    }

    Text {
      width: parent.width
      visible: root.serversVisible
      text: "TLS on connect, or a required STARTTLS upgrade on ports 143, 25 and 587. Plain text is refused unless the server is on this machine."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }
  }

  Row {
    spacing: MailStyle.space(8)

    Widgets.Button {
      visible: !root.signedIn
      text: root.busy ? "Checking" : "Connect the mailbox"
      enabled: !root.busy && addressField.text.trim() !== "" && passwordField.text !== ""
      foreground: root.textColor
      bordered: true
      fontSize: MailStyle.bodySmall
      onClicked: root.signIn()
    }

    Widgets.Button {
      visible: root.signedIn
      text: "Save changes"
      foreground: root.textColor
      bordered: true
      fontSize: MailStyle.bodySmall
      onClicked: root.save()
    }

    Widgets.Button {
      visible: root.signedIn
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

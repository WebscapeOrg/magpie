import QtQuick
import "../controls" as Widgets
import "../settings"
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../message/Direction.js" as Direction
import "../settings/Appearance.js" as Appearance
import "../message/Html.js" as Html

Column {
  id: root

  required property var service
  required property var calendarController
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property color urgentColor
  required property string panelFontFamily

  signal clientSetupRequested()
  signal addRequested()
  signal editRequested(int index)
  signal openCalendarRequested()
  signal calendarSignInRequested(int index)
  signal restartRequested()
  property bool restartBusy: false
  property string restartStatus: ""
  property bool restartFailed: false

  readonly property var accounts: service ? service.accountSummaries : []
  // Invariant: live account summaries change during polling; a stable signature list preserves the
  // field being edited.
  readonly property var signatureAccounts: service
    && Array.isArray(service.accountSignatures) ? service.accountSignatures : []
  property string selectedSignatureAccountId: ""

  readonly property var sections: {
    var values = [{ key: "restart", title: "Restart", y: restartSection.y }, { key: "display", title: "Layout and fonts", y: displaySettings.y }, { key: "backend", title: "Mail backend", y: backendSetup.y }]
    if (!root.service || root.service.hasTray !== false)
      values.push({ key: "bar", title: "Bar", y: barHeading.y })
    if (root.service && root.service.hasMailto === true)
      values.push({ key: "mailClient", title: "Default mail client", y: mailClientHeading.y })
    values.push({ key: "reading", title: "Reading", y: readingHeading.y })
    if (!root.service || root.service.hasNotifications !== false
        || String(root.service.notificationError || "") !== "")
      values.push({ key: "notifications", title: "Notifications", y: notificationsHeading.y })
    values.push({ key: "writing", title: "Writing", y: writingHeading.y })
    values.push({ key: "mailboxes", title: "Mailboxes", y: mailboxesHeading.y })
    values.push({ key: "calendars", title: "Calendars", y: calendarsSection.y })
    values.push({ key: "phone", title: "iPhone", y: phoneSettings.y })
    values.push({ key: "oauth", title: "Google OAuth client", y: oauthHeading.y })
    return values
  }
  readonly property var auth: service ? service.auth : null

  function signatureAccount(id) {
    for (var entryIndex = 0; entryIndex < signatureAccounts.length; entryIndex++)
      if (String(signatureAccounts[entryIndex].id || "") === String(id || ""))
        return signatureAccounts[entryIndex]
    return null
  }

  readonly property var accountOptions: signatureAccounts.map(function(account) {
    return { value: account.id, label: account.email }
  })

  property string selectedNameAccountId: ""

  function saveName() {
    if (service && selectedNameAccountId !== "")
      service.setAccountLabel(selectedNameAccountId, nameEdit.text)
  }

  function showNameAccount(next) {
    selectedNameAccountId = next ? String(next.id || "") : ""
    nameEdit.text = next ? String(next.label || "") : ""
  }

  function selectNameAccount(id) {
    var next = signatureAccount(id)
    if (!next || String(next.id || "") === selectedNameAccountId) return
    saveName()
    showNameAccount(next)
  }

  function ensureNameAccount() {
    if (signatureAccounts.length === 0) {
      showNameAccount(null)
      return
    }
    if (signatureAccount(selectedNameAccountId)) return
    var activeId = service ? String(service.activeAccountId || "") : ""
    showNameAccount(signatureAccount(activeId) || signatureAccounts[0])
  }

  readonly property string selectedSignatureHtml: {
    var entry = signatureAccount(selectedSignatureAccountId)
    return entry ? String(entry.signatureHtml || "") : ""
  }
  property var selectedSignatureDocument: null
  property int signatureRenderSerial: 0
  onSelectedSignatureHtmlChanged: renderSignaturePreview()
  function renderSignaturePreview() {
    var serial = ++signatureRenderSerial
    selectedSignatureDocument = null
    if (!service || !service.backend || selectedSignatureHtml === "") return
    service.backend.call("message.render", {html: selectedSignatureHtml,
      options: {allowRemoteImages: false, withReader: false}}, function(result, error) {
      if (serial !== root.signatureRenderSerial) return
      if (!error && result) root.selectedSignatureDocument = result.document
    })
  }
  property bool importing: false
  property string importingAccountId: ""
  property string importNote: ""
  property bool importFailed: false
  property string importStage: ""

  function signatureImportNote(result) {
    if (result.problem) return String(result.problem)
    var parts = []
    if (result.images > 0) parts.push(result.images + (result.images === 1 ? " image" : " images"))
    if (result.dropped > 0) parts.push(result.dropped + " unsafe or unsupported "
      + (result.dropped === 1 ? "part" : "parts") + " removed")
    return parts.length ? "Imported: " + parts.join(", ") : "Imported"
  }

  function importSignature() {
    if (importing || !service || selectedSignatureAccountId === "") return
    importingAccountId = selectedSignatureAccountId
    importing = true
    importNote = ""
    importFailed = false
    importStage = "pick"
    if (typeof service.chooseFiles !== "function") {
      finishImport(JSON.stringify({ok:false,error:"No file picker is available"}))
      return
    }
    service.chooseFiles(function(result) { root.finishImport(JSON.stringify(result || {})) })
  }

  function finishImport(text) {
    var result = null
    try { result = JSON.parse(String(text || "")) } catch (parseError) { result = null }
    if (!result || result.ok !== true) {
      var reason = result && result.error ? String(result.error) : ""
      importing = false
      if (reason !== "" && reason !== "cancelled") { importNote = reason; importFailed = true }
      return
    }
    if (importStage === "pick") {
      var paths = Array.isArray(result.paths) ? result.paths : []
      if (paths.length === 0) { importing = false; return }
      importStage = "read"
      if (!service.backend || !service.backend.ready) {
        finishImport(JSON.stringify({ok:false,error:"Mail backend unavailable"}))
        return
      }
      service.backend.call("attachment.read", {path:String(paths[0])}, function(read, error) {
        root.finishImport(JSON.stringify(error ? {ok:false,error:"That file could not be read"} : read))
      })
      return
    }
    var mime = String(result.mimeType || "").toLowerCase()
    var name = String(result.filename || "").toLowerCase()
    var kind = mime.indexOf("image/") === 0 ? "image"
      : (mime === "text/html" || mime === "application/xhtml+xml" || /\.x?html?$/.test(name)) ? "html" : ""
    if (kind === "") {
      importing = false
      importNote = "Choose a PNG, JPEG, GIF or WebP picture, or an HTML file"
      importFailed = true
      return
    }
    if (!service || !service.backend || !service.backend.ready) {
      importing = false
      importNote = "Mail backend unavailable"
      importFailed = true
      return
    }
    var accountId = importingAccountId
    service.backend.call("message.signatureImport", { kind: kind,
      data: kind === "html" ? Qt.atob(String(result.data || "")) : String(result.data || "")
    }, function(imported, error) {
      root.importing = false
      if (error || !imported) {
        root.importNote = "That signature could not be imported"
        root.importFailed = true
        return
      }
      root.importNote = root.signatureImportNote(imported)
      root.importFailed = String(imported.problem || "") !== ""
      if (root.importFailed) return
      root.service.setAccountSignatureHtml(accountId, imported.html)
      if (accountId === root.selectedSignatureAccountId && String(imported.plain || "") !== ""
          && String(signatureEdit.text || "").trim() === "") {
        signatureEdit.text = imported.plain
        root.saveSignature()
      }
    })
  }

  function saveSignature() {
    if (service && selectedSignatureAccountId !== "")
      service.setAccountSignature(selectedSignatureAccountId, signatureEdit.text)
  }

  function flushEdits() {
    saveName()
    saveSignature()
  }

  function selectSignatureAccount(id) {
    var next = signatureAccount(id)
    if (!next || String(next.id || "") === selectedSignatureAccountId) return
    saveSignature()
    selectedSignatureAccountId = String(next.id || "")
    signatureEdit.text = String(next.signature || "")
  }

  function ensureSignatureAccount() {
    if (signatureAccounts.length === 0) {
      selectedSignatureAccountId = ""
      signatureEdit.text = ""
      return
    }
    if (signatureAccount(selectedSignatureAccountId)) return
    var activeId = service ? String(service.activeAccountId || "") : ""
    var next = signatureAccount(activeId) || signatureAccounts[0]
    selectedSignatureAccountId = String(next.id || "")
    signatureEdit.text = String(next.signature || "")
  }

  onSignatureAccountsChanged: {
    Qt.callLater(ensureSignatureAccount)
    Qt.callLater(ensureNameAccount)
  }
  // Invariant: the service is bound after construction and default-mail settings can change
  // externally; refresh when the page becomes visible.
  function refreshDefaultMailClient() {
    if (visible && service && typeof service.refreshDefaultMailClient === "function")
      service.refreshDefaultMailClient()
  }
  onServiceChanged: refreshDefaultMailClient()
  onVisibleChanged: refreshDefaultMailClient()
  Component.onCompleted: {
    refreshDefaultMailClient()
    renderSignaturePreview()
    ensureSignatureAccount()
    ensureNameAccount()
  }

  spacing: MailStyle.space(16)

  Column {
    id: restartSection
    objectName: "restart-settings"
    width: parent.width
    spacing: MailStyle.space(8)

    Widgets.Button {
      objectName: "restart-button"
      text: root.restartBusy ? "Restarting" : "Restart"
      enabled: !root.restartBusy
      focusable: true
      bordered: true
      foreground: root.textColor
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      onClicked: root.restartRequested()
    }

    Text {
      width: parent.width
      text: "Restart the installed mail engine. Your window, workspace, layout and draft stay in place."
      textFormat: Text.PlainText
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      objectName: "restart-status"
      visible: text !== ""
      width: parent.width
      text: root.restartStatus
      textFormat: Text.PlainText
      color: root.restartFailed ? root.urgentColor : root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      wrapMode: Text.WordWrap
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }
  }



  DisplaySettings {
    id: displaySettings
    width: parent.width
    service: root.service
    textColor: root.textColor
    dimColor: root.dimColor
    accentColor: root.accentColor
  }

  BackendSetup {
    id: backendSetup
    width: parent.width
    runtime: root.service ? root.service.backendRuntime || null : null
    backendError: root.service && root.service.backend ? root.service.backend.failure : ""
    diagnosisAvailable: !!root.service && root.service.hasAgent === true
      && typeof root.service.diagnoseError === "function"
    diagnosing: !!root.service && !!root.service.diagnosing
    onDiagnosisRequested: root.service.diagnoseError()
    textColor: root.textColor
    dimColor: root.dimColor
    accentColor: root.accentColor
    panelFontFamily: root.panelFontFamily
  }

  Text {
    text: "Settings"
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.heading
    font.bold: true
  }


  Text {
    id: appearanceHeading
    visible: !!root.service && root.service.hasAppearance === true
    text: "APPEARANCE"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }

  Rectangle {
    objectName: "appearance-settings"
    visible: !!root.service && root.service.hasAppearance === true
    width: parent.width
    implicitHeight: Math.max(appearanceText.implicitHeight, appearanceTrack.implicitHeight)
      + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    Column {
      id: appearanceText
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(12)
      anchors.right: appearanceTrack.left
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)

      Text {
        width: parent.width
        text: "Theme"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
      }

      Text {
        width: parent.width
        text: "System follows the desktop's light or dark setting."
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }
    }

    Rectangle {
      id: appearanceTrack
      objectName: "appearanceTrack"
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: appearanceSegments.implicitWidth
      height: appearanceSegments.implicitHeight
      radius: Style.cornerRadius
      color: "transparent"
      border.width: 1
      border.color: Style.normalBorderFor(root.textColor, root.accentColor)

      Row {
        id: appearanceSegments
        spacing: 0

        AppearanceButton { text: Appearance.SYSTEM; mode: Appearance.SYSTEM; firstSegment: true }
        AppearanceButton { text: Appearance.LIGHT; mode: Appearance.LIGHT }
        AppearanceButton { text: Appearance.DARK; mode: Appearance.DARK }
      }
    }
  }


  Text {
    id: barHeading
    visible: !root.service || root.service.hasTray !== false
    text: "BAR"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }

  Rectangle {
    objectName: "bar-settings"
    visible: !root.service || root.service.hasTray !== false
    width: parent.width
    implicitHeight: Math.max(barIconText.implicitHeight, barIconSwitch.implicitHeight)
      + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    Column {
      id: barIconText
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(12)
      anchors.right: barIconSwitch.left
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)

      Text {
        width: parent.width
        text: "Show the icon in the bar"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        text: "Mail is still checked and still notifies; only the envelope goes. "
          + "With it off the window opens from a keybinding or a terminal and "
          + "nowhere else, so bind a key before turning this off:"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        text: "o.bind(\"SUPER + SHIFT + G\", \"Magpie\", "
          + "\"omarchy shell shell toggle omamail '\{}'\")"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WrapAnywhere
        textFormat: Text.PlainText
      }
    }

    ToggleSwitch {
      id: barIconSwitch
      objectName: "showBarIconSwitch"
      Accessible.name: "Show the icon in the bar"
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      checked: !root.service || root.service.showBarIcon !== false
      foreground: root.textColor
      accent: root.accentColor
      onToggled: if (root.service) root.service.setShowBarIcon(!root.service.showBarIcon)
    }
  }


  Text {
    id: mailClientHeading
    visible: !!root.service && root.service.hasMailto === true
    text: "DEFAULT MAIL CLIENT"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }

  Rectangle {
    id: mailClientRow
    objectName: "default-mail-client-settings"
    visible: !!root.service && root.service.hasMailto === true
    width: parent.width
    implicitHeight: Math.max(mailClientText.implicitHeight, mailClientButton.implicitHeight)
      + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    readonly property bool isDefault: !!root.service
      && root.service.defaultMailClient === "default"

    Column {
      id: mailClientText
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(12)
      anchors.right: mailClientButton.left
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)

      Text {
        width: parent.width
        text: mailClientRow.isDefault
          ? "Magpie is the default mail client"
          : "Set up Magpie as the default mail client"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        text: "Opens mailto: links, SUPER+SHIFT+E, and SUPER+SHIFT+ALT+E for a new message."
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        visible: text !== ""
        text: root.service ? String(root.service.defaultMailClientError || "") : ""
        color: root.urgentColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }
    }

    IconTextButton {
      id: mailClientButton
      objectName: "defaultMailClientButton"
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      enabled: !!root.service && !root.service.defaultMailClientBusy
        && root.service.defaultMailClient !== ""
      text: mailClientRow.isDefault ? "Undo" : "Set as default"
      tooltipText: mailClientRow.isDefault
        ? "Give SUPER+SHIFT+E back to Omarchy's own email binding"
        : "Make Magpie open mailto: links and SUPER+SHIFT+E"
      foreground: root.textColor
      fontFamily: root.panelFontFamily
      onClicked: root.service.setDefaultMailClient(!mailClientRow.isDefault)
    }
  }


  Text {
    id: readingHeading
    text: "READING"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }

  Rectangle {
    width: parent.width
    implicitHeight: Math.max(imagesText.implicitHeight, imagesSwitch.implicitHeight)
      + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    Column {
      id: imagesText
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(12)
      anchors.right: imagesSwitch.left
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)

      Text {
        width: parent.width
        text: "Always show remote images"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
      }

      Text {
        width: parent.width
        text: "Loading an image tells its host that this address opened the "
          + "message, and when"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: imagesSwitch
      objectName: "imagesSwitch"
      Accessible.name: "Always show remote images"
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      checked: !!root.service && root.service.alwaysShowImages
      foreground: root.textColor
      accent: root.accentColor
      onToggled: if (root.service) root.service.setAlwaysShowImages(!root.service.alwaysShowImages)
    }
  }

  Rectangle {
    width: parent.width
    implicitHeight: Math.max(heavyText.implicitHeight, heavySwitch.implicitHeight)
      + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    Column {
      id: heavyText
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(12)
      anchors.right: heavySwitch.left
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)

      Text {
        width: parent.width
        text: "Always render heavy messages"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
      }

      Text {
        width: parent.width
        text: "Renders without falling back first; layout can stall the shell while it works"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: heavySwitch
      objectName: "heavySwitch"
      Accessible.name: "Always render heavy messages"
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      checked: !!root.service && root.service.alwaysRenderHeavyMessages
      foreground: root.textColor
      accent: root.accentColor
      onToggled: if (root.service)
        root.service.setAlwaysRenderHeavyMessages(!root.service.alwaysRenderHeavyMessages)
    }
  }

  Rectangle {
    width: parent.width
    implicitHeight: Math.max(directionText.implicitHeight, directionTrack.implicitHeight)
      + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    Column {
      id: directionText
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(12)
      anchors.right: directionTrack.left
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)

      Text {
        width: parent.width
        text: "Message direction"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
      }

      Text {
        width: parent.width
        text: "Auto reads it from the message's own text. The interface is unaffected."
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }
    }

    Rectangle {
      id: directionTrack
      objectName: "contentDirectionTrack"
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: directionSegments.implicitWidth
      height: directionSegments.implicitHeight
      radius: Style.cornerRadius
      color: "transparent"
      border.width: 1
      border.color: Style.normalBorderFor(root.textColor, root.accentColor)

      Row {
        id: directionSegments
        spacing: 0

        // Invariant: the shell persists direction labels as values, so use the canonical Direction
        // constants.
        DirectionButton {
          text: Direction.AUTO; mode: Direction.AUTO; firstSegment: true
        }
        DirectionButton { text: Direction.LEFT_TO_RIGHT; mode: Direction.LEFT_TO_RIGHT }
        DirectionButton { text: Direction.RIGHT_TO_LEFT; mode: Direction.RIGHT_TO_LEFT }
      }
    }
  }

  AiSettings {
    objectName: "settings-ai"
    visible: !!root.service && root.service.hasAgent !== false
    width: parent.width
    service: root.service
    textColor: root.textColor
    dimColor: root.dimColor
    accentColor: root.accentColor
    panelFontFamily: root.panelFontFamily
  }

  // Invariant: event suggestions send message text to the selected AI, so they require explicit
  // opt-in.
  Rectangle {
    objectName: "settings-suggest-events"
    visible: !!root.service && root.service.hasAgent !== false
    width: parent.width
    implicitHeight: Math.max(suggestText.implicitHeight, suggestSwitch.implicitHeight)
      + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    Column {
      id: suggestText
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(12)
      anchors.right: suggestState.left
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)

      Text {
        width: parent.width
        text: "Suggest calendar events from mail"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        text: "Uses the selected AI agent and model: a message from a person that names a time is "
          + "sent to it once when opened, which spends tokens. Notifications, "
          + "newsletters and lists are skipped. Nothing is written until you Add."
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Text {
        objectName: "suggestEventsNeedsUpdate"
        width: parent.width
        visible: !!root.service && !root.service.backendCanSuggestEvents
        text: "Install or update the backend to use this feature."
        color: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }
    }

    Text {
      id: suggestState
      objectName: "suggestEventsState"
      anchors.right: suggestSwitch.left
      anchors.rightMargin: MailStyle.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: suggestSwitch.checked ? "On" : "Off"
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
    }

    ToggleSwitch {
      id: suggestSwitch
      objectName: "suggestEventsSwitch"
      Accessible.name: "Suggest calendar events from mail"
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      checked: !!root.service && root.service.suggestEvents === true
      enabled: !!root.service && root.service.backendCanSuggestEvents
      opacity: enabled ? 1 : 0.5
      foreground: root.textColor
      accent: root.accentColor
      onToggled: if (root.service) root.service.setSuggestEvents(!root.service.suggestEvents)
    }
  }


  Text {
    id: notificationsHeading
    visible: !root.service || root.service.hasNotifications !== false
      || String(root.service.notificationError || "") !== ""
    text: "NOTIFICATIONS"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }

  Rectangle {
    objectName: "notification-settings"
    visible: !root.service || root.service.hasNotifications !== false
    width: parent.width
    implicitHeight: Math.max(notifyText.implicitHeight, notifySwitch.implicitHeight)
      + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    Column {
      id: notifyText
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(12)
      anchors.right: notifySwitch.left
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)

      Text {
        width: parent.width
        text: "New mail notifications"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
      }

      Text {
        width: parent.width
        text: "Send a desktop notification when new mail arrives in your inbox"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: notifySwitch
      objectName: "notifySwitch"
      Accessible.name: "New mail notifications"
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      checked: !!root.service && root.service.notifyNewMail
      foreground: root.textColor
      accent: root.accentColor
      onToggled: if (root.service)
        root.service.setNotifyNewMail(!root.service.notifyNewMail)
    }
  }

  Text {
    objectName: "notificationIntegrationError"
    width: parent.width
    visible: text !== ""
    text: root.service ? String(root.service.notificationError || "") : ""
    color: root.urgentColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
  }


  Text {
    id: writingHeading
    text: "WRITING"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }

  Rectangle {
    width: parent.width
    implicitHeight: Math.max(undoText.implicitHeight, undoSeconds.implicitHeight)
      + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    Column {
      id: undoText
      anchors.left: parent.left
      anchors.leftMargin: MailStyle.space(12)
      anchors.right: undoSeconds.left
      anchors.rightMargin: MailStyle.space(16)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)

      Text {
        width: parent.width
        text: "Undo send window"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
      }

      Text {
        width: parent.width
        text: "Magpie waits before delivery. Press alt+z or select Undo to cancel. Set 0 to send now."
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }
    }

    Widgets.NumberField {
      id: undoSeconds
      anchors.right: parent.right
      anchors.rightMargin: MailStyle.space(12)
      anchors.verticalCenter: parent.verticalCenter
      label: "Seconds"
      from: 0
      to: 60
      stepSize: 1
      value: root.service ? root.service.undoSendSeconds : 10
      foreground: root.textColor
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      fontSize: MailStyle.bodySmall
      onModified: function(next) {
        if (root.service) root.service.setUndoSendSeconds(next)
      }
    }
  }

  Column {
    objectName: "settings-signature-section"
    width: parent.width
    spacing: MailStyle.space(2)
    visible: root.signatureAccounts.length > 0

    Text {
      text: "Signature"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      bottomPadding: MailStyle.space(4)
    }

    Widgets.Dropdown {
      objectName: "settings-signature-account-picker"
      visible: root.signatureAccounts.length > 1
      width: parent.width
      showLabel: false
      value: root.selectedSignatureAccountId
      options: root.accountOptions
      foreground: root.textColor
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      onChanged: function(next) { root.selectSignatureAccount(next) }
    }

    Rectangle {
      width: parent.width
      implicitHeight: Math.max(signatureEdit.implicitHeight, MailStyle.space(56))
        + MailStyle.space(20)
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.textColor, root.accentColor)

      // Invariant: place the padding click target behind the editor to preserve normal cursor
      // placement.
      MouseArea {
        anchors.fill: parent
        onClicked: signatureEdit.forceActiveFocus()
      }

      TextEdit {
        id: signatureEdit
        objectName: "settings-signature-editor"
        anchors.fill: parent
        anchors.margins: MailStyle.space(10)
        activeFocusOnTab: true
        selectByMouse: true
        wrapMode: TextEdit.Wrap
        textFormat: TextEdit.PlainText
        color: root.textColor
        selectionColor: Style.selectionFillFor(root.textColor, root.accentColor)
        selectedTextColor: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall

        // Invariant: polling must not replace the selected signature editor’s text.
        onActiveFocusChanged: if (!activeFocus) root.saveSignature()
      }

      Text {
        anchors.left: signatureEdit.left
        anchors.top: signatureEdit.top
        enabled: false
        visible: signatureEdit.text === ""
        text: "No signature"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
      }
    }

    // Invariant: signature previews use the backend-sanitized document; sender markup must not
    // reach Qt directly.
    Row {
      width: parent.width
      spacing: MailStyle.space(8)

      Widgets.Button {
        objectName: "settings-signature-import"
        text: root.importing ? "Importing" : "Import from file..."
        tooltipText: "A PNG, JPEG, GIF or WebP picture, or an HTML file"
        foreground: root.textColor
        bordered: true
        accent: root.accentColor
        fontFamily: root.panelFontFamily
        fontSize: MailStyle.caption
        enabled: !root.importing && root.selectedSignatureAccountId !== ""
        onClicked: root.importSignature()
      }

      Widgets.Button {
        objectName: "settings-signature-remove-html"
        visible: root.selectedSignatureHtml !== ""
        text: "Remove imported markup"
        foreground: root.dimColor
        bordered: false
        fontFamily: root.panelFontFamily
        fontSize: MailStyle.caption
        onClicked: {
          if (root.service) root.service.setAccountSignatureHtml(root.selectedSignatureAccountId, "")
          root.importNote = ""
        }
      }
    }

    Text {
      width: parent.width
      visible: root.importNote !== ""
      textFormat: Text.PlainText
      text: root.importNote
      color: root.importFailed ? root.urgentColor : root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }

    Rectangle {
      objectName: "settings-signature-preview"
      width: parent.width
      visible: root.selectedSignatureHtml !== ""
      implicitHeight: Math.min(MailStyle.space(220), signaturePreview.implicitHeight + MailStyle.space(20))
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.textColor, root.accentColor)
      clip: true

      TextEdit {
        id: signaturePreview
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: MailStyle.space(10)
        readOnly: true
        selectByMouse: false
        wrapMode: TextEdit.Wrap
        textFormat: TextEdit.RichText
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        text: root.selectedSignatureDocument ? Html.documentFor(root.selectedSignatureDocument, {
          foreground: root.textColor, background: "transparent", link: root.accentColor }) : ""
      }
    }

    Text {
      width: parent.width
      text: "Sits under a new message, and above the quoted text in a reply. "
        + "Sent as written — no separator line is added in front of it."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }

    Component.onDestruction: root.saveSignature()
  }


  Text {
    id: mailboxesHeading
    text: "MAILBOXES"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }

  // Invariant: editable account names must outlive live mailbox-summary rows rebuilt by polling.
  Column {
    width: parent.width
    spacing: MailStyle.space(6)
    visible: root.signatureAccounts.length > 0

    Text {
      width: parent.width
      visible: root.signatureAccounts.length > 1
      text: "Mailbox"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
    }

    Widgets.Dropdown {
      objectName: "settings-name-account-picker"
      visible: root.signatureAccounts.length > 1
      width: parent.width
      showLabel: false
      value: root.selectedNameAccountId
      options: root.accountOptions
      foreground: root.textColor
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      onChanged: function(next) { root.selectNameAccount(next) }
    }

    Item {
      width: parent.width
      implicitHeight: MailStyle.space(4)
      visible: root.signatureAccounts.length > 1
    }

    Text {
      width: parent.width
      text: "Mailbox name"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
    }

    // Invariant: use the native field; a Rectangle around a bare TextInput previously drew a box
    // that could not receive typing.
    Widgets.TextField {
      id: nameEdit
      objectName: "settings-name-editor"
      width: parent.width
      foreground: root.textColor
      accent: root.accentColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall

      // Performance: persist the completed name edit on focus loss or acceptance, not on each
      // keystroke.
      onActiveFocusChanged: if (!activeFocus) root.saveName()
      onAccepted: root.saveName()
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "What this mailbox is called in Magpie — in the switcher, in this "
        + "list, and beside every message in a combined view. Leave it empty "
        + "to use the address. It is not sent to anyone."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
    }
  }

  Column {
    width: parent.width
    spacing: MailStyle.space(2)

    Repeater {
      model: root.accounts

      Rectangle {
        id: row
        required property var modelData
        required property int index

        width: parent.width
        implicitHeight: Math.max(rowText.implicitHeight, rowActions.implicitHeight)
          + MailStyle.space(16)
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.textColor, root.accentColor)

        Column {
          id: rowText
          anchors.left: parent.left
          anchors.leftMargin: MailStyle.space(12)
          anchors.right: rowActions.left
          anchors.rightMargin: MailStyle.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: MailStyle.space(2)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: {
              var named = row.modelData.name !== undefined
                && String(row.modelData.name) !== ""
              if (named) return String(row.modelData.name)
              return row.modelData.email !== "" ? row.modelData.email : "New mailbox"
            }
            color: root.textColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.bodySmall
            elide: Text.ElideMiddle
          }

          Text {
            width: parent.width
            // Invariant: server errors and account addresses must remain plain text to prevent Qt
            // resource loading.
            textFormat: Text.PlainText
            text: {
              if (row.modelData.error !== undefined && row.modelData.error !== "")
                return row.modelData.error
              if (!row.modelData.signedIn) return "Signed out"
              var count = row.modelData.unread
              var unread = count === 0 ? "No unread mail"
                : (count === 1 ? "1 unread message" : count + " unread messages")
              var named = row.modelData.name !== undefined
                && String(row.modelData.name) !== ""
              return named ? String(row.modelData.email) + " · " + unread : unread
            }
            color: row.modelData.error !== undefined && row.modelData.error !== ""
              ? root.urgentColor : root.dimColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.caption
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: row.modelData.detail !== undefined ? row.modelData.detail : ""
            color: root.dimColor
            font.family: root.panelFontFamily
            font.pixelSize: MailStyle.caption
            elide: Text.ElideRight
          }
        }

        Row {
          id: rowActions
          anchors.right: parent.right
          anchors.rightMargin: MailStyle.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: MailStyle.space(6)

          IconTextButton {
            text: "Edit..."
            foreground: root.textColor
            fontFamily: root.panelFontFamily
            tooltipText: "Edit this mailbox"
            onClicked: root.editRequested(row.index)
          }
        }
      }
    }
  }

  IconTextButton {
    iconName: "plus"
    text: "Add a mailbox..."
    foreground: root.textColor
    fontFamily: root.panelFontFamily
    tooltipText: "Add another mail account"
    onClicked: root.addRequested()
  }

  PanelSeparator {
    width: parent.width
    foreground: root.textColor
  }

  CalendarSettings {
    id: calendarsSection
    width: parent.width
    service: root.service
    controller: root.calendarController
    textColor: root.textColor
    dimColor: root.dimColor
    accentColor: root.accentColor
    urgentColor: root.urgentColor
    panelFontFamily: root.panelFontFamily
    onAccountSetupRequested: function(index) {
      if (index < 0) return
      if (root.accounts[index].calendarProvider === "google") root.calendarSignInRequested(index)
      else root.editRequested(index)
    }
    onClientSetupRequested: root.clientSetupRequested()
    onAddAccountRequested: root.addRequested()
    onOpenCalendarRequested: root.openCalendarRequested()
  }

  PanelSeparator {
    width: parent.width
    foreground: root.textColor
  }


  PhoneSettings {
    id: phoneSettings
    width: parent.width
    service: root.service
    textColor: root.textColor
    dimColor: root.dimColor
    accentColor: root.accentColor
    panelFontFamily: root.panelFontFamily
  }

  PanelSeparator {
    width: parent.width
    foreground: root.textColor
  }

  Text {
    id: oauthHeading
    text: "GOOGLE OAUTH CLIENT"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(clientText.implicitHeight, clientButton.implicitHeight)

    Column {
      id: clientText
      anchors.left: parent.left
      anchors.right: clientButton.left
      anchors.rightMargin: MailStyle.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: MailStyle.space(2)

      Text {
        width: parent.width
        text: root.auth && root.auth.credentialsPresent
          ? "Google client configured" : "Google client setup required"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        elide: Text.ElideMiddle
      }

      Text {
        width: parent.width
        text: "Advanced setup · shared by Gmail and Google Calendar accounts"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        wrapMode: Text.WordWrap
      }
    }

    IconTextButton {
      id: clientButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: root.auth && root.auth.credentialsPresent ? "Change..." : "Set up..."
      foreground: root.dimColor
      fontFamily: root.panelFontFamily
      onClicked: root.clientSetupRequested()
    }
  }

  component AppearanceButton: Widgets.Button {
    required property string mode
    property bool firstSegment: false
    objectName: "appearance-" + mode.toLowerCase()
    selected: !!root.service && root.service.appearance === mode
    bordered: false
    foreground: selected ? root.textColor : root.dimColor
    accent: root.accentColor
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.caption
    horizontalPadding: MailStyle.space(7)
    verticalPadding: MailStyle.space(3)
    onClicked: if (root.service) root.service.setAppearance(mode)

    Rectangle {
      visible: !parent.firstSegment
      width: 1
      height: parent.height
      color: appearanceTrack.border.color
    }
  }

  component DirectionButton: Widgets.Button {
    required property string mode
    property bool firstSegment: false
    selected: !!root.service && root.service.contentDirection === mode
    bordered: false
    foreground: selected ? root.textColor : root.dimColor
    accent: root.accentColor
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.caption
    horizontalPadding: MailStyle.space(7)
    verticalPadding: MailStyle.space(3)
    onClicked: if (root.service) root.service.setContentDirection(mode)

    Rectangle {
      visible: !parent.firstSegment
      width: 1
      height: parent.height
      color: directionTrack.border.color
    }
  }
}

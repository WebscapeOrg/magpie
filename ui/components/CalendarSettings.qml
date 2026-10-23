import QtQuick
import "../controls" as Widgets
import "../settings"
import qs.Commons
import qs.Ui
import "../calendar/Sources.js" as Sources

Column {
  id: root

  required property var service
  required property var controller
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property color urgentColor
  required property string panelFontFamily
  property string colorEditingId: ""
  property string setupAccountId: ""
  property string setupError: ""
  property bool setupComplete: false
  signal accountSetupRequested(int index)
  signal clientSetupRequested()
  signal addAccountRequested()
  signal openCalendarRequested()
  readonly property var settingsSources: {
    var groups = Sources.groupByAccount(controller ? controller.availableSources : null,
      service ? service.accountSummaries : [])
    var values = []
    for (var entryIndex = 0; entryIndex < groups.length; entryIndex++) values = values.concat(groups[entryIndex].calendars)
    return values
  }
  readonly property var writableSources: settingsSources.filter(function(source) {
    return Sources.writable(source) && !root.orphaned(source)
  })

  function accountIndex(id) {
    var accounts = root.service ? root.service.accountSummaries : []
    for (var entryIndex = 0; entryIndex < accounts.length; entryIndex++) if (accounts[entryIndex].id === id) return entryIndex
    return -1
  }

  function discoverableAccounts() {
    if (!root.service || root.service.backendCanDiscoverCalendars !== true) return []
    var accounts = root.service && Array.isArray(root.service.accountSummaries)
      ? root.service.accountSummaries : []
    return accounts.filter(function(account) {
      return account
        && account.calendarProvider === "google" && root.service.backendCanGoogleCalendars === true
    })
  }

  function providerName(account) { return "Google" }

  function accountLabel(source) {
    var wanted = String(source && source.accountId || "")
    var accounts = root.service && Array.isArray(root.service.accountSummaries)
      ? root.service.accountSummaries : []
    for (var entryIndex = 0; entryIndex < accounts.length; entryIndex++) {
      if (String(accounts[entryIndex] && accounts[entryIndex].id || "") === wanted)
        return String(accounts[entryIndex].email || accounts[entryIndex].label || "")
    }
    return ""
  }

  function orphaned(source) {
    return Sources.orphaned(source,
      root.service && Array.isArray(root.service.accountSummaries) ? root.service.accountSummaries : [])
  }

  // Invariant: discovery owns calendars while their account exists.
  function removable(source) {
    var value = source || {}
    return root.orphaned(value)
  }

  function nestedDetail(source) {
    var value = source || {}
    var parts = []
    if (value.preferred === true) parts.push("Default for new events")
    if (value.readOnly === true) parts.push("Read-only")
    return parts.join(" · ")
  }

  function displayName(source) {
    var value = source || {}
    var name = String(value.name || value.id || "Calendar")
    var account = root.accountLabel(value)
    return account !== "" && name.toLowerCase() === account.toLowerCase() ? "Primary" : name
  }

  function accountCalendars(accountId) {
    return root.settingsSources.filter(function(source) {
      return String(source.accountId || "") === String(accountId || "") && !root.orphaned(source)
    })
  }

  readonly property var otherSources: settingsSources.filter(function(source) {
    var account = String(source.accountId || "")
    return account === "" || root.orphaned(source)
      || !root.discoverableAccounts().some(function(value) { return String(value.id) === account })
  })

  readonly property var defaultChoices: Sources.writableGroups(Sources.groupByAccount(
    { sources: writableSources }, service ? service.accountSummaries : []))
    .filter(function(group) { return group.calendars.length > 1 })

  readonly property var reminderSources: settingsSources.filter(function(source) {
    return Sources.nativeCalendarFeatures(source) && !root.orphaned(source)
  })

  function reminderMode(source) {
    return source.remindersEnabled !== true ? "off"
      : Number(source.reminderMinutes) >= 0 ? "custom" : "google"
  }

  function sourceDetail(source) {
    var value = source || {}
    var provider = "Google"
    var account = root.accountLabel(value)
    var detail = root.orphaned(value) ? provider + " · Mailbox removed"
      : account === "" ? provider + " calendar" : provider + " · " + account
    return value.readOnly === true ? detail + " · Read-only" : detail
  }

  CalendarPalette {
    id: calendarPalette
    palettePath: root.service ? String(root.service.calendarPalettePath || "") : ""
    textColor: root.textColor
    accentColor: root.accentColor
    urgentColor: root.urgentColor
    dimColor: root.dimColor
  }

  width: parent ? parent.width : implicitWidth
  spacing: MailStyle.space(16)

  component SettingRow: Rectangle {
    id: settingRow
    property string title: ""
    property string detail: ""
    default property alias controls: rowControls.data
    readonly property real controlsWidth: {
      var total = 0
      var count = 0
      for (var index = 0; index < rowControls.children.length; index++) {
        var control = rowControls.children[index]
        if (!control.visible) continue
        total += control.width
        count++
      }
      return total + Math.max(0, count - 1) * rowControls.spacing
    }
    readonly property bool stacked: width < controlsWidth + MailStyle.space(180)
    width: parent ? parent.width : 0
    implicitHeight: (stacked ? settingText.implicitHeight + rowControls.implicitHeight + MailStyle.space(8)
      : Math.max(settingText.implicitHeight, rowControls.implicitHeight)) + MailStyle.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)
    Column {
      id: settingText
      objectName: "calendar-setting-text"
      x: MailStyle.space(12)
      y: settingRow.stacked ? MailStyle.space(8) : (settingRow.height - height) / 2
      width: Math.max(0, settingRow.width - x - MailStyle.space(10)
        - (settingRow.stacked ? 0 : settingRow.controlsWidth + MailStyle.space(10)))
      spacing: MailStyle.space(2)
      Text {
        width: parent.width
        text: settingRow.title
        textFormat: Text.PlainText
        elide: settingRow.stacked ? Text.ElideNone : Text.ElideMiddle
        wrapMode: settingRow.stacked ? Text.WrapAnywhere : Text.NoWrap
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
      }
      Text {
        width: parent.width
        visible: text !== ""
        text: settingRow.detail
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }
    }
    Flow {
      id: rowControls
      x: settingRow.stacked ? MailStyle.space(12) : settingRow.width - width - MailStyle.space(10)
      y: settingRow.stacked ? settingText.y + settingText.height + MailStyle.space(8)
        : (settingRow.height - height) / 2
      width: Math.min(settingRow.controlsWidth, Math.max(0, settingRow.width - MailStyle.space(22)))
      spacing: MailStyle.space(6)
    }
  }

  component SectionHeading: Text {
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    font.letterSpacing: 1
  }

  component CalendarRow: Column {
    id: calendarRow
    property var source: ({})
    property string detail: ""
    width: parent ? parent.width : 0
    spacing: MailStyle.space(2)

    Rectangle {
      width: parent.width
      implicitHeight: Math.max(calendarText.implicitHeight, calendarActions.implicitHeight) + MailStyle.space(16)
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.textColor, root.accentColor)

      Widgets.Button {
        id: colorButton
        objectName: "calendar-source-color"
        focusable: true
        anchors.left: parent.left
        anchors.leftMargin: MailStyle.space(12) - (width - MailStyle.space(10)) / 2
        anchors.verticalCenter: parent.verticalCenter
        width: MailStyle.space(24)
        height: width
        horizontalPadding: 0
        verticalPadding: 0
        background: "transparent"
        selected: root.colorEditingId === String(calendarRow.source.id)
        foreground: root.textColor
        accent: root.accentColor
        tooltipText: "Change calendar color"
        Accessible.name: "Change color for " + String(calendarRow.source.name || calendarRow.source.id)
        enabled: !!root.controller && !root.controller.savingSource
          && !root.controller.discoveringCalendars
        onClicked: {
          root.colorEditingId = root.colorEditingId === String(calendarRow.source.id)
            ? "" : String(calendarRow.source.id)
        }
        Rectangle {
          objectName: "calendar-source-color-swatch"
          anchors.centerIn: parent
          width: MailStyle.space(10)
          height: width
          radius: width / 2
          color: calendarPalette.colorFor(calendarRow.source.colorKey)
        }
      }

      Column {
        id: calendarText
        anchors.left: parent.left
        anchors.leftMargin: MailStyle.space(30)
        anchors.right: calendarActions.left
        anchors.rightMargin: MailStyle.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: MailStyle.space(2)
        Text {
          width: parent.width
          text: root.displayName(calendarRow.source)
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.bodySmall
        }
        Text {
          objectName: "calendar-source-detail"
          width: parent.width
          visible: text !== ""
          text: calendarRow.detail
          textFormat: Text.PlainText
          elide: Text.ElideMiddle
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.caption
        }
      }

      Row {
        id: calendarActions
        anchors.right: parent.right
        anchors.rightMargin: MailStyle.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: MailStyle.space(6)
        IconTextButton {
          objectName: "calendar-source-remove"
          anchors.verticalCenter: parent.verticalCenter
          visible: root.removable(calendarRow.source)
          text: "Remove"
          bordered: false
          foreground: root.urgentColor
          fontFamily: root.panelFontFamily
          enabled: !!root.controller && !root.controller.savingSource
            && !root.controller.discoveringCalendars
          onClicked: root.controller.removeCalendar(calendarRow.source.id)
        }
        ToggleSwitch {
          objectName: "calendar-source-toggle"
          Accessible.name: "Show " + String(calendarRow.source.name || calendarRow.source.id)
          anchors.verticalCenter: parent.verticalCenter
          checked: calendarRow.source.enabled !== false
          interactive: !!root.controller && !root.controller.savingSource
            && !root.controller.discoveringCalendars
          foreground: root.textColor
          accent: root.accentColor
          onToggled: if (root.controller)
            root.controller.setSourceEnabled(calendarRow.source.id, calendarRow.source.enabled === false)
        }
      }
    }

    Row {
      id: colorRow
      objectName: "calendar-color-picker"
      x: MailStyle.space(12)
      visible: root.colorEditingId === String(calendarRow.source.id)
      height: visible ? implicitHeight : 0
      spacing: MailStyle.space(6)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Color"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        textFormat: Text.PlainText
      }
      Repeater {
        model: calendarPalette.slots
        Widgets.Button {
          id: paletteOption
          required property string modelData
          objectName: "calendar-color-" + modelData
          focusable: true
          width: MailStyle.space(24)
          height: width
          horizontalPadding: 0
          verticalPadding: 0
          selected: String(modelData) === String(calendarRow.source.colorKey || "")
          foreground: root.textColor
          accent: root.accentColor
          tooltipText: "Use " + modelData
          Accessible.name: "Use " + modelData + " for "
            + String(calendarRow.source.name || calendarRow.source.id)
          enabled: !!root.controller && !root.controller.savingSource
            && !root.controller.discoveringCalendars
          onClicked: {
            root.controller.setSourceColor(calendarRow.source.id, modelData)
            root.colorEditingId = ""
          }
          Rectangle {
            anchors.centerIn: parent
            width: MailStyle.space(14)
            height: width
            radius: width / 2
            color: "transparent"
            border.width: parent.selected ? Math.max(1, Style.normalBorderWidth) : 0
            border.color: root.textColor
            Rectangle {
              objectName: "calendar-color-swatch-" + paletteOption.modelData
              anchors.centerIn: parent
              width: MailStyle.space(8)
              height: width
              radius: width / 2
              color: calendarPalette.colorFor(paletteOption.modelData)
            }
          }
        }
      }
    }

  }


  Column {
    width: parent.width
    spacing: MailStyle.space(4)
    SectionHeading { text: "CALENDARS" }
    Text {
      width: parent.width
      text: "Choose which calendars appear and their colors. New events and reminders are set below."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
    }
  }

  Text {
    width: parent.width
    visible: root.discoverableAccounts().length === 0
    text: root.service && root.service.backendCanDiscoverCalendars !== true
      ? "Update the mail backend to connect account calendars."
      : "Add a Google account to connect its calendars."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
  }

  Widgets.Button {
    visible: root.discoverableAccounts().length === 0
    text: "Add an account..."
    foreground: root.textColor
    fontFamily: root.panelFontFamily
    onClicked: root.addAccountRequested()
  }

  Repeater {
    model: root.discoverableAccounts()

    Column {
      id: accountBlock
      required property var modelData
      readonly property var calendars: root.accountCalendars(modelData.id)
      width: root.width
      spacing: MailStyle.space(2)

      SettingRow {
        title: String(accountBlock.modelData.email || accountBlock.modelData.label || "")
        detail: root.providerName(accountBlock.modelData) + " · "
          + (accountBlock.modelData.signedIn !== true ? "Sign in to connect calendars"
            : accountBlock.calendars.length > 0
              ? accountBlock.calendars.length + (accountBlock.calendars.length === 1 ? " calendar" : " calendars")
              : "Uses this mailbox's sign-in")
        Widgets.Button {
          id: discoveryButton
          objectName: "calendar-discover-" + String(accountBlock.modelData.calendarProvider || "account")
          focusable: true
          bordered: true
          foreground: root.textColor
          fontFamily: root.panelFontFamily
          fontSize: MailStyle.caption
          enabled: !!root.controller && !root.controller.discoveringCalendars
            && !root.controller.savingSource
          text: accountBlock.modelData.signedIn !== true ? "Sign in..."
            : root.controller && root.controller.discoveringCalendars
            && root.controller.discoveringAccountId === String(accountBlock.modelData.id || "")
            ? "Finding..."
            : (accountBlock.calendars.length > 0
               ? "Refresh calendars..." : "Enable Google Calendar...")
          onClicked: {
            resultText.text = ""
            root.colorEditingId = ""
            root.setupAccountId = String(accountBlock.modelData.id || "")
            root.setupError = ""
            root.setupComplete = false
            if (accountBlock.modelData.signedIn !== true) {
              root.accountSetupRequested(root.accountIndex(root.setupAccountId))
              return
            }
            if (root.controller)
              root.controller.discoverAccountCalendars(accountBlock.modelData.id)
          }
        }
      }

      Repeater {
        model: accountBlock.calendars
        CalendarRow {
          required property var modelData
          source: modelData
          detail: root.nestedDetail(modelData)
        }
      }
    }
  }

  Column {
    objectName: "calendar-setup-recovery"
    width: root.width
    visible: root.setupError !== ""
    spacing: MailStyle.space(6)
    Text {
      width: parent.width
      text: root.accountLabel({ accountId: root.setupAccountId }) + ": " + root.setupError
      color: root.urgentColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
    }
    Text {
      width: parent.width
      text: "For Google, enable the Google Calendar API in the same Cloud project as your Gmail client. If access was refused, sign in again and allow calendar access. Your saved calendar choices are kept."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: root.setupAccountId !== "" && root.discoverableAccounts().some(function(account) {
        return account.id === root.setupAccountId && account.calendarProvider === "google"
      })
    }
    Flow {
      width: parent.width
      spacing: MailStyle.space(6)
      Widgets.Button {
        text: "Check again"
        foreground: root.textColor
        fontFamily: root.panelFontFamily
        enabled: !!root.controller && !root.controller.discoveringCalendars && !root.controller.savingSource
        onClicked: root.controller.discoverAccountCalendars(root.setupAccountId)
      }
      Widgets.Button {
        text: "Sign in again..."
        foreground: root.textColor
        fontFamily: root.panelFontFamily
        enabled: root.accountIndex(root.setupAccountId) >= 0
        onClicked: root.accountSetupRequested(root.accountIndex(root.setupAccountId))
      }
      Widgets.Button {
        text: "Google Calendar API setup..."
        visible: root.setupAccountId !== "" && root.discoverableAccounts().some(function(account) {
          return account.id === root.setupAccountId && account.calendarProvider === "google"
        })
        foreground: root.textColor
        fontFamily: root.panelFontFamily
        onClicked: Qt.openUrlExternally("https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")
      }
    }
  }

  Column {
    width: root.width
    visible: !!root.controller && root.controller.discoveryChoices !== null
    spacing: MailStyle.space(8)
    Text {
      text: "Choose calendars to show"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.bodySmall
      textFormat: Text.PlainText
    }
    Text {
      width: parent.width
      text: "Start with your Google selection. You can change visibility and reminders independently below. Your primary writable calendar is selected for new events by default."
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
    }
    Repeater {
      model: root.controller && root.controller.discoveryChoices ? root.controller.discoveryChoices.sources.filter(function(source) {
        return source.accountId === root.controller.discoveryChoiceAccount && source.kind === "google"
      }) : []
      delegate: SettingRow {
        required property var modelData
        title: String(modelData.name || modelData.id)
        detail: modelData.readOnly === true ? "Read-only" : ""
        ToggleSwitch {
          objectName: "calendar-discovered-toggle"
          Accessible.name: "Show " + String(modelData.name || modelData.id)
          checked: modelData.enabled === true
          foreground: root.textColor
          accent: root.accentColor
          onToggled: root.controller.chooseDiscovered(modelData.id, !modelData.enabled)
        }
      }
    }
    Row {
      spacing: MailStyle.space(8)
      Widgets.Button {
        text: root.controller && root.controller.savingSource ? "Saving..." : "Save calendar selection"
        foreground: root.textColor
        enabled: !!root.controller && !root.controller.savingSource
        onClicked: root.controller.confirmDiscovery()
      }
      Widgets.Button {
        text: "Cancel"
        foreground: root.textColor
        onClicked: root.controller.discoveryChoices = null
      }
    }
  }

  Column {
    width: root.width
    visible: root.otherSources.length > 0
    spacing: MailStyle.space(2)
    Text {
      text: "Other calendars"
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
      bottomPadding: MailStyle.space(4)
    }
    Repeater {
      model: root.otherSources
      CalendarRow {
        required property var modelData
        source: modelData
        detail: root.sourceDetail(modelData)
      }
    }
  }

  Text {
    id: resultText
    // Invariant: success is explicit state, never inferred from server-controlled error wording.
    property bool ok: false
    width: parent.width
    visible: text !== ""
    color: ok ? root.dimColor : root.urgentColor
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.caption
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
  }

  SettingRow {
    title: "Unified calendar view"
    detail: "Show every account together instead of following the current mailbox."
    ToggleSwitch {
      id: unifiedSwitch
      objectName: "unifiedCalendarSwitch"
      Accessible.name: "Unified calendar view"
      checked: !!root.service && root.service.unifiedCalendarView === true
      foreground: root.textColor
      accent: root.accentColor
      onToggled: if (root.service) root.service.setUnifiedCalendarView(!root.service.unifiedCalendarView)
    }
  }

  Widgets.Button {
    objectName: "calendar-open-after-setup"
    visible: root.setupComplete
    text: "Open calendar"
    foreground: root.textColor
    accent: root.accentColor
    fontFamily: root.panelFontFamily
    onClicked: root.openCalendarRequested()
  }


  Column {
    width: parent.width
    visible: root.defaultChoices.length > 0
    spacing: MailStyle.space(2)
    SectionHeading { text: "NEW EVENTS"; bottomPadding: MailStyle.space(2) }
    Repeater {
      id: defaultGroups
      model: root.defaultChoices
      SettingRow {
        id: defaultGroup
        required property var modelData
        title: "Default calendar"
        detail: defaultGroup.modelData.accountLabel
        Widgets.Dropdown {
          objectName: "calendar-default-picker"
          width: MailStyle.space(200)
          showLabel: false
          options: defaultGroup.modelData.calendars.map(function(source) {
            return { value: source.id, label: root.displayName(source) }
          })
          value: {
            var values = defaultGroup.modelData.calendars
            for (var entryIndex = 0; entryIndex < values.length; entryIndex++) if (values[entryIndex].preferred) return values[entryIndex].id
            return values.length ? values[0].id : ""
          }
          foreground: root.textColor
          accent: root.accentColor
          fontFamily: root.panelFontFamily
          enabled: !!root.controller && !root.controller.savingSource && !root.controller.discoveringCalendars
          onChanged: function(next) { root.controller.setDefaultCalendar(next) }
        }
      }
    }
  }


  Column {
    width: parent.width
    spacing: MailStyle.space(2)
    visible: !!root.service && root.service.backendCanGoogleCalendars === true
      && root.reminderSources.length > 0
    SectionHeading { text: "REMINDERS"; bottomPadding: MailStyle.space(2) }
    SettingRow {
      title: "Desktop reminders"
      detail: "Shown while Magpie is running, even with its window closed."
      ToggleSwitch {
        objectName: "calendar-reminders-enabled"
        Accessible.name: "Desktop reminders"
        checked: !!root.service && root.service.calendarRemindersEnabled === true
        foreground: root.textColor
        accent: root.accentColor
        onToggled: root.service.persistSetting("calendarRemindersEnabled", !root.service.calendarRemindersEnabled)
      }
    }
    SettingRow {
      visible: !!root.service && root.service.calendarRemindersEnabled === true
      title: "Snooze"
      detail: "How long Snooze puts a reminder off."
      Widgets.NumberField {
        objectName: "calendar-snooze-minutes"
        label: "Minutes"
        from: 1
        to: 1440
        stepSize: 1
        value: root.service ? root.service.calendarSnoozeMinutes : 5
        foreground: root.textColor
        accent: root.accentColor
        fontFamily: root.panelFontFamily
        fontSize: MailStyle.bodySmall
        onModified: function(next) { root.service.persistSetting("calendarSnoozeMinutes", next) }
      }
    }
    Repeater {
      model: !!root.service && root.service.calendarRemindersEnabled === true ? root.reminderSources : []
      SettingRow {
        id: reminderRow
        required property var modelData
        title: root.displayName(modelData)
        detail: root.accountLabel(modelData) + (modelData.enabled === false ? " · Hidden, still reminds" : "")
        Widgets.NumberField {
          objectName: "calendar-reminder-minutes"
          visible: root.reminderMode(reminderRow.modelData) === "custom"
          label: "Minutes before"
          from: 0
          to: 40320
          stepSize: 5
          value: Math.max(0, Number(reminderRow.modelData.reminderMinutes))
          foreground: root.textColor
          accent: root.accentColor
          fontFamily: root.panelFontFamily
          fontSize: MailStyle.bodySmall
          enabled: !!root.controller && !root.controller.savingSource
          onModified: function(next) { root.controller.setReminderPolicy(reminderRow.modelData.id, true, next) }
        }
        Widgets.Dropdown {
          objectName: "calendar-reminder-mode"
          width: MailStyle.space(200)
          showLabel: false
          value: root.reminderMode(reminderRow.modelData)
          options: [{ value: "off", label: "Off" }, { value: "google", label: "Google event reminders" },
            { value: "custom", label: "Custom timing" }]
          foreground: root.textColor
          accent: root.accentColor
          fontFamily: root.panelFontFamily
          enabled: !!root.controller && !root.controller.savingSource
          onChanged: function(next) {
            root.controller.setReminderPolicy(reminderRow.modelData.id, next !== "off",
              next === "google" ? -1 : Number(reminderRow.modelData.reminderMinutes) >= 0
                ? Number(reminderRow.modelData.reminderMinutes) : 10)
          }
        }
      }
    }
    Text {
      width: parent.width
      visible: text !== ""
      topPadding: MailStyle.space(4)
      text: String(root.service && root.service.calendarReminderError || "")
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: root.urgentColor
      font.family: root.panelFontFamily
      font.pixelSize: MailStyle.caption
    }
  }

  Widgets.Button {
    text: "Advanced Google setup..."
    foreground: root.dimColor
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.caption
    onClicked: root.clientSetupRequested()
  }


  Connections {
    target: root.controller
    function onCalendarSaved(ok, error) {
      resultText.ok = ok
      if (!ok) { resultText.text = error; return }
      resultText.text = "Calendar saved"
      root.colorEditingId = ""
    }
    function onDiscoveryFinished(ok, error, count) {
      resultText.ok = ok
      root.setupError = ok ? "" : error
      root.setupComplete = ok
      resultText.text = ok ? "Saved " + count + (count === 1 ? " calendar. Choose reminders below, then open your calendar." : " calendars. Choose reminders below, then open your calendar.") : ""
    }
  }
}

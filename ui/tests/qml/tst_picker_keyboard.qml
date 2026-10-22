import QtQuick
import QtQuick.Window
import QtTest
import qs.Commons
import "../../components" as Components

Rectangle {
  id: host
  width: 900
  height: 700
  color: Color.background
  property string mode: ""
  property string captureDirectory: ""
  property int applicationActivations: 0
  property var selected: []
  property int contactSelections: 0
  readonly property var contact: ({ name: "Alex Example", email: "alex@example.test" })
  readonly property var suggestion: ({ key: "suggestion-1", jobId: "job-1",
    title: "Project review", start: "2026-10-23T10:00:00Z", end: "2026-10-23T10:30:00Z",
    location: "Meeting room", notes: "Synthetic meeting" })

  Item { id: parking; width: 1; height: 1 }
  Shortcut {
    sequence: "Space"
    context: Qt.WindowShortcut
    onActivated: host.applicationActivations++
  }
  Shortcut {
    sequence: "Return"
    context: Qt.WindowShortcut
    onActivated: host.applicationActivations++
  }

  Components.ProviderPicker {
    id: providers
    x: 32; y: 32; width: 520
    visible: host.mode === "providers"
    textColor: Color.foreground; dimColor: Color.foreground
    accentColor: Color.accent; panelFontFamily: "sans-serif"
    onChosen: function(providerId) { host.selected = [providerId] }
  }
  Components.AccountRemovalDialog {
    id: removal
    visible: host.mode === "removal"
    textColor: Color.foreground; dimColor: Color.foreground
    dangerColor: Color.urgent; popupBackgroundColor: Color.background
    popupBorderColor: Color.foreground; panelFontFamily: "sans-serif"
    onConfirmed: function(request) { host.selected = [request] }
  }
  Components.AccountSwitcher {
    id: accounts
    visible: host.mode === "accounts"
    textColor: Color.foreground; dimColor: Color.foreground
    accentColor: Color.accent; urgentColor: Color.urgent
    popupBackgroundColor: Color.background; popupBorderColor: Color.foreground
    panelFontFamily: "sans-serif"
    accounts: [{id:"synthetic",email:"alex@example.test",active:true,signedIn:true}]
    onAddAccountRequested: host.selected = ["add"]
    onManageRequested: host.selected = ["manage"]
  }
  Components.ContactsPicker {
    id: contacts
    visible: host.mode === "contacts"
    contacts: [host.contact]
    textColor: Color.foreground; dimColor: Color.foreground
    accentColor: Color.accent; popupBackgroundColor: Color.background
    popupBorderColor: Color.foreground; panelFontFamily: "sans-serif"
    onContactChosen: function(contact, target) {
      host.contactSelections++
      host.selected = [contact, target]
    }
  }
  Components.EventSuggestionCard {
    id: events
    x: 32; y: 32; width: 520
    suggestions: host.mode === "events" ? [host.suggestion] : []
    textColor: Color.foreground; dimColor: Color.foreground
    accentColor: Color.accent; dimmerColor: Color.foreground
    panelFontFamily: "sans-serif"
    onAddRequested: function(suggestion) { host.selected = [suggestion] }
  }
  Components.LinkLabel {
    id: link
    x: 32; y: 32
    visible: host.mode === "link"
    text: "Connection help"
    color: Color.foreground
    font.family: "sans-serif"
    font.pixelSize: 18
    onActivated: host.selected = ["help"]
  }

  TestCase {
    name: "PickerKeyboard"
    when: windowShown

    function init() {
      removal.close()
      accounts.close()
      contacts.close()
      host.mode = ""
      events.expanded = false
      host.selected = []
      host.contactSelections = 0
      host.applicationActivations = 0
      parking.forceActiveFocus()
    }

    function activate(mode) {
      host.mode = mode
      wait(20)
      parking.forceActiveFocus()
    }

    function focused() { return host.Window.window.activeFocusItem }

    function test_provider_choice_uses_tab_and_space() {
      activate("providers")
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Space)
      compare(host.selected, ["gmail"])
      compare(host.applicationActivations, 0)
    }

    function test_removal_starts_on_cancel_and_cycles_without_removing() {
      activate("removal")
      removal.openFor({ id: "synthetic", email: "alex@example.test" })
      tryCompare(removal, "opened", true)
      compare(focused().text, "Cancel")
      keyClick(Qt.Key_Tab)
      compare(focused().text, "Remove")
      keyClick(Qt.Key_Tab, Qt.ShiftModifier)
      compare(focused().text, "Cancel")
      keyClick(Qt.Key_Return)
      tryCompare(removal, "opened", false)
      compare(host.selected, [])
    }

    function test_removal_requires_explicit_focused_confirmation() {
      activate("removal")
      var request = { id: "synthetic", email: "alex@example.test" }
      removal.openFor(request)
      tryCompare(removal, "opened", true)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Return)
      compare(host.selected, [request])
      tryCompare(removal, "opened", false)
    }

    function test_switcher_management_actions_are_reachable() {
      activate("accounts")
      accounts.openCentered()
      tryCompare(accounts, "opened", true)
      keyClick(Qt.Key_Tab)
      compare(focused().text, "Add a mailbox...")
      keyClick(Qt.Key_Return)
      compare(host.selected, ["add"])
      accounts.openCentered()
      tryCompare(accounts, "opened", true)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Tab)
      compare(focused().text, "Manage accounts...")
      keyClick(Qt.Key_Space)
      compare(host.selected, ["manage"])
    }

    function test_contacts_can_choose_cc_without_the_pointer() {
      activate("contacts")
      contacts.open()
      tryCompare(contacts, "opened", true)
      keyClick(Qt.Key_Tab)
      compare(focused().text, "+ To")
      keyClick(Qt.Key_Tab)
      compare(focused().text, "+ Cc")
      keyClick(Qt.Key_Return)
      compare(host.selected, [host.contact, "cc"])
      compare(host.contactSelections, 1)
      tryCompare(contacts, "opened", false)
    }

    function test_contact_cc_pointer_action_does_not_also_choose_to() {
      activate("contacts")
      contacts.open()
      tryCompare(contacts, "opened", true)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Tab)
      var ccButton = focused()
      mouseClick(ccButton, ccButton.width / 2, ccButton.height / 2)
      compare(host.selected, [host.contact, "cc"])
      compare(host.contactSelections, 1)
      tryCompare(contacts, "opened", false)
    }

    function test_escape_cancels_removal_without_confirmation() {
      activate("removal")
      removal.openFor({ id: "synthetic", email: "alex@example.test" })
      tryCompare(removal, "opened", true)
      keyClick(Qt.Key_Escape)
      tryCompare(removal, "opened", false)
      compare(host.selected, [])
      compare(removal.request, null)
    }

    function test_event_expansion_and_add_are_explicit_keyboard_actions() {
      activate("events")
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Space)
      compare(events.expanded, true)
      compare(host.selected, [])
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Return)
      compare(host.selected, [host.suggestion])
      compare(host.applicationActivations, 0)
    }

    function test_link_preserves_global_modified_keys() {
      activate("link")
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Return, Qt.ControlModifier)
      compare(host.selected, [])
      keyClick(Qt.Key_Return)
      compare(host.selected, ["help"])
      compare(host.applicationActivations, 0)
    }

    function test_capture_keyboard_focus() {
      if (host.captureDirectory === "") skip("Capture directory was not requested")
      var modes = ["providers", "removal", "accounts", "contacts", "events", "link"]
      for (var modeIndex = 0; modeIndex < modes.length; modeIndex++) {
        init()
        activate(modes[modeIndex])
        if (host.mode === "removal") removal.openFor({id:"synthetic",email:"alex@example.test"})
        else if (host.mode === "accounts") accounts.openCentered()
        else if (host.mode === "contacts") contacts.open()
        wait(50)
        if (host.mode !== "removal") keyClick(Qt.Key_Tab)
        mouseMove(host, host.width - 5, host.height - 5)
        wait(150)
        grabImage(host).save(host.captureDirectory + "/" + host.mode + ".png")
      }
    }
  }
}

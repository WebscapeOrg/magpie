import QtQuick 2.15
import QtTest 1.3
import qs.Commons
import qs.Commons as Commons
import "../../components" as Mail
import "../.." as Omamail
import "../../account/Accounts.js" as Accounts

Item {
  width: 700
  height: 900

  QtObject {
    id: gmailAuth
    property bool credentialsPresent: true
    property bool loggedIn: false
    property bool loginBusy: false
    property bool toolsChecked: true
    property bool toolsPresent: true
    property var missingTools: []
    property string lastError: ""
    property string clientId: "000000-abc.apps.googleusercontent.com"
    property var credentials: null
    property int credentialSaves: 0
    signal credentialsSaved()
    function saveCredentials(_text) { credentialSaves++ }
  }

  QtObject {
    id: gmailService
    property var auth: gmailAuth
    property string accountEmail: ""
    property string accountAddress: ""
    property string accountName: ""
    property var saved: null
    property int signIns: 0
    function configureCurrentAccount(values) { saved = values }
    function signIn() { signIns++ }
    function openCloudConsole() {}
    function openGmailApiPage() {}
    function openProviderWebsite(_id) {}
  }

  Mail.SetupPage {
    id: gmailPage
    width: 600
    service: gmailService
    textColor: Commons.Color.foreground
    dimColor: Commons.Color.foreground
    dangerColor: Commons.Color.accent
    accentColor: Commons.Color.accent
    panelFontFamily: "monospace"
  }

  Omamail.Service {
    id: realService
    shell: shellStore
    manifest: ({ id: "omamail", __sourceDir: "/tmp/omamail-test" })
  }
  QtObject {
    id: shellStore
    function updateEntryInline(_id, _entry) {}
    function hide(_id) {}
  }

  TestCase {
    name: "SetupNameField"
    when: windowShown

    function gmailField(name) { return findChild(gmailPage, name) }

    function test_a_second_gmail_mailbox_can_be_named_and_the_name_goes_with_the_sign_in() {
      compare(gmailPage.configured, true)
      var name = gmailField("account-name-field")
      verify(name !== null)
      verify(name.visible, "the field is on the page even with the client step folded")
      name.text = "Work"
      gmailPage.signInNamed()
      verify(gmailService.saved !== null)
      compare(gmailService.saved.label, "Work")
      compare(gmailService.signIns, 1, "and the sign-in follows")
      gmailService.saved = null
      gmailService.accountName = "Work"
      gmailPage.signInNamed()
      compare(gmailService.saved, null, "an unchanged name is not written again")
      name.text = "Work mail"
      gmailPage.save()
      compare(gmailService.saved.label, "Work mail", "saving the client saves the name too")
      compare(gmailAuth.credentialSaves, 1)
    }

    // Invariant: a draft has a position before an account ID; naming it must preserve that current draft.
    function test_naming_a_draft_keeps_it_current() {
      var list = Accounts.emptyList()
      list = Accounts.add(list, {email: "ada@example.com", provider: "gmail", label: "", signature: ""})
      list = Accounts.setActive(list, "ada@example.com")
      realService.activeIndex = -1
      realService.accountList = list
      realService.accountsLoaded = true
      wait(0)
      realService.refreshCurrent()
      tryCompare(realService, "activeAccountId", "ada@example.com")
      realService.addAccount()
      compare(realService.activeIndex, 1, "the draft is the current mailbox, by position")
      var draft = realService.accountAt(1)
      verify(draft !== null)
      compare(realService.current, draft)
      realService.configureCurrentAccount({ label: "Work" })
      compare(realService.activeIndex, 1, "and still is once named")
      compare(realService.current, realService.accountAt(1))
      compare(String(realService.accountList.accounts[1].label || ""), "Work")
      compare(realService.accountName, "Work", "which is what the field reads back")
    }

    function test_gmail_name_can_be_cleared_without_changing_the_account_address() {
      gmailService.accountName = "Personal"
      gmailService.accountEmail = "ada@example.com"
      gmailPage.syncFromStore()
      var name = gmailField("account-name-field")
      compare(name.text, "Personal")
      name.text = "  "
      gmailService.saved = null
      gmailPage.saveName()
      verify(gmailService.saved !== null)
      compare(gmailService.saved.label, "")
      compare(gmailService.saved.email, undefined)
      compare(gmailService.accountEmail, "ada@example.com")
    }
  }
}

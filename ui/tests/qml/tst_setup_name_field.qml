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
    id: fakeAuth
    property bool loggedIn: false
    property bool loginBusy: false
    property bool toolsChecked: true
    property var missingTools: []
    property string lastError: ""
    property var settings: ({ username: "", aliases: [], imapHost: "", imapPort: 993, smtpHost: "", smtpPort: 465 })
  }

  QtObject {
    id: fakeService
    property var auth: fakeAuth
    property string accountAddress: ""
    property string accountName: "Work"
    property string accountSenderName: "Ada Lovelace"
    property bool backendCanNameSender: false
    property var saved: null
    property var signedIn: null
    function configureCurrentAccount(values) { saved = values }
    function configureCurrentAccountAndSignIn(values, secret) { signedIn = values }
  }

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

  Mail.ImapSetupPage {
    id: page
    width: 600
    service: fakeService
    textColor: Commons.Color.foreground
    dimColor: Commons.Color.foreground
    dangerColor: Commons.Color.accent
    accentColor: Commons.Color.accent
    panelFontFamily: "monospace"
  }

  QtObject {
    id: outlookService
    property var auth: null
    property string accountAddress: "ada@hotmail.com"
    property string accountSenderName: ""
    property bool backendCanNameSender: true
    property var saved: null
    function configureCurrentAccount(values) { saved = values }
  }

  Mail.OutlookSetupPage {
    id: outlookPage
    width: 600
    service: outlookService
    textColor: Color.foreground
    dimColor: Color.foreground
    dangerColor: Color.accent
    accentColor: Color.accent
    panelFontFamily: "monospace"
  }

  TestCase {
    name: "SetupNameField"
    when: windowShown

    function field(name) { return findChild(page, name) }
    function outlookField(name) { return findChild(outlookPage, name) }
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
      list = Accounts.add(list, { email: "ada@example.com", provider: "imap", clientId: "", clientSecret: "",
        imap: { imapHost: "imap.example.com", imapPort: 993, smtpHost: "smtp.example.com", smtpPort: 465,
          username: "ada@example.com", aliases: [], insecure: false }, label: "", signature: "" })
      list = Accounts.setActive(list, "imap:ada@example.com")
      realService.activeIndex = -1
      realService.accountList = list
      realService.accountsLoaded = true
      wait(0)
      realService.refreshCurrent()
      tryCompare(realService, "activeAccountId", "imap:ada@example.com")
      realService.addAccount("gmail")
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

    function test_the_name_comes_from_the_store_and_goes_back_with_the_form() {
      var name = field("account-name-field")
      verify(name !== null)
      compare(name.text, "Work", "the name the entry has is what the field shows")
      field("imap-address-field").text = "ada@icloud.com"
      name.text = "  Ada at home  "
      page.save()
      verify(fakeService.saved !== null)
      compare(fakeService.saved.label, "Ada at home", "trimmed, with the rest of the form")
      compare(fakeService.saved.email, "ada@icloud.com")
      page.signIn()
      verify(fakeService.signedIn !== null)
      compare(fakeService.signedIn.label, "Ada at home", "and on the way to a sign-in")
      name.text = ""
      page.save()
      compare(fakeService.saved.label, "", "empty is no name, which puts the address back")
    }

    // Invariant: older backends cannot send a stored sender name; hiding the field must also preserve its value.
    function test_imap_setup_names_the_sender_only_on_a_backend_that_writes_it() {
      var sender = field("sender-name-field")
      verify(sender !== null)
      verify(!sender.visible, "hidden while the backend cannot name the sender")
      field("imap-address-field").text = "ada@icloud.com"
      page.save()
      compare(fakeService.saved.senderName, undefined, "and left out of the form")

      fakeService.backendCanNameSender = true
      verify(sender.visible)
      compare(sender.text, "Ada Lovelace", "the name the entry has is what the field shows")
      verify(sender.placeholderText.indexOf("Your name") === 0)
      verify(field("account-name-field").placeholderText.indexOf("Mailbox name") === 0)
      sender.text = "  Ada King  "
      field("account-name-field").text = "Home"
      page.save()
      compare(fakeService.saved.senderName, "Ada King", "trimmed, with the rest of the form")
      compare(fakeService.saved.label, "Home", "beside the mailbox name, not in place of it")
      page.signIn()
      compare(fakeService.signedIn.senderName, "Ada King", "and on the way to a sign-in")
      fakeService.backendCanNameSender = false
      page.syncFromStore()
    }

    function test_outlook_switches_expose_the_setting_name() {
      compare(outlookField("outlook-work-switch").Accessible.name, "Work or school account (Microsoft 365)")
      compare(outlookField("outlook-graph-switch").Accessible.name, "Send through Microsoft Graph")
    }

    function test_outlook_setup_names_the_sender() {
      var sender = outlookField("sender-name-field")
      verify(sender !== null)
      verify(sender.visible)
      sender.text = "Ada Lovelace"
      outlookField("outlook-address-field").text = "ada@hotmail.com"
      outlookField("outlook-client-id-field").text = "00000000-0000-0000-0000-000000000000"
      outlookPage.save()
      verify(outlookService.saved !== null)
      compare(outlookService.saved.provider, "outlook")
      compare(outlookService.saved.senderName, "Ada Lovelace")
    }

    function test_configuring_an_account_stores_its_sender_name() {
      var list = Accounts.emptyList()
      list = Accounts.add(list, { email: "ada@example.com", provider: "imap", clientId: "", clientSecret: "",
        imap: { imapHost: "imap.example.com", imapPort: 993, smtpHost: "smtp.example.com", smtpPort: 465,
          username: "ada@example.com", aliases: [], insecure: false }, label: "", signature: "" })
      list = Accounts.setActive(list, "imap:ada@example.com")
      realService.activeIndex = -1
      realService.accountList = list
      realService.accountsLoaded = true
      wait(0)
      realService.refreshCurrent()
      tryCompare(realService, "activeAccountId", "imap:ada@example.com")
      realService.configureCurrentAccount({ senderName: "Ada\nLovelace" })
      compare(String(realService.accountList.accounts[0].senderName || ""), "Ada Lovelace")
      compare(realService.accountSenderName, "Ada Lovelace", "which is what the field reads back")
      realService.configureCurrentAccount({ label: "Work" })
      compare(String(realService.accountList.accounts[0].senderName || ""), "Ada Lovelace",
        "a save without it keeps the name")
    }
  }
}

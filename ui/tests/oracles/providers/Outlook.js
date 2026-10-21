.pragma library

.import "Imap.js" as Imap
.import "../../../providers/ImapProtocol.js" as Protocol
.import "../../../providers/MicrosoftOAuth.js" as Microsoft

// Invariant: Outlook shares IMAP mailbox rules but requires Microsoft OAuth rather than an account password.

var ID = "outlook"
var NAME = "Outlook"
var SUMMARY = "Outlook.com and Hotmail, signed in securely with Microsoft."
var AUTH = "oauth"

var CAPABILITIES = Imap.CAPABILITIES
var MAILBOXES = Imap.MAILBOXES

function searchQuery(text) {
  return Imap.searchQuery(text)
}

function cachedSummaryInSearch(sourceQuery, summary) {
  return Imap.cachedSummaryInSearch(sourceQuery, summary)
}

function labelQuery(name) {
  return Imap.labelQuery(name)
}

function webHomeUrl() {
  return "https://outlook.live.com/mail/"
}

// Invariant: Outlook uses Microsoft's fixed IMAP host and chooses the SMTP host by tenant; Graph can supply sending.
function settings(address, tenant, send) {
  var work = Microsoft.isWorkTenant(tenant)
  return Protocol.normalizeSettings({
    imapHost: "outlook.office365.com",
    imapPort: 993,
    smtpHost: work ? "smtp.office365.com" : "smtp-mail.outlook.com",
    smtpPort: 587,
    username: String(address === undefined || address === null ? "" : address).trim(),
    insecure: false,
    send: send
  })
}

var NATIVE_SYNC = true

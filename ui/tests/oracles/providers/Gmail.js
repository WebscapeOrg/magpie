.pragma library

.import "../../../providers/GmailApi.js" as Api

// Invariant: These historical descriptor rules are test references; Rust owns live provider operations.

var ID = "gmail"
var NAME = "Gmail"

var SUMMARY = "Google's own API. Needs an OAuth client you create once."

var AUTH = "oauth"
var NATIVE_SYNC = true

// Invariant: Gmail uses one square mark for both the chooser icon and the setup logo.
var MARK = "gmail.png"

var CAPABILITIES = {
  labels: true,
  manageLabels: true,
  move: true,
  threads: true,
  archive: true,
  spam: true,
  star: true,
  batch: true,
  web: true,
  webBox: true,
  search: true,
  send: true
}

// Invariant: Mailbox queries also represent views such as unread that have no label ID.
var MAILBOXES = [
  { key: "inbox", label: "Inbox", icon: "inbox", query: "in:inbox" },
  // Invariant: Category exclusion fails open to all unread Inbox mail when categories are unavailable;
  // Updates remain included for receipts, deliveries and notifications.
  { key: "unread", label: "Unread", icon: "unread",
    query: "in:inbox is:unread -category:promotions -category:social -category:forums" },
  { key: "starred", label: "Starred", icon: "star", query: "is:starred" },
  { key: "sent", label: "Sent", icon: "sent", query: "in:sent" },
  { key: "drafts", label: "Drafts", icon: "compose", query: "in:drafts" },
  { key: "all", label: "All mail", icon: "archive", query: "in:anywhere -in:spam -in:trash", optional: true },
  // Invariant: Ordinary Gmail search excludes Spam, so the sidebar must offer a direct route.
  { key: "spam", label: "Spam", icon: "spam", query: "in:spam", optional: true },
  { key: "trash", label: "Trash", icon: "trash", query: "in:trash", optional: true }
]

// Invariant: Typed searches retain Gmail syntax verbatim.
function searchQuery(text) {
  return String(text === undefined || text === null ? "" : text).trim()
}

// Invariant: A plain-text preview excludes cached Spam and Trash rows, matching ordinary Gmail search.
function cachedSummaryInSearch(sourceQuery, summary) {
  var labels = summary && Array.isArray(summary.labelIds) ? summary.labelIds : []
  for (var itemIndex = 0; itemIndex < labels.length; itemIndex++) {
    var label = String(labels[itemIndex] || "").toUpperCase()
    if (label === "SPAM" || label === "TRASH") return false
  }
  var source = String(sourceQuery || "").toLowerCase()
  return !/(^|\s)in:(spam|trash)(\s|$)/.test(source)
}

function addressQuery(field, address) {
  var value = String(address === undefined || address === null ? "" : address).trim()
  if (value === "" || /[\s"]/.test(value)) return ""
  return (field === "to" ? "to:" : "from:") + value
}

function labelQuery(name) {
  var value = String(name === undefined || name === null ? "" : name).trim()
  return value === "" ? "" : "label:" + value
}

// Invariant: Browser profile selection is unknown; reference URLs use the available /u/0 profile.
function webMessageUrl(messageId) {
  return Api.webMessageUrl(messageId, 0)
}

function webBoxUrl(query) {
  return Api.webSearchUrl(query, 0)
}

function webHomeUrl() {
  return Api.webHomeUrl(0)
}

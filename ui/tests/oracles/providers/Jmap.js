.pragma library

.import "../../../providers/JmapProtocol.js" as Protocol

// Invariant: These historical descriptor rules are test references; Rust owns live JMAP operations.

var ID = "jmap"
var NAME = "JMAP"

var SUMMARY = "Any server that speaks JMAP"

// Invariant: Password sign-in detects Basic then Bearer rather than asking the user for a scheme.
var AUTH = "password"

// Invariant: Account capabilities may refuse this provider ceiling but never extend it.
var CAPABILITIES = {
  // Invariant: The reference presentation treats JMAP membership as folders rather than Gmail-style labels.
  labels: false,
  threads: true,
  conversations: true,
  archive: true,
  // Invariant: Spam requires evidence that the server trains on Junk moves; otherwise the account refuses it.
  spam: true,
  // Invariant: The JMAP mail contract includes the $flagged keyword.
  star: true,
  batch: true,
  search: true,
  // Invariant: Sending additionally requires the account's submission capability.
  send: true,
  // Invariant: A generic JMAP account has no known webmail URL.
  web: false,
  webBox: false
}

// Invariant: Mailbox roles survive server naming differences; unresolved optional roles disappear.
// Queries retain role or mailbox IDs rather than mutable display names.
var MAILBOXES = [
  { key: "inbox", label: "Inbox", icon: "inbox", query: "role:inbox" },
  { key: "unread", label: "Unread", icon: "unread", query: "role:inbox unseen" },
  { key: "starred", label: "Flagged", icon: "star", query: "role:inbox flagged" },
  { key: "sent", label: "Sent", icon: "sent", query: "role:sent" },
  { key: "drafts", label: "Drafts", icon: "compose", query: "role:drafts" },
  { key: "archive", label: "Archive", icon: "archive", query: "role:archive", optional: true },
  { key: "spam", label: "Junk", icon: "spam", query: "role:junk", optional: true },
  { key: "trash", label: "Trash", icon: "trash", query: "role:trash", optional: true }
]

// Invariant: Typed JMAP search spans the account and preserves the complete text after its prefix.
function searchQuery(text) {
  var value = Protocol.trimmed(text)
  return value === "" ? "" : "text:" + value
}

// Invariant: Ordinary text search excludes Junk and Trash, including their cached preview rows.
function cachedSummaryInSearch(sourceQuery, summary) {
  var labels = summary && Array.isArray(summary.labelIds) ? summary.labelIds : []
  for (var itemIndex = 0; itemIndex < labels.length; itemIndex++) {
    var label = String(labels[itemIndex] || "").toUpperCase()
    if (label === "SPAM" || label === "TRASH") return false
  }
  var source = Protocol.trimmed(sourceQuery).toLowerCase()
  return !/(^|\s)role:(junk|trash)(\s|$)/.test(source)
}

// Invariant: A mailbox query uses its stable ID, never its mutable or duplicated display name.
function labelQuery(id) {
  var value = Protocol.trimmed(id)
  return value === "" ? "" : "mailbox:" + value
}

// Invariant: Account detail exposes the recognizable host, not the client's session path.
function detail(account) {
  var settings = (account || {}).jmap || {}
  var host = Protocol.sessionHost(settings.sessionUrl)
  return host === "" ? NAME : NAME + " · " + host
}

var NATIVE_SYNC = true

.pragma library

.import "../../../providers/ImapProtocol.js" as Protocol

// Invariant: These historical descriptor rules are test references; Rust owns live IMAP operations.

var ID = "imap"
var NAME = "IMAP"
var SUMMARY = "Any standard mailbox — Fastmail, iCloud, Zoho, your own server."
var AUTH = "password"

var CAPABILITIES = {
  labels: false,
  // Invariant: A single-folder message supports moves without supporting multiple labels.
  move: true,
  manageLabels: true,
  // Invariant: IMAP has no server thread ID; References threading is a separate client decision.
  threads: false,
  // Invariant: Archive is a ceiling capability; each account must resolve a destination.
  archive: true,
  // Invariant: Moving to Junk does not establish that the server trains a spam filter.
  spam: false,
  star: true,
  batch: true,
  search: true,
  send: true,
  web: false
}

// Invariant: SPECIAL-USE folders replace these fallback names; callers treat folder queries as opaque.
var MAILBOXES = [
  { key: "inbox", label: "Inbox", icon: "inbox", query: "folder:INBOX" },
  { key: "unread", label: "Unread", icon: "unread", query: "folder:INBOX UNSEEN" },
  { key: "starred", label: "Flagged", icon: "star", query: "folder:INBOX FLAGGED" },
  { key: "sent", label: "Sent", icon: "sent", query: "folder:\\Sent" },
  { key: "drafts", label: "Drafts", icon: "compose", query: "folder:\\Drafts" },
  { key: "archive", label: "Archive", icon: "archive", query: "folder:\\Archive", optional: true },
  { key: "spam", label: "Junk", icon: "spam", query: "folder:\\Junk", optional: true },
  { key: "trash", label: "Trash", icon: "trash", query: "folder:\\Trash", optional: true }
]

// Algorithm: Translate familiar address/subject operators to IMAP criteria and remaining words to TEXT.
// Empty or wildcard-only operators stay literal text so they cannot widen a search.
function searchQuery(text) {
  var value = String(text === undefined || text === null ? "" : text).trim()
  if (value === "") return ""
  var pattern = /(from|to|subject):\s*(?:"([^"]*)"|(\S*))|(\S+)/gi
  var words = []
  var parts = []
  var match
  while ((match = pattern.exec(value)) !== null) {
    if (match[1] === undefined) {
      words.push(match[4])
      continue
    }
    var term = (match[2] !== undefined ? match[2] : match[3]).replace(/\*/g, "")
    if (term !== "") parts.push(match[1].toUpperCase() + " " + JSON.stringify(term))
    else words.push(match[0])
  }
  var plain = words.join(" ").trim()
  if (plain !== "") parts.push("TEXT " + JSON.stringify(plain))
  if (parts.length === 0) parts.push("TEXT " + JSON.stringify(value))
  return "folder:INBOX " + parts.join(" ")
}

// Invariant: A typed IMAP search selects INBOX; other cached folders cannot preview its results.
function cachedSummaryInSearch(sourceQuery, summary) {
  return Protocol.parseQuery(sourceQuery).folder.toUpperCase() === "INBOX"
}

// Invariant: Address searches use IMAP substring matching; selecting a folder is a separate query.
function addressQuery(field, address) {
  var value = String(address === undefined || address === null ? "" : address).trim()
  if (value === "") return ""
  return "folder:INBOX " + (field === "to" ? "TO " : "FROM ") + JSON.stringify(value)
}

function labelQuery(name) {
  var value = String(name === undefined || name === null ? "" : name).trim()
  return value === "" ? "" : "folder:" + JSON.stringify(value)
}

var NATIVE_SYNC = true

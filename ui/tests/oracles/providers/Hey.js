.pragma library

.import "../../../providers/HeyCli.js" as Cli

// Invariant: These test descriptors model the official HEY CLI, never private web endpoints.

var ID = "hey"
var NAME = "HEY"

var SUMMARY = "37signals' own mailbox, read through the HEY CLI they publish."

// Invariant: The HEY CLI owns sign-in and credential storage.
var AUTH = "cli"

// Invariant: CLIENT_URL names the official CLI; MARK is square artwork and LOGO is the wordmark.
var CLIENT_URL = "https://github.com/basecamp/hey-cli"

var MARK = "hey-mark.png"
var LOGO = "hey.png"

var CAPABILITIES = {
  labels: true,
  // Invariant: HEY box moves cannot satisfy the user-named destination contract.
  move: false,
  threads: true,
  // Invariant: HEY lists one row per topic, so its rows already represent conversations.
  conversations: true,
  // Invariant: Moving to a HEY box is not archiving and must not inherit the archive action.
  archive: false,
  spam: true,
  // Invariant: Set Aside and Reply Later move threads; neither implements a star.
  star: false,
  batch: true,
  web: true,
  // Invariant: A HEY URL cannot represent every filtered mailbox, so webBox stays unavailable.
  webBox: false,
  search: true,
  send: true
}

// Invariant: Query strings are opaque to callers; the shared inbox key maps to HEY's Imbox.
var MAILBOXES = [
  { key: "inbox", label: "Imbox", icon: "inbox", query: "box:imbox" },
  // Invariant: HEY provides no unseen box; the unread query filters the Imbox listing.
  { key: "unread", label: "New for you", icon: "unread", query: "box:imbox unseen" },
  { key: "drafts", label: "Drafts", icon: "compose", query: "drafts:" },
  { key: "later", label: "Reply Later", icon: "reply", query: "box:laterbox" },
  { key: "aside", label: "Set Aside", icon: "pin", query: "box:asidebox" },
  { key: "feed", label: "The Feed", icon: "label", query: "box:feedbox" },
  { key: "papertrail", label: "Paper Trail", icon: "archive", query: "box:trailbox", optional: true },
  // Invariant: Trash is served through a search although the shared DSL calls it a box.
  { key: "trash", label: "Trash", icon: "trash", query: "box:trash", optional: true }
]

// Invariant: Prefix typed text so mailbox-like words remain a search, not a navigation command.
function searchQuery(text) {
  var value = String(text === undefined || text === null ? "" : text).trim()
  return value === "" ? "" : "search:" + value
}

// Invariant: Unrefined HEY text search spans the mailbox, so every cached box is eligible.
function cachedSummaryInSearch(sourceQuery, summary) {
  return true
}

// Invariant: HEY address search cannot distinguish From and To.
function addressQuery(field, address) {
  var value = String(address === undefined || address === null ? "" : address).trim()
  return value === "" ? "" : "search:" + value
}

function labelQuery(name) {
  var value = String(name === undefined || name === null ? "" : name).trim()
  return value === "" ? "" : "label:" + value
}

// Invariant: Web thread URLs use both numeric ID parts; filtered mailboxes have no equivalent URL.
function webMessageUrl(messageId) {
  return Cli.webMessageUrl(messageId)
}

function webHomeUrl() {
  return Cli.webHomeUrl()
}

var NATIVE_SYNC = true

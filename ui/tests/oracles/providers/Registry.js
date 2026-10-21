.pragma library

.import "Gmail.js" as Gmail
.import "Outlook.js" as Outlook
.import "Imap.js" as Imap
.import "Hey.js" as Hey
.import "Jmap.js" as Jmap

// Invariant: This independent reference registry derives answers from its own descriptors,
// not current generated native metadata. Rust owns production query resolution.

// Invariant: Undeclared capabilities default to unavailable.
function capabilities(values) {
  var raw = values || {}
  return {
    labels: raw.labels === true,
    // Invariant: A named move destination is independent of support for multiple labels.
    move: raw.move === true,
    threads: raw.threads === true,
    // Invariant: Server thread identity does not imply a collapsed listing.
    conversations: raw.conversations === true,
    archive: raw.archive === true,
    spam: raw.spam === true,
    star: raw.star === true,
    batch: raw.batch === true,
    web: raw.web === true,
    // Invariant: A message URL does not imply that every mailbox view has a corresponding URL.
    webBox: raw.webBox === true,
    search: raw.search === true,
    manageLabels: raw.manageLabels === true,
    send: raw.send === true
  }
}

function mailbox(raw) {
  var entry = raw || {}
  return {
    key: String(entry.key || ""),
    label: String(entry.label || ""),
    icon: String(entry.icon || ""),
    query: String(entry.query || ""),
    optional: entry.optional === true
  }
}

function define(source) {
  var raw = source || {}
  var boxes = []
  var list = Array.isArray(raw.MAILBOXES) ? raw.MAILBOXES : []
  for (var itemIndex = 0; itemIndex < list.length; itemIndex++) {
    var box = mailbox(list[itemIndex])
    boxes.push(box)
  }
  return {
    id: String(raw.ID || ""),
    name: String(raw.NAME || ""),
    summary: String(raw.SUMMARY || ""),
    auth: String(raw.AUTH || "none"),
    nativeSync: raw.NATIVE_SYNC === true,
    // Invariant: The square mark and wider setup logo are distinct; providers with one asset reuse it.
    mark: String(raw.MARK || ""),
    logo: String(raw.LOGO || raw.MARK || ""),
    unavailable: String(raw.UNAVAILABLE || ""),
    capabilities: capabilities(raw.CAPABILITIES),
    addressSearch: typeof raw.addressQuery === "function",
    inheritedDefault: "in:inbox",
    mailboxes: boxes,
    searchQuery: typeof raw.searchQuery === "function" ? raw.searchQuery : function() { return "" },
    cachedSummaryInSearch: typeof raw.cachedSummaryInSearch === "function"
      ? raw.cachedSummaryInSearch : function() { return false },
    labelQuery: typeof raw.labelQuery === "function" ? raw.labelQuery : function() { return "" },
    addressQuery: typeof raw.addressQuery === "function" ? raw.addressQuery : function() { return "" },
    webMessageUrl: typeof raw.webMessageUrl === "function" ? raw.webMessageUrl : function() { return "" },
    webBoxUrl: typeof raw.webBoxUrl === "function" ? raw.webBoxUrl : function() { return "" },
    webHomeUrl: typeof raw.webHomeUrl === "function" ? raw.webHomeUrl : function() { return "" },
    clientUrl: String(raw.CLIENT_URL || ""),
    detail: typeof raw.detail === "function" ? raw.detail : function() { return "" }
  }
}

// Invariant: Specific hosted services precede protocols; JMAP precedes the IMAP fallback.
var ALL = [define(Gmail), define(Outlook), define(Hey), define(Jmap), define(Imap)]

var DEFAULT_ID = "gmail"

function ids() {
  var output = []
  for (var itemIndex = 0; itemIndex < ALL.length; itemIndex++) output.push(ALL[itemIndex].id)
  return output
}

// Invariant: Unknown provider IDs fall back to Gmail for older account records.
function get(id) {
  var wanted = String(id === undefined || id === null ? "" : id).trim().toLowerCase()
  for (var itemIndex = 0; itemIndex < ALL.length; itemIndex++) {
    if (ALL[itemIndex].id === wanted) return ALL[itemIndex]
  }
  return ALL[0]
}

function exists(id) {
  var wanted = String(id === undefined || id === null ? "" : id).trim().toLowerCase()
  for (var itemIndex = 0; itemIndex < ALL.length; itemIndex++) {
    if (ALL[itemIndex].id === wanted) return true
  }
  return false
}

function isConnectable(id) {
  return !get(id).unavailable
}

function unavailableReason(id) {
  return String(get(id).unavailable || "")
}

// Invariant: Per-account refusals can withdraw provider capabilities but cannot add them.
function refuses(refusals, capability) {
  if (!refusals) return false
  // Invariant: Refusal presence matters; its value only supplies the user-facing reason.
  var reason = refusals[String(capability)]
  return reason !== undefined && reason !== null
}

function can(id, capability, refusals) {
  if (get(id).capabilities[String(capability)] !== true) return false
  return !refuses(refusals, capability)
}

function refusal(id, capability, refusals) {
  if (get(id).capabilities[String(capability)] !== true) return ""
  if (!refuses(refusals, capability)) return ""
  return String(refusals[String(capability)])
}

// Invariant: Account-specific missing roles remove sidebar rows and their positional shortcuts.
function mailboxes(id, absent) {
  var list = get(id).mailboxes
  var missing = Array.isArray(absent) ? absent : []
  var drop = []
  for (var itemIndex = 0; itemIndex < missing.length; itemIndex++) drop.push(String(missing[itemIndex]))
  var output = []
  for (var nestedIndex = 0; nestedIndex < list.length; nestedIndex++) {
    if (drop.indexOf(list[nestedIndex].key) < 0) output.push(list[nestedIndex])
  }
  return output
}

function mailboxIndex(id, key) {
  var list = get(id).mailboxes
  var wanted = String(key === undefined || key === null ? "" : key)
  for (var itemIndex = 0; itemIndex < list.length; itemIndex++) {
    if (list[itemIndex].key === wanted) return itemIndex
  }
  return 0
}

// Invariant: Every provider lists Inbox first, making cross-account mailbox fallback predictable.
function mailboxFor(id, key) {
  var list = get(id).mailboxes
  return list[mailboxIndex(id, key)]
}

function hasMailbox(id, key) {
  var list = get(id).mailboxes
  var wanted = String(key === undefined || key === null ? "" : key)
  for (var itemIndex = 0; itemIndex < list.length; itemIndex++) {
    if (list[itemIndex].key === wanted) return true
  }
  return false
}

// Invariant: Typed search wins; a custom default applies only to Inbox; otherwise use the mailbox query.
function query(id, mailboxKey, searchText, defaultQuery) {
  var provider = get(id)
  var text = String(searchText === undefined || searchText === null ? "" : searchText).trim()
  if (text !== "") return provider.searchQuery(text)

  var custom = String(defaultQuery === undefined || defaultQuery === null ? "" : defaultQuery).trim()
  // Invariant: The inherited Gmail default must not become an IMAP criterion or a HEY text search.
  if (provider.id !== "gmail" && custom === "in:inbox") custom = ""
  if (custom !== "" && String(mailboxKey) === "inbox") return custom

  return mailboxFor(id, mailboxKey).query
}

function cachedSummaryInSearch(id, sourceQuery, summary) {
  return get(id).cachedSummaryInSearch(sourceQuery, summary)
}

// Invariant: Selecting a label or folder is separate from typing a text search.
function labelQuery(id, name) {
  return get(id).labelQuery(name)
}

function addressQuery(id, field, address) {
  return get(id).addressQuery(field, address)
}

function unreadQuery(id) {
  return mailboxFor(id, "unread").query
}

function badge(id) {
  return get(id).name
}

function summary(id) {
  return String(get(id).summary || "")
}

function detail(id, account) {
  return String(get(id).detail(account) || "")
}

// Invariant: Artwork names stay relative; the consuming view chooses the assets directory.
function mark(id) {
  return String(get(id).mark || "")
}

function logo(id) {
  return String(get(id).logo || "")
}

function authKind(id) {
  return String(get(id).auth || "none")
}

function usesOAuth(id) {
  return authKind(id) === "oauth"
}

function usesPassword(id) {
  return authKind(id) === "password"
}

// Invariant: CLI authentication delegates browser interaction and credential storage to the provider client.
function usesCli(id) {
  return authKind(id) === "cli"
}

function webMessageUrl(id, messageId) {
  return get(id).webMessageUrl(messageId)
}

function webBoxUrl(id, query) {
  return get(id).webBoxUrl(query)
}

function webHomeUrl(id) {
  return get(id).webHomeUrl()
}

function clientUrl(id) {
  return String(get(id).clientUrl || "")
}

function nativeSync(id) {
  return get(id).nativeSync === true
}

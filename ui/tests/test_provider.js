const assert = require("assert")
const { load, deepEqual } = require("./load")

const provider = load("providers/Registry.js")
for (const api of [1, 5, 6, 7]) {
  const boxes = provider.mailboxes("imap", [], api)
  assert.strictEqual(boxes.some(box => box.key === "archive"), api < 6)
  assert.strictEqual(boxes.some(box => box.key === "all"), api >= 6)
  assert.strictEqual(boxes.find(box => box.key === (api < 6 ? "archive" : "all")).query,
    api < 6 ? "folder:\\Archive" : "search:ALL")
}
// Invariant: Historical query functions are explicit reference oracles; Rust separately verifies their captured wire fixtures.
const legacyQueries = load("tests/oracles/providers/Registry.js")
for (const method of ["query", "cachedSummaryInSearch", "labelQuery", "addressQuery", "webMessageUrl", "webBoxUrl"])
  provider[method] = legacyQueries[method]

// Invariant: Provider IDs and chooser order follow docs/providers/README.md.
deepEqual(provider.ids(), ["gmail", "outlook", "hey", "jmap", "imap"])
assert.strictEqual(provider.get("gmail").name, "Gmail")
assert.strictEqual(provider.get("outlook").name, "Outlook")
assert.strictEqual(provider.get("imap").name, "IMAP")
assert.strictEqual(provider.get("hey").name, "HEY")
assert.strictEqual(provider.get("jmap").name, "JMAP")
assert.strictEqual(provider.exists("jmap"), true)

// Invariant: Unknown provider IDs retain the presentation fallback without becoming known providers.
assert.strictEqual(provider.get("nonesuch").id, "gmail")
assert.strictEqual(provider.get("").id, "gmail")
assert.strictEqual(provider.get(null).id, "gmail")
assert.strictEqual(provider.get(undefined).id, "gmail")
assert.strictEqual(provider.get("  GMAIL  ").id, "gmail", "ids are trimmed and folded")
assert.strictEqual(provider.exists("nonesuch"), false)
assert.strictEqual(provider.exists("imap"), true)

// Invariant: Missing provider capabilities are explicit false values so controls cannot offer unsupported actions.

assert.strictEqual(provider.can("gmail", "labels"), true)
assert.strictEqual(provider.can("imap", "labels"), false)
assert.strictEqual(provider.can("outlook", "labels"), false)
assert.strictEqual(provider.can("gmail", "manageLabels"), true)
assert.strictEqual(provider.can("imap", "manageLabels"), true)
assert.strictEqual(provider.can("hey", "manageLabels"), false, "HEY's labels are HEY's own")

assert.strictEqual(provider.addressQuery("gmail", "from", "ada@example.com"), "from:ada@example.com")
assert.strictEqual(provider.addressQuery("gmail", "to", " ada@example.com "), "to:ada@example.com")
assert.strictEqual(provider.addressQuery("gmail", "from", "a b"), "", "a space would end the operator")
assert.strictEqual(provider.addressQuery("imap", "from", "ada@example.com"), 'folder:INBOX FROM "ada@example.com"')
assert.strictEqual(provider.addressQuery("imap", "to", 'a"b'), 'folder:INBOX TO "a\\"b"')
assert.strictEqual(provider.addressQuery("hey", "to", "ada@example.com"), "search:ada@example.com")
assert.strictEqual(provider.addressQuery("imap", "from", ""), "")

assert.strictEqual(provider.query("imap", "inbox", "from: ada@example.com", ""),
  'folder:INBOX FROM "ada@example.com"', "a webmail from: operator, space and all, becomes the IMAP criterion")
assert.strictEqual(provider.query("imap", "inbox", "to:*@example.com invoice", ""),
  'folder:INBOX TO "@example.com" TEXT "invoice"', "wildcards go: IMAP criteria already match substrings")
assert.strictEqual(provider.query("imap", "inbox", "plain words", ""),
  'folder:INBOX TEXT "plain words"', "words without an operator stay one TEXT criterion")
assert.strictEqual(provider.query("imap", "inbox", 'from:"Jane Doe" report', ""),
  'folder:INBOX FROM "Jane Doe" TEXT "report"', "a quoted operator value keeps its spaces")
assert.strictEqual(provider.query("imap", "inbox", "from:", ""),
  'folder:INBOX TEXT "from:"', "an operator with no value searches for what was typed, not for everything")
assert.strictEqual(provider.query("imap", "inbox", "from:*", ""),
  'folder:INBOX TEXT "from:*"', "a wildcard alone is not a criterion either")
assert.strictEqual(provider.query("imap", "inbox", "from:*** invoice", ""),
  'folder:INBOX TEXT "from:*** invoice"', "an operator that strips to nothing is not quietly dropped")
// Invariant: Multiple-label support and user-chosen folder movement are independent capabilities.
assert.strictEqual(provider.can("gmail", "move"), true)
assert.strictEqual(provider.can("imap", "move"), true)
assert.strictEqual(provider.can("outlook", "move"), true)
assert.strictEqual(provider.can("hey", "move"), false, "HEY's destinations are its own")
assert.strictEqual(provider.can("gmail", "spam"), true)
assert.strictEqual(provider.can("imap", "spam"), false, "IMAP has no junk verb worth offering")
assert.strictEqual(provider.can("gmail", "threads"), true)
assert.strictEqual(provider.can("imap", "threads"), false)
assert.strictEqual(provider.can("imap", "star"), true, "\\Flagged is a star")
assert.strictEqual(provider.can("imap", "web"), false, "no web UI to open a message in")
assert.strictEqual(provider.can("gmail", "web"), true)

// Invariant: A provider may link to one message without supporting a link to an arbitrary mailbox view.
assert.strictEqual(provider.can("gmail", "webBox"), true)
assert.strictEqual(provider.can("hey", "web"), true)
assert.strictEqual(provider.can("hey", "webBox"), false)
assert.strictEqual(provider.can("imap", "webBox"), false)
assert.strictEqual(provider.can("outlook", "webBox"), false)

assert.strictEqual(provider.webMessageUrl("hey", "1:2"), "https://app.hey.com/topics/2")
assert.strictEqual(provider.webBoxUrl("hey", "box:feedbox"), "")
assert.strictEqual(provider.webBoxUrl("imap", "folder:INBOX"), "")
assert.strictEqual(provider.webBoxUrl("gmail", "in:inbox"),
  "https://mail.google.com/mail/u/0/#search/in%3Ainbox")
assert.strictEqual(provider.can("gmail", "invented"), false, "an unknown capability is a no")

// Invariant: HEY has no star or archive operation; its other destinations must not impersonate those actions.
assert.strictEqual(provider.can("hey", "send"), true)
assert.strictEqual(provider.can("hey", "search"), true)
assert.strictEqual(provider.can("hey", "spam"), true, "hey spam trains the filter")
assert.strictEqual(provider.can("hey", "threads"), true, "a topic is a conversation")
assert.strictEqual(provider.can("hey", "labels"), true)
assert.strictEqual(provider.can("hey", "star"), false, "HEY has no flag")
assert.strictEqual(provider.can("hey", "archive"), false, "HEY has no archive")

// Invariant: Having thread IDs does not imply that the provider listing already groups conversations.
assert.strictEqual(provider.can("hey", "conversations"), true, "a HEY row is a topic")
assert.strictEqual(provider.can("gmail", "conversations"), false,
  "Gmail has thread ids and still lists messages")
assert.strictEqual(provider.can("imap", "conversations"), false)
assert.strictEqual(provider.can("gmail", "threads"), true,
  "and the two answers are independent of each other")

// Invariant: Account refusals may narrow a provider capability ceiling but cannot grant a missing capability.

assert.strictEqual(provider.can("gmail", "archive"), true)
assert.strictEqual(provider.can("gmail", "archive", null), true)
assert.strictEqual(provider.can("gmail", "archive", undefined), true)
assert.strictEqual(provider.can("gmail", "archive", {}), true,
  "an object with no key for it says nothing about it")

const refusals = {
  archive: "This account has no Archive mailbox",
  spam: "This server is not known to learn from its Junk mailbox"
}
assert.strictEqual(provider.can("gmail", "archive", refusals), false)
assert.strictEqual(provider.can("gmail", "spam", refusals), false)
assert.strictEqual(provider.can("gmail", "star", refusals), true,
  "a refusal takes away only the keys it names")

assert.strictEqual(provider.can("hey", "archive", { archive: "" }), false)
assert.strictEqual(provider.can("imap", "spam", { spam: "" }), false)
assert.strictEqual(provider.can("hey", "star", { star: "of course it can" }), false)

// Invariant: Only a withdrawn offered capability has an account-specific refusal reason.
assert.strictEqual(provider.refusal("gmail", "archive", refusals),
  "This account has no Archive mailbox")
assert.strictEqual(provider.refusal("gmail", "spam", refusals),
  "This server is not known to learn from its Junk mailbox")
assert.strictEqual(provider.refusal("gmail", "star", refusals), "")
assert.strictEqual(provider.refusal("gmail", "archive", null), "")
assert.strictEqual(provider.refusal("gmail", "archive"), "")
assert.strictEqual(provider.refusal("hey", "archive", { archive: "not this way" }), "",
  "a ceiling that never offered it has nothing to explain")

assert.strictEqual(provider.isConnectable("gmail"), true)
assert.strictEqual(provider.isConnectable("imap"), true)
assert.strictEqual(provider.isConnectable("hey"), true)
assert.strictEqual(provider.isConnectable("outlook"), true)

assert.strictEqual(provider.unavailableReason("gmail"), "")
assert.strictEqual(provider.unavailableReason("imap"), "")
assert.strictEqual(provider.unavailableReason("hey"), "")

const DRAWN_ICONS = ["inbox", "unread", "star", "sent", "archive", "trash", "spam", "reply", "pin", "label", "compose"]

// Invariant: The first mailbox is the provider inbox used when a prior provider's key has no match.
const ids = provider.ids()
for (const id of ids) {
  const boxes = provider.mailboxes(id)
  assert.ok(boxes.length > 0, id + " has mailboxes")
  assert.ok(boxes[0].key === "inbox" || boxes[0].key === "imbox",
    id + " leads with its inbox")
  for (const box of boxes) {
    // Invariant: Every mailbox icon must be supported by ActionIcon because the collapsed rail has no text label.
    assert.ok(DRAWN_ICONS.indexOf(box.icon) >= 0,
      id + "/" + box.key + " has no drawable icon: " + box.icon)
    assert.ok(box.label !== "", id + "/" + box.key + " needs a label for its tooltip")
  }
}

// Invariant: HEY can report spam but its CLI exposes no spam listing, so no spam mailbox is offered.
for (const id of ["gmail", "imap"]) {
  const spam = provider.mailboxes(id).filter(box => box.key === "spam")
  assert.strictEqual(spam.length, 1, id + " has one spam mailbox")
  assert.ok(spam[0].optional, id + "/spam yields the strip before the inbox does")
}
assert.strictEqual(provider.mailboxes("hey").filter(box => box.key === "spam").length, 0)

// Invariant: Returned mailbox arrays are copies and cannot mutate provider definitions.
const boxes = provider.mailboxes("gmail")
boxes.push({ key: "invented" })
assert.strictEqual(provider.mailboxes("gmail").length, boxes.length - 1,
  "the mailbox list is copied on the way out")

// Invariant: Account-reported absent mailboxes are removed before sidebar positions are numbered.
const imapKeys = provider.mailboxes("imap").map(box => box.key)
deepEqual(provider.mailboxes("imap", null).map(box => box.key), imapKeys,
  "no absent list is the whole list")
deepEqual(provider.mailboxes("imap", []).map(box => box.key), imapKeys)
deepEqual(provider.mailboxes("imap", "archive").map(box => box.key), imapKeys,
  "and so is anything that is not a list")

const withoutAll = provider.mailboxes("imap", ["all"])
assert.strictEqual(withoutAll.filter(box => box.key === "all").length, 0)
assert.strictEqual(withoutAll.length, imapKeys.length - 1)
assert.strictEqual(withoutAll.indexOf(withoutAll.filter(box => box.key === "spam")[0]),
  imapKeys.indexOf("spam") - 1, "Junk moves up when All mail is not there")

deepEqual(provider.mailboxes("imap", ["archive", "spam", "trash"]).map(box => box.key),
  imapKeys.filter(key => key !== "archive" && key !== "spam" && key !== "trash"))
deepEqual(provider.mailboxes("imap", ["nonesuch"]).map(box => box.key), imapKeys,
  "a key this provider never had drops nothing")

const dropped = provider.mailboxes("imap", ["archive"])
dropped.push({ key: "invented" })
assert.strictEqual(provider.mailboxes("imap", ["archive"]).length, dropped.length - 1)

assert.strictEqual(provider.hasMailbox("gmail", "all"), true)
assert.strictEqual(provider.hasMailbox("imap", "all"), true)
assert.strictEqual(provider.hasMailbox("imap", "archive"), true, "Archive remains available to API 5")
assert.strictEqual(provider.hasMailbox("gmail", "drafts"), true)
assert.strictEqual(provider.hasMailbox("hey", "drafts"), true)
assert.strictEqual(provider.hasMailbox("imap", "drafts"), true)
assert.strictEqual(provider.mailboxFor("gmail", "nonesuch").key, "inbox",
  "an unknown mailbox key falls back to the inbox rather than to undefined")
assert.strictEqual(provider.mailboxFor("imap", "starred").label, "Flagged",
  "IMAP calls it what the protocol calls it")

assert.strictEqual(provider.query("gmail", "inbox", "", ""), "in:inbox")
assert.strictEqual(provider.query("gmail", "starred", "", ""), "is:starred")
assert.strictEqual(provider.query("gmail", "trash", "", ""), "in:trash")
assert.strictEqual(provider.query("gmail", "drafts", "", ""), "in:drafts")

assert.strictEqual(provider.query("imap", "inbox", "", ""), "folder:INBOX")
assert.strictEqual(provider.query("imap", "unread", "", ""), "folder:INBOX UNSEEN")
assert.strictEqual(provider.query("imap", "sent", "", ""), "folder:\\Sent")
assert.strictEqual(provider.query("imap", "drafts", "", ""), "folder:\\Drafts")
assert.strictEqual(provider.query("outlook", "unread", "", ""), "folder:INBOX UNSEEN")

assert.strictEqual(provider.query("gmail", "trash", "from:jane", ""), "from:jane",
  "Gmail takes the user's search operators verbatim")
assert.strictEqual(provider.query("imap", "trash", "invoice", ""),
  "folder:INBOX TEXT \"invoice\"")
assert.strictEqual(provider.query("imap", "inbox", "say \"hi\"", ""),
  "folder:INBOX TEXT \"say \\\"hi\\\"\"", "a quote in a search term is escaped")

// Invariant: A configured default search applies to the inbox only; typed search takes precedence.
assert.strictEqual(provider.query("gmail", "inbox", "", "in:inbox -category:promotions"),
  "in:inbox -category:promotions")
assert.strictEqual(provider.query("gmail", "trash", "", "in:inbox -category:promotions"),
  "in:trash", "the default query does not leak into other mailboxes")
assert.strictEqual(provider.query("gmail", "inbox", "urgent", "in:inbox -category:promotions"),
  "urgent", "a typed search beats the default")
assert.strictEqual(provider.query("gmail", "inbox", "   ", ""), "in:inbox",
  "whitespace is not a search")
// Invariant: The plugin-wide Gmail default query must not become an IMAP command or a HEY query.
assert.strictEqual(provider.query("imap", "inbox", "", "in:inbox"), "folder:INBOX")
assert.strictEqual(provider.query("hey", "inbox", "", "in:inbox"), "box:imbox")
assert.strictEqual(provider.query("outlook", "inbox", "", "in:inbox"), "folder:INBOX")

assert.strictEqual(provider.query("hey", "inbox", "", ""), "box:imbox")
assert.strictEqual(provider.query("hey", "feed", "", ""), "box:feedbox")
assert.strictEqual(provider.query("hey", "trash", "", ""), "box:trash")
assert.strictEqual(provider.query("hey", "drafts", "", ""), "drafts:")
assert.strictEqual(provider.query("hey", "inbox", "dentist", ""), "search:dentist")

// Invariant: Cached search previews may only include rows the provider's corresponding live search can return.
assert.strictEqual(provider.cachedSummaryInSearch("gmail", "in:inbox",
  { labelIds: ["INBOX"] }), true)
assert.strictEqual(provider.cachedSummaryInSearch("gmail", "in:trash",
  { labelIds: ["TRASH"] }), false)
assert.strictEqual(provider.cachedSummaryInSearch("gmail", "in:inbox",
  { labelIds: ["SPAM"] }), false)
assert.strictEqual(provider.cachedSummaryInSearch("imap", "folder:INBOX UNSEEN", {}), true)
assert.strictEqual(provider.cachedSummaryInSearch("imap", "folder:\\Sent", {}), false)
assert.strictEqual(provider.cachedSummaryInSearch("imap", "folder:\"Project Mail\"", {}), false)
assert.strictEqual(provider.cachedSummaryInSearch("hey", "box:feedbox", {}), true)
assert.strictEqual(provider.cachedSummaryInSearch("hey", "box:laterbox", {}), true)
assert.strictEqual(provider.cachedSummaryInSearch("hey", "box:asidebox", {}), true)
assert.strictEqual(provider.cachedSummaryInSearch("hey", "label:4711", {}), true)

assert.strictEqual(provider.unreadQuery("gmail"),
  "in:inbox is:unread -category:promotions -category:social -category:forums")
assert.strictEqual(provider.unreadQuery("imap"), "folder:INBOX UNSEEN")
assert.strictEqual(provider.unreadQuery("outlook"), "folder:INBOX UNSEEN")
assert.strictEqual(provider.unreadQuery("hey"), "box:imbox unseen")

// Invariant: Unread scope excludes known categories instead of requiring a primary category that may be absent.
assert.ok(provider.unreadQuery("gmail").indexOf("category:primary") === -1,
  "the Unread scope is not a positive category filter; it fails closed")
assert.ok(provider.unreadQuery("gmail").indexOf("-category:updates") === -1,
  "Updates carries receipts, deliveries and GitHub's notifications; it stays in")

// Invariant: Selecting a label opens that folder; it does not perform a text search for its name.
assert.strictEqual(provider.labelQuery("gmail", "Receipts"), "label:Receipts")
assert.strictEqual(provider.labelQuery("imap", "Receipts"), "folder:\"Receipts\"")
assert.strictEqual(provider.labelQuery("imap", "Old Mail"), "folder:\"Old Mail\"",
  "a folder name with a space has to arrive quoted")
// Invariant: HEY label commands require the numeric label ID carried as rawName.
assert.strictEqual(provider.labelQuery("hey", "4711"), "label:4711")
assert.strictEqual(provider.labelQuery("hey", ""), "")
assert.strictEqual(provider.labelQuery("imap", ""), "")
assert.strictEqual(provider.labelQuery("imap", "   "), "")

assert.ok(provider.labelQuery("imap", "Old Mail").indexOf("TEXT") < 0)

// Invariant: Provider web-home navigation is independent of message and mailbox URL support.
assert.strictEqual(provider.webHomeUrl("gmail"), "https://mail.google.com/mail/u/0/")
assert.strictEqual(provider.webHomeUrl("hey"), "https://app.hey.com")
assert.strictEqual(provider.webHomeUrl("imap"), "", "an IMAP server is not a website")
assert.strictEqual(provider.webHomeUrl("outlook"), "https://outlook.live.com/mail/")

// Invariant: Provider artwork distinguishes square marks from lockups; protocol-only IMAP has no brand artwork.
assert.strictEqual(provider.mark("gmail"), "gmail.png")
assert.strictEqual(provider.logo("gmail"), "gmail.png", "one square mark serves both")
assert.strictEqual(provider.mark("hey"), "hey-mark.png")
assert.strictEqual(provider.logo("hey"), "hey.png")
assert.strictEqual(provider.mark("imap"), "")
assert.strictEqual(provider.logo("imap"), "")
assert.strictEqual(provider.mark("outlook"), "outlook.svg")
assert.strictEqual(provider.logo("outlook"), "outlook.svg", "one square mark serves both")

assert.strictEqual(provider.authKind("gmail"), "oauth")
assert.strictEqual(provider.authKind("outlook"), "oauth")
assert.strictEqual(provider.authKind("imap"), "password")
// Invariant: The official HEY CLI owns its browser login, token and credential storage.
assert.strictEqual(provider.authKind("hey"), "cli")
assert.strictEqual(provider.usesCli("hey"), true)
assert.strictEqual(provider.usesCli("gmail"), false)
assert.strictEqual(provider.usesOAuth("hey"), false)
assert.strictEqual(provider.usesPassword("hey"), false)
assert.strictEqual(provider.usesOAuth("gmail"), true)
assert.strictEqual(provider.usesOAuth("outlook"), true)
assert.strictEqual(provider.usesOAuth("imap"), false)
assert.strictEqual(provider.usesPassword("imap"), true)
assert.strictEqual(provider.usesPassword("gmail"), false)

assert.strictEqual(provider.badge("imap"), "IMAP")
assert.strictEqual(provider.badge("jmap"), "JMAP", "the switcher badge is the protocol, no host")
assert.ok(provider.summary("imap").length > 0)

assert.strictEqual(provider.detail("gmail", { email: "ada@gmail.com" }), "")
assert.strictEqual(provider.detail("hey", {}), "")
assert.strictEqual(provider.detail("imap", { imap: { imapHost: "imap.example.org" } }), "")
assert.strictEqual(
  provider.detail("jmap", { jmap: { sessionUrl: "https://mail.example.org/jmap/session" } }),
  "JMAP · mail.example.org")
assert.strictEqual(provider.detail("jmap", {}), "JMAP",
  "a mailbox that has not signed in yet still says what kind it is")
assert.strictEqual(provider.detail("jmap", null), "JMAP")
assert.strictEqual(provider.DEFAULT_ID, "gmail",
  "an account written before providers existed is a Gmail account")

console.log("Provider.js ok")

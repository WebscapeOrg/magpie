const assert = require("assert")
const { load, deepEqual } = require("./load")

const unified = load("account/Unified.js")

// Invariant: Unified IDs include the source account and message ID, separated by the explicit U+001F delimiter.
const ID_SEPARATOR = "\u001f"

assert.strictEqual(unified.unifiedId("me@example.org", "42"), "me@example.org" + ID_SEPARATOR + "42")
assert.strictEqual(unified.unifiedId("", "42"), "", "an id with no account addresses nothing")
assert.strictEqual(unified.unifiedId("me@example.org", ""), "")

deepEqual(unified.splitUnifiedId("me@example.org" + ID_SEPARATOR + "42"),
  { accountId: "me@example.org", id: "42" })

// Invariant: Provider message IDs cannot contain the unified-ID control separator.
assert.strictEqual(unified.unifiedId("a@b.com", "42:Sent Items").indexOf(ID_SEPARATOR), 7,
  "the only separator in a composed id is the one that was put there")
assert.strictEqual(
  unified.unifiedId("a@b.com", "42:Sent Items").split(ID_SEPARATOR).length, 2)

deepEqual(unified.splitUnifiedId("42"), { accountId: "", id: "" })
deepEqual(unified.splitUnifiedId(""), { accountId: "", id: "" })
deepEqual(unified.splitUnifiedId(unified.unifiedId("", "42")),
  { accountId: "", id: "" }, "an empty account is not an account")

// Invariant: A bare IMAP ID containing a folder space must not be mistaken for a composed account ID.
deepEqual(unified.splitUnifiedId("42:Sent Items"), { accountId: "", id: "" },
  "a bare IMAP id is not a composed one")
assert.strictEqual(unified.accountOf("42:Sent Items"), "")
assert.strictEqual(unified.sourceIdOf("42:Sent Items"), "")
deepEqual(unified.splitUnifiedId("1a0682969660774e"), { accountId: "", id: "" },
  "nor is a bare Gmail id")

deepEqual(unified.splitUnifiedId(unified.unifiedId("me@fastmail.com", "42:Sent Items")),
  { accountId: "me@fastmail.com", id: "42:Sent Items" })

assert.strictEqual(unified.accountOf("me@example.org" + ID_SEPARATOR + "42"), "me@example.org")
assert.strictEqual(unified.sourceIdOf("me@example.org" + ID_SEPARATOR + "42"), "42")
assert.strictEqual(unified.accountOf("42"), "")

// Invariant: A multi-account selection groups original provider IDs by their owning account.
deepEqual(unified.groupByAccount([
  unified.unifiedId("a@example.org", "1"),
  unified.unifiedId("b@example.net", "7:INBOX"),
  "42",
  unified.unifiedId("a@example.org", "2"),
  unified.unifiedId("b@example.net", "8:Sent Items")
]), [
  { accountId: "a@example.org", ids: ["1", "2"] },
  { accountId: "b@example.net", ids: ["7:INBOX", "8:Sent Items"] }
])
deepEqual(unified.groupByAccount([]), [])
deepEqual(unified.groupByAccount(null), [])

const sources = [
  { id: "a@example.org", label: "Personal", messages: [
    { id: "1", date: 3000, subject: "newest" },
    { id: "2", date: 1000, subject: "oldest" }
  ]},
  { id: "b@example.net", label: "Work", messages: [
    { id: "1", date: 2000, subject: "middle" }
  ]}
]
const merged = unified.mergeMessages(sources)

assert.strictEqual(merged.length, 3)
deepEqual(merged.map(function(row) { return row.subject }),
  ["newest", "middle", "oldest"], "newest first, across mailboxes")

deepEqual(merged.map(function(row) { return row.id }),
  [unified.unifiedId("a@example.org", "1"), unified.unifiedId("b@example.net", "1"), unified.unifiedId("a@example.org", "2")])
deepEqual(merged.map(function(row) { return row.sourceId }), ["1", "1", "2"])

assert.strictEqual(merged[0].accountId, "a@example.org")
assert.strictEqual(merged[0].sourceLabel, "Personal")
assert.strictEqual(merged[1].sourceLabel, "Work")
assert.strictEqual(merged[0].subject, "newest", "the provider's own fields survive")

// Invariant: Merged rows are copied so later source mutations cannot retarget an already displayed row.
sources[0].messages[0].subject = "changed underneath"
assert.strictEqual(merged[0].subject, "newest")

deepEqual(unified.mergeMessages([{ label: "Nameless", messages: [{ id: "1" }] }]), [])

assert.strictEqual(unified.mergeMessages(
  [{ id: "a@example.org", messages: [{ subject: "no id" }] }]).length, 0)

assert.strictEqual(unified.mergeMessages([
  { id: "a@example.org", messages: [{ id: "1", date: 1 }, { id: "1", date: 1 }] }
]).length, 1)

deepEqual(unified.mergeMessages(null), [])

deepEqual(unified.mergeMessages([]), [])

// Performance: Read each row timestamp once before sorting; comparator calls must not repeat cross-engine date conversion.
let timeReads = 0
function countingTime(timestamp) {
  return { getTime: function() { timeReads += 1; return timestamp } }
}
const unsorted = []
for (let rowIndex = 0; rowIndex < 8; rowIndex++) {
  unsorted.push({ id: String(rowIndex), subject: "s" + rowIndex, date: countingTime(1000 + (rowIndex % 3) * 1000) })
}
const timed = unified.mergeMessages([{ id: "a@x", label: "A", messages: unsorted }])
assert.strictEqual(timed.length, 8)
assert.strictEqual(timeReads, 8,
  "one read per row, not one per comparison: " + timeReads + " reads for 8 rows")

deepEqual(timed.map(function(row) { return row.sourceId }), ["2", "5", "1", "4", "7", "0", "3", "6"])

assert.strictEqual(timed[0].at, undefined)
assert.strictEqual(timed[0].row, undefined)

// Performance: An unfinished source adds one timestamp read for its oldest-row watermark.
timeReads = 0
const paging = []
for (let rowIndex = 0; rowIndex < 4; rowIndex++) {
  paging.push({ id: String(rowIndex), subject: "s" + rowIndex, date: countingTime(4000 - rowIndex * 100) })
}
unified.mergeMessages([{ id: "a@x", label: "A", messages: paging, hasMore: true }])
assert.strictEqual(timeReads, 5,
  "one per row, plus the watermark's read of the oldest: " + timeReads)

// Invariant: Date objects, ISO strings and internalDate milliseconds share one chronological order.
const mixedTimes = unified.mergeMessages([
  { id: "a@example.org", messages: [{ id: "date-object", date: new Date(5000) }] },
  { id: "b@example.net", messages: [{ id: "internal", internalDate: 9000 }] },
  { id: "c@example.com", messages: [{ id: "string", date: "1970-01-01T00:00:07Z" }] }
])
deepEqual(mixedTimes.map(function(row) { return row.sourceId }),
  ["internal", "string", "date-object"])

// Invariant: Account and message ID break equal-date ties deterministically.
const tied = unified.mergeMessages([
  { id: "b@example.net", messages: [{ id: "x", date: 1000 }] },
  { id: "a@example.org", messages: [{ id: "x", date: 1000 }] }
])
deepEqual(tied.map(function(row) { return row.id }), [unified.unifiedId("a@example.org", "x"), unified.unifiedId("b@example.net", "x")])
deepEqual(unified.mergeMessages([
  { id: "a@example.org", messages: [{ id: "x", date: 1000 }] },
  { id: "b@example.net", messages: [{ id: "x", date: 1000 }] }
]).map(function(row) { return row.id }), [unified.unifiedId("a@example.org", "x"), unified.unifiedId("b@example.net", "x")],
  "the same rows in the other order merge to the same order")

assert.strictEqual(unified.cursorOffset(merged, unified.unifiedId("a@example.org", "1"), 1), unified.unifiedId("b@example.net", "1"))
assert.strictEqual(unified.cursorOffset(merged, unified.unifiedId("b@example.net", "1"), 1), unified.unifiedId("a@example.org", "2"))
assert.strictEqual(unified.cursorOffset(merged, unified.unifiedId("b@example.net", "1"), -1), unified.unifiedId("a@example.org", "1"))

assert.strictEqual(unified.cursorOffset(merged, unified.unifiedId("a@example.org", "1"), -1), "")
assert.strictEqual(unified.cursorOffset(merged, unified.unifiedId("a@example.org", "2"), 1), "")

assert.strictEqual(unified.cursorOffset(merged, "", 1), unified.unifiedId("a@example.org", "1"))
assert.strictEqual(unified.cursorOffset(merged, "", -1), unified.unifiedId("a@example.org", "2"))
assert.strictEqual(unified.cursorOffset([], "anything", 1), "")

assert.strictEqual(unified.cursorOffset(merged, "gone@example.org 9", 1), unified.unifiedId("a@example.org", "1"))

deepEqual(unified.rowOf(merged, unified.unifiedId("b@example.net", "1")).subject, "middle")
assert.strictEqual(unified.rowOf(merged, "nothing"), null)
assert.strictEqual(unified.rowOf(merged, ""), null)

// Invariant: Unified capabilities intersect each account's actual capabilities, including server-specific refusals.
const gmailish = { archive: true, spam: true, star: true, web: true,
  mailboxes: [{ key: "inbox" }, { key: "spam" }, { key: "sent" }] }
const noArchive = { archive: false, spam: true, star: true, web: false,
  mailboxes: [{ key: "inbox" }, { key: "spam" }] }

assert.strictEqual(unified.everyMailboxCan([gmailish], "archive"), true)
assert.strictEqual(unified.everyMailboxCan([gmailish, noArchive], "archive"), false,
  "one mailbox that cannot archive is a merged list that does not offer it")
assert.strictEqual(unified.everyMailboxCan([gmailish, noArchive], "spam"), true)
assert.strictEqual(unified.everyMailboxCan([gmailish, noArchive], "web"), false)

assert.strictEqual(unified.everyMailboxCan([gmailish], "labels"), false)
assert.strictEqual(unified.everyMailboxCan([], "archive"), false,
  "no mailboxes cannot do anything")
assert.strictEqual(unified.everyMailboxCan([gmailish, null], "archive"), false,
  "a mailbox that has not answered yet is not a yes")

deepEqual(unified.sharedMailboxRows([gmailish]).map(function(row) { return row.key }),
  ["inbox", "spam", "sent"])
deepEqual(unified.sharedMailboxRows([gmailish, noArchive]).map(function(row) { return row.key }),
  ["inbox", "spam"], "a row one server does not have is a row that cannot be opened")
deepEqual(unified.sharedMailboxRows([]), [])
deepEqual(unified.sharedMailboxRows([{ mailboxes: [] }, gmailish]), [])

deepEqual(unified.sharedMailboxRows([{ mailboxes: [{ key: "" }, { key: "inbox" }] },
  gmailish]).map(function(row) { return row.key }), ["inbox"])

assert.strictEqual(unified.totalUnread([{ unread: 3 }, { unread: 0 }, { unread: 7 }]), 10)
assert.strictEqual(unified.totalUnread([{ unread: -1 }, { unread: "4" }]), 4)
assert.strictEqual(unified.totalUnread(null), 0)

assert.strictEqual(unified.anyLoading([{ loading: false }, { loading: true }]), true)
assert.strictEqual(unified.anyLoading([{ loading: false }]), false)
assert.strictEqual(unified.anyLoading([]), false)

assert.strictEqual(unified.anyServerSearchLoading([
  { serverSearchLoading: false }, { serverSearchLoading: true }
]), true, "a search in any mailbox keeps the unified search busy")
assert.strictEqual(unified.anyServerSearchLoading([{ serverSearchLoading: false }]), false)
assert.strictEqual(unified.anyServerSearchLoading([]), false)

assert.strictEqual(unified.rowIsConversation({ thread: { count: 2 } }), true,
  "a collapsed row keeps its own conversation count")
assert.strictEqual(unified.rowIsConversation({ thread: { count: 0 } }), false,
  "a message row does not inherit a conversation capability from another mailbox")

assert.strictEqual(unified.allLoaded([{ loaded: true }, { loaded: true }]), true)
assert.strictEqual(unified.allLoaded([{ loaded: true }, { loaded: false }]), false)
assert.strictEqual(unified.allLoaded([]), false, "no mailboxes have not loaded")

// Invariant: A stopped mailbox with an error is settled; retrying one remains loading even if it retains an old error.
assert.strictEqual(
  unified.allLoaded([{ loaded: true }, { loaded: false, error: "Not signed in" }]),
  true,
  "a mailbox that cannot load is not a mailbox still loading")

assert.strictEqual(
  unified.allLoaded([{ loaded: true }, { loading: true, error: "Not signed in" }]),
  false)

assert.strictEqual(unified.allLoaded([{ loaded: false, error: "   " }]), false)

assert.strictEqual(unified.anyHasMore([{ hasMore: false }, { hasMore: true }]), true)
assert.strictEqual(unified.anyHasMore([{ hasMore: false }]), false)

// Invariant: Unified errors include the owning mailbox label when available.
assert.strictEqual(unified.firstError([
  { label: "Personal", error: "" },
  { label: "Fastmail", error: "the server refused that command" }
]), "Fastmail: the server refused that command")
assert.strictEqual(unified.firstError([{ error: "no label to give" }]), "no label to give")
assert.strictEqual(unified.firstError([{ error: "" }]), "")
assert.strictEqual(unified.firstError([]), "")

// Invariant: Merged pagination stops at the newest unfinished source's last-row time so no deeper source fills another's unseen gap.
const deepAndShallow = [
  { id: "a@example.org", hasMore: true, messages: [
    { id: "1", date: 900 }, { id: "2", date: 800 },
    { id: "3", date: 300 }, { id: "4", date: 200 } ] },
  { id: "b@example.net", hasMore: true, messages: [
    { id: "1", date: 850 }, { id: "2", date: 700 } ] }
]

assert.strictEqual(unified.pageWatermark(deepAndShallow), 700)
deepEqual(unified.mergeMessages(deepAndShallow).map(function(row) { return row.date }),
  [900, 850, 800, 700],
  "everything at or above the watermark, and nothing that would have a hole under it")

// Invariant: A finished source imposes no pagination watermark.
const oneFinished = [
  { id: "a@example.org", hasMore: false, messages: [
    { id: "1", date: 900 }, { id: "2", date: 200 } ] },
  { id: "b@example.net", hasMore: false, messages: [{ id: "1", date: 500 }] }
]
assert.strictEqual(unified.pageWatermark(oneFinished), 0)
deepEqual(unified.mergeMessages(oneFinished).map(function(row) { return row.date }),
  [900, 500, 200], "nothing is withheld once every source is complete")

assert.strictEqual(unified.pageWatermark([
  { id: "a@example.org", hasMore: false, messages: [{ id: "1", date: 100 }] },
  { id: "b@example.net", hasMore: true, messages: [{ id: "1", date: 600 }] }
]), 600)

// Invariant: An empty source supplies no watermark until it reports a row.
assert.strictEqual(unified.pageWatermark([
  { id: "a@example.org", hasMore: true, messages: [] },
  { id: "b@example.net", hasMore: true, messages: [{ id: "1", date: 600 }] }
]), 600)

console.log("Unified.js ok")

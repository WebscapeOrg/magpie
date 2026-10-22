const assert = require("assert")
const { load, deepEqual } = require("./load")

const conversation = load("tests/oracles/Conversation.js")


const mailboxes = [
  { key: "inbox", label: "Inbox" },
  { key: "unread", label: "Unread" },
  { key: "starred", label: "Flagged" },
  { key: "sent", label: "Sent" },
  { key: "drafts", label: "Drafts" },
  { key: "spam", label: "Junk" },
  { key: "trash", label: "Trash" }
]

const block = {
  id: "d",
  count: 3,
  unread: true,
  flagged: false,
  memberIds: ["maaaaad", "maaaaae", "maaaaaf"]
}

function summary(id, over) {
  const base = {
    id: id,
    from: { display: "Ada Lovelace", email: "ada@example.org" },
    subject: "The engine",
    time: "3d",
    fullTime: "2 September 2026 at 09:14",
    unread: false,
    starred: false,
    labelIds: ["INBOX"]
  }
  return Object.assign(base, over || {})
}

const known = {
  maaaaad: summary("maaaaad", { labelIds: ["INBOX", "DRAFT"], time: "5d" }),
  maaaaae: summary("maaaaae", { time: "4d" }),
  maaaaaf: summary("maaaaaf", { time: "3d", unread: true, labelIds: ["INBOX", "UNREAD"] })
}


deepEqual(conversation.blockOf(block), block, "a whole block reads back whole")
assert.strictEqual(conversation.blockOf(null), null, "no block is null, not an empty one")
assert.strictEqual(conversation.blockOf({ memberIds: ["a", "", null, "b"] }).count, 2,
  "count is the members that are actually there")
deepEqual(conversation.blockOf({ id: " d ", memberIds: [] }),
  { id: "d", count: 0, unread: false, flagged: false, memberIds: [] },
  "an unknown conversation reads as a count of zero")


assert.ok(conversation.drawsRail(true, block), "three members on a collapsing provider")
assert.ok(!conversation.drawsRail(false, block),
  "a provider that never collapsed its listing has no members to draw")
assert.ok(!conversation.drawsRail(true, { id: "e", memberIds: ["x"] }),
  "one message has nowhere to go")
assert.ok(!conversation.drawsRail(true, { id: "t", count: 0, memberIds: [] }),
  "an unknown count draws nothing")
assert.ok(!conversation.drawsRail(true, null), "and neither does no block at all")


assert.strictEqual(conversation.threadAfterSelect(block, "maaaaae", { thread: null }), block,
  "moving to a member keeps the block the row was opened with")
assert.strictEqual(
  conversation.threadAfterSelect(block, "maaaaae",
    { thread: { id: "d", count: 0, memberIds: [] } }),
  block,
  "including when the member's own detail read carries an empty block")
deepEqual(
  conversation.threadAfterSelect(null, "yaaaaag", { thread: block }),
  block, "opening a conversation row takes its block")
assert.strictEqual(
  conversation.threadAfterSelect(block, "yaaaaag", { thread: { id: "g", memberIds: ["yaaaaag"] } }),
  null, "opening a message of one leaves the conversation behind")
assert.strictEqual(conversation.threadAfterSelect(block, "yaaaaag", null), null,
  "and so does opening one whose summary is not known yet")


deepEqual(conversation.missingMemberIds(block, {}),
  ["maaaaad", "maaaaae", "maaaaaf"], "nothing known is every id, in rail order")
deepEqual(conversation.missingMemberIds(block, { maaaaae: known.maaaaae }),
  ["maaaaad", "maaaaaf"], "the row the list already drew is not asked for again")
deepEqual(conversation.missingMemberIds(block, known), [], "and nothing is owed once they land")
deepEqual(conversation.missingMemberIds(null, known), [], "no conversation asks for nothing")

deepEqual(conversation.mergedSummaries({ a: 1 }, { b: 2 }, 10), { a: 1, b: 2 },
  "a read is merged into what is held rather than replacing it")
deepEqual(conversation.mergedSummaries({ a: 1 }, { a: 2 }, 10), { a: 2 },
  "and the newer answer wins")
deepEqual(conversation.mergedSummaries({ a: 1, b: 2 }, { c: 3 }, 2), { c: 3 },
  "past the ceiling the store is dropped whole rather than evicted from")
deepEqual(conversation.mergedSummaries({ a: 1, b: 2, d: 4 }, { c: 3 }, 2, ["a", "d", "zz"]),
  { a: 1, d: 4, c: 3 },
  "except the conversation on screen, whose members survive the reset")
deepEqual(conversation.mergedSummaries({ a: 1, b: 2 }, { c: 3 }, 2, null), { c: 3 })


assert.strictEqual(conversation.mailboxKeyOf(known.maaaaae), "inbox")
assert.strictEqual(conversation.mailboxKeyOf(known.maaaaad), "drafts",
  "a draft answering a thread sits in the Inbox too, and Drafts is where to find it")
assert.strictEqual(conversation.mailboxKeyOf({ labelIds: ["SENT"] }), "sent")
assert.strictEqual(conversation.mailboxKeyOf({ labelIds: ["INBOX", "TRASH"] }), "trash")
assert.strictEqual(conversation.mailboxKeyOf({ labelIds: [] }), "",
  "a message whose labels name no rail row is not guessed at")

assert.strictEqual(conversation.viewedMailboxKey("inbox", false), "inbox")
assert.strictEqual(conversation.viewedMailboxKey("unread", false), "inbox",
  "Unread is a reading of the Inbox, not a mailbox of its own")
assert.strictEqual(conversation.viewedMailboxKey("starred", false), "inbox")
assert.strictEqual(conversation.viewedMailboxKey("inbox", true), "",
  "a search is a view of the account, so every member carries a name")

assert.strictEqual(conversation.mailboxNameFor(known.maaaaae, "inbox", mailboxes), "",
  "a member inside the mailbox on screen says nothing")
assert.strictEqual(conversation.mailboxNameFor(known.maaaaae, "sent", mailboxes), "Inbox",
  "and one outside it carries the account's own name for where it is")
assert.strictEqual(conversation.mailboxNameFor(known.maaaaad, "inbox", mailboxes), "Drafts")
assert.strictEqual(conversation.mailboxNameFor(known.maaaaae, "", mailboxes), "Inbox",
  "in a search every member carries one")
assert.strictEqual(conversation.mailboxNameFor({ labelIds: ["SPAM"] }, "inbox", []), "",
  "an account with no Junk row has no name to draw")


{
  const drawn = conversation.stops(block, known, "maaaaaf", "inbox", mailboxes)
  assert.strictEqual(drawn.length, 3, "one stop per member")
  deepEqual(drawn.map(stop => stop.id), ["maaaaaf", "maaaaae", "maaaaad"],
    "newest first, the other way up from Thread/get's own order")
  deepEqual(drawn.map(stop => stop.open), [true, false, false],
    "the open message keeps its place in the timeline")
  deepEqual(drawn.map(stop => stop.unread), [true, false, false])
  deepEqual(drawn.map(stop => stop.mailbox), ["", "", "Drafts"],
    "only the member outside the Inbox names where it is")
  assert.strictEqual(drawn[1].sender, "Ada Lovelace")
  assert.strictEqual(drawn[1].time, "4d")
  assert.ok(drawn.every(stop => stop.known), "every summary has arrived")
}

{
  const drawn = conversation.stops(block, known, "maaaaaf", "sent", mailboxes)
  deepEqual(drawn.map(stop => stop.mailbox), ["Inbox", "Inbox", "Drafts"])
}

{
  const drawn = conversation.stops(block, {}, "maaaaaf", "inbox", mailboxes)
  assert.strictEqual(drawn.length, 3)
  assert.ok(drawn.every(stop => !stop.known), "every stop is a skeleton")
  deepEqual(drawn.map(stop => stop.sender), ["", "", ""])
  deepEqual(drawn.map(stop => stop.unread), [false, false, false],
    "an unknown member is never drawn unread")
  deepEqual(drawn.map(stop => stop.open), [true, false, false],
    "and the open one is still marked")
}

{
  const flagged = Object.assign({}, known, {
    maaaaae: summary("maaaaae", { starred: true, labelIds: ["INBOX", "STARRED"] })
  })
  deepEqual(conversation.stops(block, flagged, "maaaaaf", "inbox", mailboxes)
    .map(stop => stop.flagged), [false, true, false])
}

deepEqual(conversation.stops(null, known, "", "inbox", mailboxes), [])

// Invariant: Rail stops use member-local flags; representative row aggregates must not double-count unread members.
{
  const representative = summary("maaaaad", {
    unread: true, starred: true, labelIds: ["INBOX"],
    thread: { id: "d", count: 3, unread: true, flagged: true, memberIds: block.memberIds }
  })
  const withRow = Object.assign({}, known, { maaaaad: representative })
  const drawn = conversation.stops(block, withRow, "maaaaaf", "inbox", mailboxes)
  assert.strictEqual(drawn[2].unread, false, "the representative's own labels say read")
  assert.strictEqual(drawn[2].flagged, false, "and unstarred")
  assert.strictEqual(drawn[0].unread, true, "the reply is the unread one")
  assert.strictEqual(conversation.caption(block, withRow), "3 messages · 1 unread",
    "the row's OR does not count as a second unread")
  assert.strictEqual(conversation.memberHasLabel({ unread: true }, "UNREAD"), true)
  assert.strictEqual(conversation.memberHasLabel({ starred: true }, "STARRED"), true)
  assert.strictEqual(conversation.memberHasLabel({ labelIds: [] , unread: true }, "UNREAD"), false)
  assert.strictEqual(conversation.memberHasLabel({ unread: true }, "INBOX"), false,
    "a label with no flag of its own has no fallback")
  assert.strictEqual(conversation.memberHasLabel(null, "UNREAD"), false)
}

assert.strictEqual(
  conversation.stops(block, { maaaaad: summary("maaaaad", { from: { display: "", email: "ada@example.org" } }) },
    "maaaaad", "inbox", mailboxes)[2].sender,
  "ada@example.org")


assert.strictEqual(conversation.caption(block, known), "3 messages · 1 unread")
assert.strictEqual(conversation.caption(block, {}), "3 messages",
  "the length is known before any summary is; the unread count is not")
assert.strictEqual(
  conversation.caption(block, Object.assign({}, known, {
    maaaaaf: summary("maaaaaf", { unread: false })
  })), "3 messages", "and it goes when the last unread member is read")
assert.strictEqual(conversation.caption({ id: "e", memberIds: ["x"] }, {}), "",
  "a conversation of one is captioned with nothing, because it draws nothing")
assert.strictEqual(conversation.caption(null, known), "")


assert.strictEqual(conversation.memberStep(block, "maaaaaf", 1), "maaaaae",
  "n goes down the rail, to the older message")
assert.strictEqual(conversation.memberStep(block, "maaaaae", -1), "maaaaaf",
  "p goes up it, to the newer")
assert.strictEqual(conversation.memberStep(block, "maaaaad", 1), "",
  "n stops at the oldest member rather than wrapping to the newest")
assert.strictEqual(conversation.memberStep(block, "maaaaaf", -1), "",
  "and p stops at the newest")
assert.strictEqual(conversation.memberStep(block, "yaaaaag", 1), "maaaaaf",
  "a rail whose open message left it starts from the end the move came from")
assert.strictEqual(conversation.memberStep(block, "yaaaaag", -1), "maaaaad")
assert.strictEqual(conversation.memberStep(null, "maaaaad", 1), "")
assert.strictEqual(conversation.memberStep({ id: "t", memberIds: [] }, "", 1), "")

assert.strictEqual(conversation.neighbourStop(block, "maaaaae"), "maaaaaf",
  "the newer stop above is preferred")
assert.strictEqual(conversation.neighbourStop(block, "maaaaaf"), "maaaaae",
  "the newest member has only an older neighbour")
assert.strictEqual(conversation.neighbourStop(block, "maaaaad"), "maaaaae")
assert.strictEqual(conversation.neighbourStop(block, "yaaaaag"), "",
  "a message that is not a stop has no neighbour")
assert.strictEqual(conversation.neighbourStop({ id: "t", memberIds: ["only"] }, "only"), "",
  "a conversation of one has nowhere to go")
assert.strictEqual(conversation.neighbourStop(null, "maaaaae"), "")

assert.ok(conversation.holdsMember(block, "maaaaae"))
assert.ok(!conversation.holdsMember(block, "yaaaaag"))
assert.ok(!conversation.holdsMember(null, "maaaaae"))

console.log("conversation tests passed")

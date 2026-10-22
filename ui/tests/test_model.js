const assert = require("assert")
const { load, deepEqual } = require("./load")

const model = load("account/Model.js")

// Invariant: A conversation representative and its member stop share an ID but retain different action scopes.
const rowRead = { id: "m3", action: "markRead", cacheKey: "inbox",
  sourceLabelId: "", quiet: false, memberOnly: false }
const memberRead = { ...rowRead, memberOnly: true }
const memberAgain = model.enqueueAction([memberRead], memberRead)
assert.strictEqual(memberAgain.length, 1)
assert.strictEqual(memberAgain[0].memberOnly, true)
deepEqual(model.enqueueAction([memberRead], rowRead), [memberRead, rowRead])

// Invariant: Coalescing keeps the first dispatch; an explicit action behind a quiet action remains separate.
const firstSend = () => {}
const secondSend = () => {}
const coalesced = model.enqueueAction([{ ...rowRead, dispatch: firstSend }],
  { ...rowRead, dispatch: secondSend })
assert.strictEqual(coalesced.length, 1)
assert.strictEqual(coalesced[0].dispatch, firstSend)
const inTurn = model.enqueueAction([{ ...rowRead, quiet: true, dispatch: firstSend }],
  { ...rowRead, dispatch: secondSend })
assert.strictEqual(inTurn.length, 2)
assert.strictEqual(inTurn[1].dispatch, secondSend)

const listBefore = [{ id: "a" }, { id: "b" }, { id: "c" }, { id: "d" }]
deepEqual(model.restoreRow([{ id: "a" }, { id: "d" }], listBefore[2], listBefore, 2),
  [{ id: "a" }, listBefore[2], { id: "d" }], "the first surviving follower anchors the row")
deepEqual(model.restoreRow([{ id: "x" }, { id: "a" }, { id: "d" }], listBefore[1], listBefore, 1),
  [{ id: "x" }, { id: "a" }, listBefore[1], { id: "d" }],
  "a row that arrived above since does not push it past its follower")
deepEqual(model.restoreRow([{ id: "a" }], listBefore[2], listBefore, 2),
  [{ id: "a" }, listBefore[2]], "with no follower left the index is clamped")
deepEqual(model.restoreRow([], listBefore[0], listBefore, 0), [listBefore[0]])
// Invariant: Rollback anchors against the settled order, including rows removed by earlier pending edits.
deepEqual(model.restoreRow([listBefore[0]], listBefore[1], listBefore, 0).map(r => r.id),
  ["a", "b"], "with no follower left, the last surviving predecessor anchors the row")
deepEqual(model.restoreRow([listBefore[0]], listBefore[1], [listBefore[1]], 0).map(r => r.id),
  ["b", "a"], "which the failed edit's own snapshot could not have said")
deepEqual(model.restoreRow([listBefore[3]], { id: "n" }, listBefore, 1).map(r => r.id),
  ["d", "n"], "a row the settled list never held falls back to its index, clamped")

const sendA = () => {}
const sendB = () => {}
assert.strictEqual(model.holdsDispatch([{ dispatch: sendA }], sendA), true)
assert.strictEqual(model.holdsDispatch([{ dispatch: sendA }], sendB), false,
  "a coalesced repeat's send is not in the queue")
assert.strictEqual(model.holdsDispatch(null, sendA), false)

const previews = [{ id: "a", unread: true }, { id: "c", unread: true }]
deepEqual(model.previewAfterRestore(previews, { id: "b", unread: true }, true, listBefore, 1).map(r => r.id),
  ["a", "b", "c"], "an unread row goes back into the preview where the order says")
deepEqual(model.previewAfterRestore(previews, { id: "a", unread: true, starred: true }, true, listBefore, 0)[0].starred,
  true, "a row still listed is replaced")
deepEqual(model.previewAfterRestore(previews, { id: "a" }, false, listBefore, 0).map(r => r.id),
  ["c"], "a row that should not be there comes out")
deepEqual(model.previewAfterRestore(previews, { id: "b" }, false, listBefore, 1), previews)

// Invariant: Rollback restores only rows removed by the refused edit and not removed again by a later pending edit.
{
  const order = [{ id: "a" }, { id: "b" }, { id: "c" }]
  const row = { id: "b", unread: true }
  deepEqual(model.listAfterRestore([{ id: "a" }, { id: "c" }], row, true, false, order, 1).map(r => r.id),
    ["a", "b", "c"], "a removed row goes back where the settled order says")
  deepEqual(model.listAfterRestore([{ id: "a" }, { id: "b", unread: false }], row, false, false, order, 1)[1],
    row, "a row still listed is replaced by its replay")
  deepEqual(model.listAfterRestore([{ id: "a" }], row, true, true, order, 1).map(r => r.id),
    ["a"], "a row an edit behind this one took off stays off")
  deepEqual(model.listAfterRestore([{ id: "a" }], row, false, false, order, 1).map(r => r.id),
    ["a"], "a row this edit never removed is not put in")
  deepEqual(model.listAfterRestore(null, row, true, false, order, 0).map(r => r.id), ["b"])
  deepEqual(model.listAfterRestore([{ id: "a" }], null, true, false, order, 0).map(r => r.id), ["a"])
}

// Invariant: Refusing an earlier edit replays later edits from the earlier baseline without mutating held entries.
{
  const star = s => ({ ...s, starred: true })
  const read = s => ({ ...s, unread: false })
  const held = [
    { token: 1, before: { id: "m", unread: true, starred: false }, apply: star },
    { token: 2, before: { id: "m", unread: true, starred: true }, apply: read, removed: false }
  ]
  const rebased = model.rebaseIntents(held, 1)
  deepEqual(rebased.summary, { id: "m", unread: false, starred: false },
    "the star comes off and the read stays")
  assert.strictEqual(rebased.entries.length, 1)
  assert.strictEqual(rebased.entries[0].token, 2)
  deepEqual(rebased.entries[0].before, { id: "m", unread: true, starred: false },
    "the edit behind now starts from where the failed one did")
  deepEqual(held[1].before, { id: "m", unread: true, starred: true }, "the held entry is not written to")
  deepEqual(model.rebaseIntents(held, 2).summary, { id: "m", unread: true, starred: true },
    "the last edit failing leaves the first")
  assert.strictEqual(model.rebaseIntents(held, 9), null, "an answer nobody waited for")
  deepEqual(model.withoutIntent(held, 1).map(e => e.token), [2])
  deepEqual(model.withoutIntent(null, 1), [])
  assert.strictEqual(model.anyIntentRemoved(held), false)
  assert.strictEqual(model.anyIntentRemoved(held.concat([{ token: 3, removed: true }])), true)

  let intents = model.intentsWith({}, "m", held[0])
  intents = model.intentsWith(intents, "m", held[1])
  assert.strictEqual(intents.m.length, 2)
  const failed = model.intentsSettled(intents, "m", 1, true, null)
  deepEqual(failed.outcome.summary, { id: "m", unread: false, starred: false })
  assert.strictEqual(failed.intents.m.length, 1, "the failed intent is gone, the other is held")
  const kept = model.intentsSettled(failed.intents, "m", 2, false, null)
  assert.strictEqual(kept.intents.m, undefined, "nothing held once every edit is answered")
  assert.strictEqual(kept.outcome.summary, null)
  const unknown = model.intentsSettled({}, "m", 7, true, { id: "m" })
  deepEqual(unknown.outcome.summary, { id: "m" }, "an id nothing was held for answers with the fallback")
  deepEqual(unknown.intents, {})
}

// Invariant: The first pending edit owns the settled list until every edit in that query has settled.
{
  let lists = model.settledListsHeld({}, "q", [{ id: "a" }, { id: "b" }], [])
  lists = model.settledListsHeld(lists, "q", [{ id: "b" }], [])
  deepEqual(lists.q.messages.map(r => r.id), ["a", "b"], "the second hold keeps the first list")
  assert.strictEqual(lists.q.pending, 2)
  lists = model.settledListsReleased(lists, "q")
  assert.strictEqual(lists.q.pending, 1)
  lists = model.settledListsReleased(lists, "q")
  assert.strictEqual(lists.q, undefined, "released once nothing is in flight")
  deepEqual(model.settledListsReleased({}, "q"), {})
}

assert.strictEqual(model.setupState({ toolsPresent: false }), "tools_missing")
assert.strictEqual(model.setupState({ toolsPresent: true, credentialsPresent: false }), "no_credentials")
assert.strictEqual(model.setupState({ toolsPresent: true, credentialsPresent: true, signedIn: false }), "signed_out")
assert.strictEqual(model.setupState({ toolsPresent: true, credentialsPresent: true, signingIn: true }), "signing_in")
assert.strictEqual(model.setupState({ toolsPresent: true, credentialsPresent: true,
  recoveringSession: true, signedIn: false }), "reconnecting")
assert.strictEqual(model.setupState({ toolsPresent: true, credentialsPresent: true, signedIn: true }), "ready")
assert.strictEqual(model.setupState(null), "tools_missing")

assert.ok(model.setupDetail("tools_missing", ["socat", "secret-tool"]).indexOf("socat, secret-tool") > 0)
assert.strictEqual(model.setupHeadline("ready"), "")
assert.strictEqual(model.setupHeadline("reconnecting"), "Reconnecting to Gmail…")
assert.ok(model.setupDetail("reconnecting").indexOf("retry automatically") > 0)
assert.strictEqual(model.setupActionLabel("reconnecting"), "")
assert.strictEqual(model.setupHeadline("signed_out"), "Sign in to Gmail",
  "an account with no provider recorded is a Gmail account")
assert.strictEqual(model.setupHeadline("signed_out", "IMAP"), "Sign in to IMAP")
assert.strictEqual(model.setupHeadline("no_credentials", "IMAP", "password"),
  "Add this mailbox", "only one of the two sends anyone to a Cloud console")
assert.strictEqual(model.setupHeadline("no_credentials", "Gmail", "oauth"),
  "Connect a Google Cloud project")
assert.strictEqual(model.setupHeadline("no_credentials", "Outlook", "oauth"),
  "Add this Outlook mailbox")
assert.strictEqual(model.setupHeadline("signing_in", "Outlook", "oauth"),
  "Waiting for Microsoft…")
assert.ok(model.setupDetail("no_credentials", [], "", "Outlook", "oauth")
  .indexOf("Microsoft") >= 0)

assert.strictEqual(model.setupDetail("unavailable", [], "no API yet", "HEY"), "no API yet")
assert.strictEqual(model.setupActionLabel("unavailable", "HEY"), "",
  "there is no button that would help")
assert.strictEqual(model.setupActionLabel("ready"), "")
// Invariant: Actions that open another workflow retain the trailing ellipsis.
assert.ok(model.setupActionLabel("no_credentials").endsWith("..."))
assert.strictEqual(model.setupActionLabel("signing_in"), "Cancel")
assert.ok(model.setupActionLabel("no_credentials", "IMAP", "password").endsWith("..."))

assert.ok(model.setupDetail("signing_in", [], "", "IMAP", "password").indexOf("browser") < 0)
assert.ok(model.setupDetail("signing_in", [], "", "Gmail", "oauth").indexOf("browser") > 0)

assert.strictEqual(model.survivesAction("inbox", "archive"), false)
assert.strictEqual(model.survivesAction("all", "archive"), true, "All mail still contains an archived message")
assert.strictEqual(model.survivesAction("starred", "archive"), true)
assert.strictEqual(model.survivesAction("unread", "markRead"), false)
assert.strictEqual(model.survivesAction("inbox", "markRead"), true)
assert.strictEqual(model.survivesAction("starred", "unstar"), false)
assert.strictEqual(model.survivesAction("inbox", "unstar"), true)
assert.strictEqual(model.survivesAction("inbox", "trash"), false)
assert.strictEqual(model.survivesAction("trash", "trash"), true)
assert.strictEqual(model.survivesAction("trash", "untrash"), false)

// Invariant: A folder move leaves its source view even when the remembered mailbox key names another view.
assert.strictEqual(model.survivesAction("inbox", "label:Label_7"), false)
assert.strictEqual(model.survivesAction("unread", "label:Label_7"), false)
assert.strictEqual(model.survivesAction("all", "label:Label_7"), true, "All mail still contains a moved message")
assert.strictEqual(model.survivesAction("starred", "label:Label_7", "folder:Receipts"), false,
  "a selected folder leaves even when the previous mailbox key was Starred")

deepEqual(model.labelChangesFor("archive"), { add: [], remove: ["INBOX"] })
deepEqual(model.labelChangesFor("star"), { add: ["STARRED"], remove: [] })
assert.strictEqual(model.labelChangesFor("trash"), null, "trash is its own endpoint, not a label change")

deepEqual(model.labelChangesFor("label:Label_7"), { add: ["Label_7"], remove: ["INBOX"] })
deepEqual(model.labelChangesFor("label:Label_7", "Label_3"),
  { add: ["Label_7"], remove: ["INBOX", "Label_3"] },
  "moving from a Gmail label removes the label that supplied the current view")
assert.strictEqual(model.labelTarget("label:Label_7"), "Label_7")
assert.strictEqual(model.labelTarget("archive"), "", "a verb that is not a move names no label")
assert.strictEqual(model.labelChangesFor("label:"), null, "a move with no destination is not a change")

// Invariant: The move capability governs user-chosen destinations; labels governs multiple labels per message.
assert.strictEqual(model.actionCapability("label:Label_7"), "move")
assert.strictEqual(model.actionUnavailable("label:Label_7", "HEY"), "HEY has no destination you can name")

const labelSet = [
  { id: "L2", name: "zebra" },
  { id: "S1", name: "Inbox", system: true },
  { id: "L1", name: "Archive notes" },
  { id: "L3", name: "banana" }
]
deepEqual(model.movableLabels(labelSet, "").map(l => l.id), ["L1", "L3", "L2"])
deepEqual(model.movableLabels(labelSet, "an").map(l => l.id), ["L3", "L1"],
  "case-insensitive: the typed run first, then the letters in order (A..n in Archive notes)")
deepEqual(model.movableLabels(labelSet, "  ZEB  ").map(l => l.id), ["L2"], "a typed query is trimmed")
deepEqual(model.movableLabels(labelSet, "inbox").map(l => l.id), [], "a system label is not a destination")
deepEqual(model.movableLabels(labelSet, "", "L3").map(l => l.id), ["L1", "L2"],
  "the current Gmail label or IMAP folder is not a move destination")
deepEqual(model.movableLabels(null, ""), [])

const row = { id: "a", labelIds: ["INBOX", "UNREAD"], unread: true, starred: false, inInbox: true }
const read = model.applyLabelChange(row, "markRead")
assert.strictEqual(read.unread, false)
deepEqual(read.labelIds, ["INBOX"])
assert.strictEqual(row.unread, true, "the original row is left alone")

const starred = model.applyLabelChange(row, "star")
assert.strictEqual(starred.starred, true)
deepEqual(starred.labelIds, ["INBOX", "UNREAD", "STARRED"])

deepEqual(model.applyLabelChange(starred, "star").labelIds, ["INBOX", "UNREAD", "STARRED"])
assert.strictEqual(model.applyLabelChange(row, "archive").inInbox, false)
assert.strictEqual(model.applyLabelChange(null, "star"), null)

// Invariant: Conversation flags aggregate counted members; zero members means unknown membership.

// Invariant: Star is message-scoped; unstar is conversation-scoped so no hidden starred member remains.
assert.strictEqual(model.actionScope("archive"), "conversation")
assert.strictEqual(model.actionScope("unarchive"), "conversation")
assert.strictEqual(model.actionScope("trash"), "conversation")
assert.strictEqual(model.actionScope("untrash"), "conversation")
assert.strictEqual(model.actionScope("spam"), "conversation")
assert.strictEqual(model.actionScope("markRead"), "conversation")
assert.strictEqual(model.actionScope("markUnread"), "conversation")
assert.strictEqual(model.actionScope("unstar"), "conversation")
assert.strictEqual(model.actionScope("star"), "message")
assert.strictEqual(model.actionScope(""), "message")

const block = (overrides) => Object.assign(
  { id: "t1", count: 3, unread: true, flagged: false,
    memberIds: ["m1", "m2", "m3"] }, overrides || {})
const conversation = (overrides) => Object.assign(
  { id: "m1", labelIds: ["INBOX"], unread: true, starred: false, inInbox: true,
    thread: block() }, overrides || {})

deepEqual(model.actionTargets(conversation(), "markRead"), ["m1", "m2", "m3"])
deepEqual(model.actionTargets(conversation(), "archive"), ["m1", "m2", "m3"])
deepEqual(model.actionTargets(conversation(), "star"), ["m1"])
// Invariant: A row with no counted conversation members targets only its own provider ID.
deepEqual(model.actionTargets({ id: "g1" }, "markRead"), ["g1"])
deepEqual(model.actionTargets({ id: "h1", thread: { id: "t", memberIds: [] } },
  "trash"), ["h1"])

deepEqual(model.actionTargets(
  conversation({ thread: block({ count: 1, memberIds: ["m1"] }) }), "markRead"),
  ["m1"])
deepEqual(model.actionTargets(null, "markRead"), [])

// Invariant: A representative ID takes precedence over the same ID appearing in another row's member list.
const rows = [{ id: "z", thread: { id: "t0", memberIds: ["m2", "z"] } },
  conversation()]
assert.strictEqual(model.rowIndexForMember(rows, "z"), 0)
assert.strictEqual(model.rowIndexForMember(rows, "m1"), 1)
assert.strictEqual(model.rowIndexForMember(rows, "m3"), 1)
assert.strictEqual(model.rowIndexForMember(rows, "nobody"), -1)
assert.strictEqual(model.rowIndexForMember(rows, ""), -1)
assert.strictEqual(model.rowHoldsMember(conversation(), "m2"), true)
assert.strictEqual(model.rowHoldsMember(conversation(), "m1"), true)
assert.strictEqual(model.rowHoldsMember(conversation(), "other"), false)
assert.strictEqual(model.rowHoldsMember(null, "m1"), false)

// Invariant: Member labels carry local unread state; summary.unread already includes the conversation aggregate.
const members = (overrides) => Object.assign({
  m1: { id: "m1", labelIds: ["INBOX"] },
  m2: { id: "m2", labelIds: ["INBOX", "UNREAD"] },
  m3: { id: "m3", labelIds: ["INBOX"] }
}, overrides || {})

deepEqual(model.threadAfterMemberChange(conversation(), members()),
  block({ unread: true }))

deepEqual(model.threadAfterMemberChange(conversation(),
  members({ m2: { id: "m2", labelIds: ["INBOX"] } })),
  block({ unread: false }))
// Invariant: An unknown member preserves an existing unread flag because it may be the unread member.
deepEqual(model.threadAfterMemberChange(conversation(),
  { m1: { id: "m1", labelIds: ["INBOX"] }, m3: { id: "m3", labelIds: ["INBOX"] } }),
  block({ unread: true }))
// Invariant: An unknown member cannot turn an existing read flag into unread.
deepEqual(model.threadAfterMemberChange(conversation({ thread: block({ unread: false }) }),
  { m1: { id: "m1", labelIds: ["INBOX"] }, m3: { id: "m3", labelIds: ["INBOX"] } }),
  block({ unread: false }))

deepEqual(model.threadAfterMemberChange(conversation(),
  members({ m3: { id: "m3", labelIds: ["INBOX", "STARRED"] } })),
  block({ unread: true, flagged: true }))
assert.strictEqual(model.threadAfterMemberChange({ id: "g1" }, {}), null)

deepEqual(model.threadAfterAction(conversation(), "markRead"), block({ unread: false }))
deepEqual(model.threadAfterAction(conversation({ thread: block({ unread: false }) }),
  "markUnread"), block({ unread: true }))
deepEqual(model.threadAfterAction(conversation({ thread: block({ flagged: true }) }),
  "unstar"), block({ flagged: false }))

deepEqual(model.threadAfterAction(conversation({ thread: block({ flagged: false }) }),
  "star"), block({ flagged: false }))

// Invariant: Representative flags retain the conversation aggregate unless a complete conversation action replaces it.
const readRow = model.applyLabelChange(conversation(), "markRead")
assert.strictEqual(readRow.unread, true, "a member is still unread")
deepEqual(readRow.labelIds, ["INBOX"])
const readConversation = model.applyLabelChange(conversation(), "markRead", "",
  model.threadAfterAction(conversation(), "markRead"))
assert.strictEqual(readConversation.unread, false)
assert.strictEqual(readConversation.thread.unread, false)

// Invariant: Filtered unread/starred views use the recomputed conversation flags; other views retain verb rules.
const survives = (key, action, row) => model.survivesAction(key, action, "", false, "", row)
assert.strictEqual(survives("unread", "markRead", conversation()), true)
assert.strictEqual(survives("unread", "markRead",
  conversation({ thread: block({ unread: false }) })), false)
assert.strictEqual(survives("unread", "markRead", { id: "g1" }), false)
assert.strictEqual(survives("starred", "unstar",
  conversation({ thread: block({ flagged: true }) })), true)
assert.strictEqual(survives("starred", "unstar",
  conversation({ thread: block({ flagged: false }) })), false)
assert.strictEqual(survives("starred", "unstar", { id: "g1" }), false)

assert.strictEqual(survives("inbox", "archive", conversation()), false)
assert.strictEqual(survives("inbox", "markRead", conversation()), true)
assert.strictEqual(survives("trash", "trash", conversation()), true)

assert.strictEqual(model.markAllReadNote(3, true), "3 conversations marked read")
assert.strictEqual(model.markAllReadNote(3, false), "3 messages marked read")
assert.strictEqual(model.markAllReadNote(1, true), "1 conversation marked read")
assert.strictEqual(model.markAllReadNote(1, false), "1 message marked read")

assert.strictEqual(model.showInitialListSkeleton(true, 0), true,
  "an empty initial fetch uses rows shaped like the list")
assert.strictEqual(model.showInitialListSkeleton(true, 3), false,
  "pagination keeps the messages already on screen")
assert.strictEqual(model.showInitialListSkeleton(false, 0), false,
  "an empty result is not still loading")
assert.strictEqual(model.showListFooter(0), false,
  "an empty state must not compete with pagination controls")
assert.strictEqual(model.showListFooter(1), true,
  "loaded messages retain their result summary and pagination")

const list = [{ id: "a", unread: true }, { id: "b", unread: false }, { id: "c", unread: true }]
deepEqual(model.removeById(list, "b").map(entry => entry.id), ["a", "c"])
deepEqual(model.removeById(list, "zzz").map(entry => entry.id), ["a", "b", "c"])
deepEqual(model.replaceById(list, { id: "b", unread: true }).map(entry => entry.unread), [true, true, true])
assert.strictEqual(model.indexById(list, "c"), 2)
assert.strictEqual(model.indexById(list, "zzz"), -1)
assert.strictEqual(model.indexById(null, "a"), -1)
assert.strictEqual(model.messageById(list, [{ id: "preview" }], "preview").id, "preview")
assert.strictEqual(model.messageById(list, [{ id: "preview" }], "a").id, "a")
assert.strictEqual(model.messageById(list, [{ id: "preview" }], "missing"), null)
assert.strictEqual(model.unreadCount(list), 2)
assert.strictEqual(model.unreadCount([]), 0)

// Invariant: Live search metadata replaces cached copies while preserving other preview rows until settlement.
const cachedSearch = [
  { id: "old", subject: "cached", date: new Date("2026-08-20T10:00:00Z") },
  { id: "same", subject: "stale", date: new Date("2026-08-22T10:00:00Z") }
]
const liveSearch = [
  { id: "new", subject: "live", date: new Date("2026-08-24T10:00:00Z") },
  { id: "same", subject: "fresh", date: new Date("2026-08-22T10:00:00Z") }
]
const searchMerged = model.mergeSearchResults(cachedSearch, liveSearch)
deepEqual(searchMerged.map(entry => entry.id), ["new", "same", "old"])
assert.strictEqual(searchMerged[1].subject, "fresh")
deepEqual(model.mergeSearchResults(null, liveSearch).map(entry => entry.id), ["new", "same"])

// Invariant: A settled server page removes cached false positives and may use cached metadata only for server-confirmed IDs.
const settledSearch = model.settledSearchResults([], cachedSearch, liveSearch,
  ["new", "same"], false)
deepEqual(settledSearch.map(entry => entry.id), ["new", "same"])
assert.strictEqual(settledSearch[1].subject, "fresh")
deepEqual(model.settledSearchResults([], cachedSearch, [], ["same"], false)
  .map(entry => entry.id), ["same"], "a server-confirmed cached row may fill in")
deepEqual(model.settledSearchResults([], cachedSearch, liveSearch, [], false), [],
  "an empty server answer removes every preview row")
deepEqual(model.settledSearchResults([{ id: "page-1" }], cachedSearch,
  liveSearch, ["new"], true).map(entry => entry.id), ["new", "page-1"],
  "an appended authoritative page keeps the pages already settled")
deepEqual(model.missingSearchSummaryIds(liveSearch, ["new", "same"]), [])
deepEqual(model.missingSearchSummaryIds(liveSearch, ["new", "missing", "same"]),
  ["missing"], "a partial metadata answer names the paging hole")

assert.strictEqual(model.badgeText(0), "")
assert.strictEqual(model.badgeText(7), "7")
assert.strictEqual(model.badgeText(99), "99")
assert.strictEqual(model.badgeText(100), "99+")
assert.strictEqual(model.badgeText(1500, 99), "99+")
assert.strictEqual(model.badgeText(-3), "")

assert.strictEqual(model.barTooltip("ready", "me@example.com", 0), "me@example.com · No unread mail")
assert.strictEqual(model.barTooltip("ready", "me@example.com", 1), "me@example.com · 1 unread message")
assert.strictEqual(model.barTooltip("ready", "me@example.com", 4), "me@example.com · 4 unread messages")
assert.strictEqual(model.barTooltip("ready", "", 2), "Gmail · 2 unread messages")
assert.strictEqual(model.barTooltip("signed_out", "me@example.com", 9), "Gmail · Sign in to Gmail")
assert.strictEqual(model.barTooltip("signed_out", "me@example.com", 9, "IMAP"),
  "IMAP · Sign in to IMAP")
assert.strictEqual(model.barTooltip("ready", "", 2, "IMAP"), "IMAP · 2 unread messages")

// Invariant: New-mail notifications begin only after the first inbox load primes the seen set.

const inbox = [
  { id: "a", unread: true, inInbox: true, subject: "one" },
  { id: "b", unread: false, inInbox: true, subject: "two" },
  { id: "c", unread: true, inInbox: true, subject: "three" },
  { id: "d", unread: true, inInbox: false, subject: "archived elsewhere" }
]

deepEqual(model.newArrivals(inbox, {}, false), [], "nothing fires before priming")
deepEqual(model.newArrivals(inbox, { a: true }, true).map(entry => entry.id), ["c"])
deepEqual(model.newArrivals(inbox, { a: true, c: true }, true), [])
deepEqual(model.newArrivals([], {}, true), [])

// Invariant: The notification floor suppresses old unread mail absent from the original cached page.
const floor = Date.parse("2026-08-01T00:00:00Z")
const timeInbox = [
  { id: "old", unread: true, inInbox: true, date: new Date(floor - 1000000) },
  { id: "new", unread: true, inInbox: true, date: new Date(floor + 1000) },
  { id: "nodate", unread: true, inInbox: true, date: null }
]
deepEqual(model.newArrivals(timeInbox, {}, true, floor).map(entry => entry.id),
  ["new", "nodate"],
  "an older message is not an arrival, and one with no date is still announced")

// Invariant: The newest mailbox timestamp supplies the notification floor; the local clock may be ahead of the server.
assert.strictEqual(model.newestDate(timeInbox), floor + 1000)
assert.strictEqual(model.newestDate([{ id: "x", date: null }]), 0)
assert.strictEqual(model.newestDate([]), 0)
assert.strictEqual(model.newestDate(null), 0)

const skewed = model.newestDate(timeInbox)
deepEqual(model.newArrivals(timeInbox, {}, true, skewed).map(entry => entry.id),
  ["new", "nodate"],
  "the newest row is itself never below the floor it set")

deepEqual(model.newArrivals(timeInbox, {}, true, 0).map(entry => entry.id),
  ["old", "new", "nodate"])

assert.strictEqual(model.notificationBody({ subject: "Invoice", snippet: "Due Friday" }), "Invoice\nDue Friday")
assert.strictEqual(model.notificationBody({ subject: "Invoice", snippet: "" }), "Invoice")
assert.strictEqual(model.notificationBody(null), "")
assert.ok(model.notificationBody({ subject: "s", snippet: "x".repeat(400) }).length < 160)

assert.strictEqual(model.resultSummary([], 0, false), "No messages")
assert.strictEqual(model.resultSummary([{}], 1, false), "1 message")
assert.strictEqual(model.resultSummary([{}, {}], 2, false), "2 messages")
assert.strictEqual(model.resultSummary([{}, {}], 87, true), "2 of about 87")
// Invariant: A provider estimate no larger than the page is not a confirmed total when more pages remain.
assert.strictEqual(model.resultSummary([{}, {}, {}], 1, true), "3 messages so far")
assert.strictEqual(model.resultSummary([{}, {}, {}], 3, true), "3 messages so far")
// Invariant: Only counted multi-member rows justify describing the result as conversations.
assert.strictEqual(model.resultSummary(
  [{ thread: { id: "t", memberIds: ["a", "b"] } }, {}], 2, false), "2 conversations")
assert.strictEqual(model.resultSummary(
  [{ thread: { id: "t", memberIds: ["a", "b"] } }, {}], 87, true), "2 of about 87")
assert.strictEqual(model.resultSummary(
  [{ thread: { id: "t", memberIds: ["a", "b"] } }], 1, true), "1 conversation so far")
assert.strictEqual(model.resultSummary(
  [{ thread: { id: "t", memberIds: ["a"] } }, {}], 2, false), "2 messages")

assert.strictEqual(model.syncedShort("Synced 1m ago"), "1m ago")
assert.strictEqual(model.syncedShort("Synced just now"), "just now")
assert.strictEqual(model.syncedShort("Checking for mail"), "checking")
assert.strictEqual(model.syncedShort(""), "")
assert.strictEqual(model.accountStatusLine("me@example.com", "Synced 1m ago"), "me@example.com · 1m ago")
assert.strictEqual(model.accountStatusLine("me@example.com", ""), "me@example.com",
  "nothing synced yet is just the address, not a dangling dot")
assert.strictEqual(model.accountStatusLine("", "Synced 1m ago"), "Not connected")

assert.strictEqual(model.truncate("short", 20), "short")
assert.strictEqual(model.truncate("a much longer string", 10), "a much lo…")
assert.strictEqual(model.pluralize(1, "message"), "1 message")
assert.strictEqual(model.pluralize(0, "message"), "0 messages")

// Invariant: Model notification output is plain text; markup escaping belongs to the final platform consumer.
{
  const crafted = {
    subject: "<img src=\"http://tracker.example.com/p.gif\">",
    snippet: "a & b",
    from: { display: "-u critical" }
  }
  assert.ok(model.notificationBody(crafted).indexOf("<img") >= 0)
  assert.ok(model.notificationBody(crafted).indexOf("a & b") >= 0)
  assert.strictEqual(model.notificationTitle(crafted), "-u critical")
  assert.strictEqual(model.notificationTitle({ from: { display: "" } }), "New message")
  assert.strictEqual(model.notificationTitle(null), "New message")
}

// Invariant: Keyboard movement advances from the list cursor independently of the opened message.
{
  const rows = [{ id: "a" }, { id: "b" }, { id: "c" }, { id: "d" }]

  assert.strictEqual(model.cursorAfterOffset(rows, "", 1), "a",
    "with no cursor yet, j starts at the top")
  assert.strictEqual(model.cursorAfterOffset(rows, "", -1), "d",
    "with no cursor yet, k starts at the bottom")

  assert.strictEqual(model.cursorAfterOffset(rows, "a", 1), "b")
  assert.strictEqual(model.cursorAfterOffset(rows, "b", 1), "c")
  assert.strictEqual(model.cursorAfterOffset(rows, "c", 1), "d")
  assert.strictEqual(model.cursorAfterOffset(rows, "d", 1), "d",
    "the last row is where moving down stops")

  assert.strictEqual(model.cursorAfterOffset(rows, "c", -1), "b")
  assert.strictEqual(model.cursorAfterOffset(rows, "a", -1), "a",
    "the first row is where moving up stops")

  assert.strictEqual(model.cursorAfterOffset([], "a", 1), "",
    "an empty list has nowhere to go")
  assert.strictEqual(model.cursorAfterOffset(rows, "gone", 1), "a",
    "a cursor whose message left the list starts over rather than sticking")
  assert.strictEqual(model.cursorAfterOffset(rows, "a", 0), "a",
    "a zero step is a no-op, not a jump to the top")
}

// Invariant: The shared Flickable requires explicit row-reveal offsets rather than ListView positioning.
{

  const view = 100
  const content = 500
  const viewportMargin = 4

  assert.strictEqual(
    model.contentYToReveal(0, view, 40, 20, content, viewportMargin), 0,
    "a row already on screen does not move the list under the reader")

  assert.strictEqual(
    model.contentYToReveal(0, view, 90, 20, content, viewportMargin), 14,
    "a row off the bottom scrolls just far enough, plus the margin")

  assert.strictEqual(
    model.contentYToReveal(200, view, 180, 20, content, viewportMargin), 176,
    "a row off the top scrolls back to it, plus the margin")

  assert.strictEqual(
    model.contentYToReveal(10, view, 0, 20, content, viewportMargin), 0,
    "the top of the list is as far up as it goes: no negative offset")

  assert.strictEqual(
    model.contentYToReveal(380, view, 480, 20, content, viewportMargin), 400,
    "the bottom clamps to the last screenful rather than scrolling past it")

  assert.strictEqual(
    model.contentYToReveal(0, view, 40, 300, content, viewportMargin), 36,
    "a row taller than the viewport shows its top rather than its bottom")

  assert.strictEqual(
    model.contentYToReveal(0, 500, 40, 20, 400, viewportMargin), 0,
    "content shorter than the viewport never scrolls")
}

// Invariant: Removal chooses a surviving neighbour; replacing the list retains the cursor only if its row survives.
{
  const rows = [{ id: "a" }, { id: "b" }, { id: "c" }]

  assert.strictEqual(model.cursorAfterRemoval(rows, "a"), "b")
  assert.strictEqual(model.cursorAfterRemoval(rows, "b"), "c")

  assert.strictEqual(model.cursorAfterRemoval(rows, "c"), "b")
  assert.strictEqual(model.cursorAfterRemoval([{ id: "only" }], "only"), "",
    "emptying the list leaves no cursor to hold")
  assert.strictEqual(model.cursorAfterRemoval(rows, "gone"), "",
    "a cursor that is already adrift has no neighbour to inherit")
  assert.strictEqual(model.cursorAfterRemoval([], "a"), "")

  assert.strictEqual(model.cursorAfterReload(rows, "b"), "b",
    "a refresh that kept the message keeps the cursor")
  assert.strictEqual(model.cursorAfterReload(rows, "gone"), "a",
    "a mailbox switch lands on the first row rather than nowhere")
  assert.strictEqual(model.cursorAfterReload(rows, ""), "a",
    "and so does a list arriving for the first time")
  assert.strictEqual(model.cursorAfterReload([], "b"), "",
    "an empty mailbox has no row to sit on")
}

// Invariant: User labels sort by case-folded name and stable ID rather than provider creation order.
{
  const reported = [
    { id: "L2", name: "zebra", rawName: "zebra" },
    { id: "S1", name: "Inbox", rawName: "INBOX", system: true },
    { id: "L4", name: "Work/Invoices", rawName: "Work/Invoices" },
    { id: "L1", name: "Bills", rawName: "Bills" },
    { id: "L3", name: "Work", rawName: "Work" },
    { id: "L5", name: "archive notes", rawName: "archive notes" }
  ]
  deepEqual(model.railLabels(reported).map(l => l.id), ["L5", "L1", "L3", "L4", "L2"],
    "A to Z, case folded, a nested folder under its parent, and no system label")
  const twins = [
    { id: "b", name: "Work" }, { id: "c", name: "Bills" }, { id: "a", name: "work" }
  ]
  deepEqual(model.railLabels(twins).map(l => l.id), ["c", "a", "b"],
    "two labels that print the same are ordered by id, so the pair never swaps")
  deepEqual(model.railLabels(twins.slice().reverse()).map(l => l.id), ["c", "a", "b"],
    "whatever order the server handed them over in")
  deepEqual(reported.map(l => l.id), ["L2", "S1", "L4", "L1", "L3", "L5"],
    "the provider's own list is not reordered underneath it")
  deepEqual(model.railLabels(null), [])
  deepEqual(model.railLabels([null, { id: "L9", name: "x" }]).map(l => l.id), ["L9"])
}

{
  const boxes = [
    { key: "inbox", label: "Inbox" },
    { key: "unread", label: "Unread" },
    { key: "sent", label: "Sent" }
  ]
  const labels = [
    { id: "SYS", name: "Category", rawName: "Category", system: true },
    { id: "L1", name: "Work", rawName: "Work" },
    { id: "L2", name: "Bills", rawName: "Bills" }
  ]
  // Invariant: Sidebar digits follow the exact visible tree order supplied by the caller.
  const slots = model.sidebarSlots(boxes, model.visibleLabels(labels, []), 10)
  assert.strictEqual(slots.length, 5, "system labels are not rows and get no number")
  assert.strictEqual(slots[0].kind, "mailbox")
  assert.strictEqual(slots[0].key, "inbox")
  assert.strictEqual(slots[3].kind, "label")
  assert.strictEqual(slots[3].id, "L2",
    "Bills is numbered before Work: the digits follow the rail, and the rail is A to Z")
  assert.strictEqual(model.sidebarSlots(boxes, labels, 10)[3].id, "L1",
    "in the order given: the caller says what the rail draws")
  // Invariant: A child receives a digit immediately after its parent, before the next alphabetic sibling.
  const treeLabels = [
    { id: "Work (old)", name: "Work (old)", delimiter: "/" }, { id: "Work/Invoices", name: "Work/Invoices", delimiter: "/" },
    { id: "Work", name: "Work", delimiter: "/" }]
  deepEqual(model.sidebarSlots([], model.visibleLabels(treeLabels, []), 10).map(function (s) { return s.id }),
    ["Work", "Work/Invoices", "Work (old)"])
  deepEqual(model.sidebarSlots([], model.visibleLabels(treeLabels, ["Work"]), 10).map(function (s) { return s.id }),
    ["Work", "Work (old)"], "a folded child has no number: a digit never opens a row that is not on screen")
  assert.strictEqual(slots[3].name, "Bills", "the name a provider selects a label by")

  assert.strictEqual(model.slotNumberOf(slots, "mailbox", "inbox"), 1)
  assert.strictEqual(model.slotNumberOf(slots, "mailbox", "sent"), 3)
  assert.strictEqual(model.slotNumberOf(slots, "label", "L1"), 5)
  assert.strictEqual(model.slotNumberOf(slots, "label", "SYS"), 0)
  assert.strictEqual(model.slotNumberOf(slots, "mailbox", "L1"), 0,
    "a key and an id are not the same handle")
  assert.strictEqual(model.slotNumberOf([], "mailbox", "inbox"), 0)

  // Invariant: Only the first nine visible rows receive digits; Ctrl+0 remains the zoom shortcut.
  const many = []
  for (let sampleIndex = 0; sampleIndex < 14; sampleIndex++) many.push({ id: "L" + sampleIndex, name: "n" + sampleIndex, rawName: "n" + sampleIndex })
  assert.strictEqual(model.sidebarSlots(boxes, many, 9).length, 9)
  assert.strictEqual(model.slotNumberOf(model.sidebarSlots(boxes, many, 9), "label", "L6"), 0,
    "past the ninth row there is no digit left to offer: Ctrl+0 belongs to the zoom")
  assert.strictEqual(model.sidebarSlots(null, null, 10).length, 0)
}

assert.strictEqual(model.wrappedIndex(0, 1, 3), 1)
assert.strictEqual(model.wrappedIndex(2, 1, 3), 0, "past the last row comes back to the first")
assert.strictEqual(model.wrappedIndex(0, -1, 3), 2, "and backwards off the top wraps too")
assert.strictEqual(model.wrappedIndex(1, 0, 3), 1)
assert.strictEqual(model.wrappedIndex(0, 1, 1), 0, "one mailbox has nowhere to go")
assert.strictEqual(model.wrappedIndex(0, 1, 0), 0, "and no mailboxes must not divide by zero")
assert.strictEqual(model.wrappedIndex(-1, 1, 3), 0)

// Invariant: Keyboard actions must honor the same provider capability refusals as hidden buttons.

assert.strictEqual(model.actionCapability("archive"), "archive")
assert.strictEqual(model.actionCapability("unarchive"), "archive")
assert.strictEqual(model.actionCapability("star"), "star")
assert.strictEqual(model.actionCapability("unstar"), "star")
assert.strictEqual(model.actionCapability("spam"), "spam")
assert.strictEqual(model.actionCapability("trash"), "", "every provider can trash")
assert.strictEqual(model.actionCapability("markRead"), "")

assert.strictEqual(model.actionUnavailable("archive", "HEY"), "HEY has no archive")
assert.strictEqual(model.actionUnavailable("star", "HEY"), "HEY has no star")
assert.strictEqual(model.actionUnavailable("spam", "IMAP"),
  "IMAP has no junk verb to report to")
assert.strictEqual(model.actionUnavailable("trash", "HEY"), "")

deepEqual(model.unavailableActions({ archive: true, star: true, spam: true, move: true }), [])
deepEqual(model.unavailableActions({ archive: false, star: false, move: false }),
  ["archive", "star", "move"])
deepEqual(model.unavailableActions(null), ["archive", "star", "move"],
  "an unknown provider offers nothing it cannot prove")

assert.strictEqual(model.badgeCount({ thread: { id: "d", count: 3, memberIds: ["a", "b", "c"] } }), 3)
assert.strictEqual(model.badgeCount({ thread: { id: "d", count: 1, memberIds: ["a"] } }), 0)
assert.strictEqual(model.badgeCount({ thread: { id: "d", count: 0, memberIds: [] } }), 0)
assert.strictEqual(model.badgeCount({ id: "m" }), 0)
assert.strictEqual(model.badgeCount(null), 0)

console.log("test_model.js ok")

// Invariant: Zoom steps round to twentieths so reversing a step restores the saved value.
assert.strictEqual(model.zoomAfterStep(1, 0.1), 1.1)
assert.strictEqual(model.zoomAfterStep(1.1, -0.1), 1)
assert.strictEqual(model.zoomAfterStep(1.37, 0), 1.35)

assert.strictEqual(model.zoomAfterStep(2.5, 0.1), 2.5)
assert.strictEqual(model.zoomAfterStep(0.6, -0.1), 0.6)
assert.strictEqual(model.zoomAfterStep(99, 0), 2.5)

// Invariant: Persisted zoom accepts numeric strings but uses the default for nonnumeric values.
assert.strictEqual(model.clampZoom(undefined), 1)
assert.strictEqual(model.clampZoom(null), 1)
assert.strictEqual(model.clampZoom("nonsense"), 1)
assert.strictEqual(model.clampZoom(0), 0.6, "but zero is a number, and clamps")
assert.strictEqual(model.clampZoom("1.5"), 1.5, "including one written as text")

deepEqual(model.windowPrefs(""), {
  sidebarCollapsed: false, sidebarWidth: 0, listWidth: 0, collapsedFolders: [], bodyZoom: 1, bodyMode: "reader",
  alwaysShowImages: false, windowOpen: false
})
assert.strictEqual(model.windowPrefs('{"plainTextForced":true}').bodyMode, "plain",
  "the old two-mode preference migrates to the three-mode setting")
assert.strictEqual(model.windowPrefs('{"bodyMode":"original"}').bodyMode, "original")
assert.strictEqual(model.windowPrefs('{"bodyMode":"unknown"}').bodyMode, "reader")
assert.strictEqual(model.windowPrefs('{"windowOpen":true}').windowOpen, true)
assert.strictEqual(model.windowPrefs('{"sidebarWidth":180,"listWidth":"420"}').sidebarWidth, 180)
assert.strictEqual(model.windowPrefs('{"sidebarWidth":180,"listWidth":"420"}').listWidth, 420)
assert.strictEqual(model.windowPrefs('{"sidebarWidth":-3,"listWidth":"wide"}').sidebarWidth, 0,
  "a bad width is a default, not a pane of no width")
assert.strictEqual(model.paneWidth(99999), 4000)
assert.strictEqual(model.paneWidth(0), 0)
deepEqual(model.windowPrefs('{"collapsedFolders":["Archive","",3,"Archive"]}').collapsedFolders, ["Archive", "3"])
assert.strictEqual(model.windowPrefs('{"windowOpen":"yes"}').windowOpen, false)

// Invariant: A detail response is authoritative only for fields it carries; HEY bodies may omit listing metadata.

const listed = {
  id: "1:2",
  subject: "Lunch on Friday",
  from: { name: "Jane", email: "jane@example.com" },
  snippet: "Are you free",
  date: new Date("2026-08-20T10:00:00Z"),
  time: "10:00",
  fullTime: "Aug 20, 2026 10:00"
}
const bodyless = {
  id: "1:2",
  subject: "(no subject)",
  from: { name: "", email: "" },
  snippet: "",
  date: null,
  time: "",
  fullTime: "",
  unread: false
}

const merged = model.detailSummary(listed, bodyless)
assert.strictEqual(merged.subject, "Lunch on Friday")
assert.strictEqual(merged.from.email, "jane@example.com")
assert.strictEqual(merged.snippet, "Are you free")
assert.strictEqual(merged.time, "10:00")

assert.strictEqual(merged.unread, false)

const full = model.detailSummary(listed, {
  id: "1:2", subject: "Re: Lunch on Friday",
  from: { name: "Jane", email: "jane@example.com" },
  snippet: "Yes", date: new Date("2026-08-21T10:00:00Z"), time: "10:00", fullTime: "x"
})
assert.strictEqual(full.subject, "Re: Lunch on Friday", "a detail read that knows wins")
assert.strictEqual(full.snippet, "Yes")

assert.strictEqual(model.detailSummary(null, bodyless).subject, "(no subject)")
assert.strictEqual(model.detailSummary(listed, null), listed)

// Invariant: A detail response with zero counted members cannot erase a listing's known conversation membership.
const grouped = {
  id: "maaaaaf", subject: "Re: Thread of three",
  from: { name: "Bea", email: "bea@example.org" }, snippet: "Third",
  date: new Date("2026-08-22T10:00:00Z"), time: "10:00", fullTime: "x",
  unread: true, starred: false,
  thread: { id: "d", count: 3, unread: true, flagged: false,
    memberIds: ["maaaaad", "maaaaae", "maaaaaf"] }
}
const opened = model.detailSummary(grouped, {
  id: "maaaaaf", subject: "Re: Thread of three",
  from: { name: "Bea", email: "bea@example.org" }, snippet: "Third",
  date: new Date("2026-08-22T10:00:00Z"), time: "10:00", fullTime: "x",
  unread: false, starred: false,
  thread: { id: "d", count: 0, unread: false, flagged: false, memberIds: [] }
})
assert.strictEqual(opened.thread.count, 3, "the row keeps the count the listing gave it")
deepEqual(opened.thread.memberIds, ["maaaaad", "maaaaae", "maaaaaf"])
// Invariant: Preserving a listing's conversation block must not restore its stale unread field over a detail response.
assert.strictEqual(opened.unread, false)

assert.strictEqual(model.detailSummary(grouped, {
  id: "maaaaaf", subject: "Re: Thread of three",
  from: { name: "Bea", email: "bea@example.org" }, snippet: "Third",
  date: new Date("2026-08-22T10:00:00Z"), time: "10:00", fullTime: "x",
  thread: { id: "d", count: 2, unread: false, flagged: false,
    memberIds: ["maaaaae", "maaaaaf"] }
}).thread.count, 2)

// Invariant: Current in-memory labels override cached detail labels; cached message content remains usable.
{
  const fromDisk = {
    id: "reply", subject: "Re: Lunch on Friday", snippet: "Yes",
    unread: true, starred: false, inInbox: true, inTrash: false,
    labelIds: ["INBOX", "UNREAD"],
    thread: { id: "d", count: 0, unread: false, flagged: false, memberIds: [] }
  }
  const inHand = { id: "reply", unread: false, starred: true, labelIds: ["INBOX", "STARRED"] }
  const painted = model.cachedDetailSummary(inHand, fromDisk)
  deepEqual(painted.labelIds, ["INBOX", "STARRED"])
  assert.strictEqual(painted.unread, false, "read a moment ago stays read")
  assert.strictEqual(painted.starred, true)
  assert.strictEqual(painted.inInbox, true)
  assert.strictEqual(painted.subject, "Re: Lunch on Friday", "everything else is the file's")
  assert.strictEqual(painted.snippet, "Yes")
  assert.strictEqual(painted.thread.count, 0, "a member has no block in hand, so the file's stands")
  deepEqual(fromDisk.labelIds, ["INBOX", "UNREAD"], "the file's summary is not written on")
  // Invariant: A current representative block overrides the cached block, including aggregate member flags.
  const filed = {
    id: "rep", labelIds: ["INBOX", "UNREAD"], unread: true, starred: false,
    thread: { id: "d", count: 2, unread: true, flagged: false, memberIds: ["rep", "reply"] }
  }
  const settled = { id: "rep", unread: false, starred: false, labelIds: ["INBOX"],
    thread: { id: "d", count: 2, unread: false, flagged: false, memberIds: ["rep", "reply"] } }
  const representative = model.cachedDetailSummary(settled, filed)
  assert.strictEqual(representative.unread, false)
  assert.strictEqual(representative.thread.unread, false, "the row's block replaced the file's")
  const replyStillUnread = { ...settled, thread: { ...settled.thread, unread: true } }
  assert.strictEqual(model.cachedDetailSummary(replyStillUnread, filed).unread, true)

  assert.strictEqual(model.cachedDetailSummary({ ...settled, thread: { id: "d", count: 0, memberIds: [] } }, filed).thread.count, 2)

  const moved = model.cachedDetailSummary({ id: "reply", labelIds: ["TRASH"] }, fromDisk)
  assert.strictEqual(moved.inInbox, false)
  assert.strictEqual(moved.inTrash, true)
  // Invariant: No matching in-memory label evidence leaves the cached detail unchanged.
  assert.strictEqual(model.cachedDetailSummary(null, fromDisk), fromDisk)
  assert.strictEqual(model.cachedDetailSummary({ id: "reply" }, fromDisk), fromDisk)
  assert.strictEqual(model.cachedDetailSummary({ id: "other", labelIds: [] }, fromDisk), fromDisk)
  assert.strictEqual(model.cachedDetailSummary(inHand, null), null)
}

assert.strictEqual(model.setupHeadline("tools_missing", "HEY", "cli"),
  "Install the HEY CLI")
assert.strictEqual(model.setupHeadline("tools_missing", "Gmail", "oauth"),
  "Missing system tools")
assert.strictEqual(model.setupHeadline("no_credentials", "HEY", "cli"), "Sign in to HEY")
assert.strictEqual(model.setupHeadline("signing_in", "HEY", "cli"), "Waiting for HEY…")

assert.ok(model.setupDetail("tools_missing", ["hey"], "", "HEY", "cli").indexOf("HEY CLI") >= 0)
assert.ok(model.setupDetail("signed_out", [], "", "HEY", "cli").indexOf("The HEY CLI") === 0)
assert.ok(model.setupDetail("no_credentials", [], "", "HEY", "cli").indexOf("never sees") >= 0)
assert.strictEqual(model.setupActionLabel("tools_missing", "HEY", "cli"), "Check again")
assert.strictEqual(model.setupActionLabel("no_credentials", "HEY", "cli"), "Sign in to HEY...")

// Invariant: Switching accounts preserves a mailbox only if the destination provider offers it.
assert.strictEqual(model.mailboxAfterAccountSwitch("unread", [
  { key: "inbox" }, { key: "unread" }, { key: "all" }
]), "unread")
assert.strictEqual(model.mailboxAfterAccountSwitch("starred", [
  { key: "inbox" }, { key: "unread" }
]), "")

const sections = [
  { key: "reading", title: "Reading", y: 40 },
  { key: "writing", title: "Writing", y: 300 },
  { key: "mailboxes", title: "Mailboxes", y: 700 }
]
assert.strictEqual(model.activeSettingsSection(sections, 0), "reading")
assert.strictEqual(model.activeSettingsSection(sections, 299), "reading")
assert.strictEqual(model.activeSettingsSection(sections, 300), "writing")
assert.strictEqual(model.activeSettingsSection(sections, 699), "writing")
assert.strictEqual(model.activeSettingsSection(sections, 700), "mailboxes")
assert.strictEqual(model.activeSettingsSection(sections, 5000), "mailboxes")
assert.strictEqual(model.activeSettingsSection([], 100), "", "no sections, no answer")
// Invariant: The active settings section follows screen coordinates rather than source declaration order.
assert.strictEqual(model.activeSettingsSection([sections[2], sections[0], sections[1]], 300), "writing")

// Invariant: Settings content includes enough trailing space for the last heading to reach the viewport top.
assert.strictEqual(model.settingsContentHeight(sections, 900, 500), 1200)
assert.strictEqual(model.settingsContentHeight(sections, 1500, 500), 1500)
assert.strictEqual(model.settingsContentHeight([], 900, 500), 900, "nothing to reach, nothing to pad")

assert.strictEqual(model.settingsScrollTarget(sections, "writing", 1200, 500), 300)
assert.strictEqual(model.settingsScrollTarget(sections, "mailboxes", 1200, 500), 700)
assert.strictEqual(model.settingsScrollTarget(sections, "mailboxes", 1000, 500), 500, "clamped to the end")
assert.strictEqual(model.settingsScrollTarget(sections, "reading", 400, 500), 0, "a page shorter than its viewport does not scroll")
assert.strictEqual(model.settingsScrollTarget(sections, "nope", 1200, 500), -1)
assert.strictEqual(model.settingsScrollTarget(null, "reading", 1200, 500), -1)

deepEqual(model.contentYBounds(0, 5000, 300, 0, 0), { min: 0, max: 4700 })

// Invariant: Flickable margins extend both ends of the legal contentY range, including negative top offsets.
deepEqual(model.contentYBounds(0, 5000, 300, 50, 70), { min: -50, max: 4770 })

// Invariant: A ListView header changes originY and must remain reachable through the scroll clamp.
deepEqual(model.contentYBounds(-200, 4200, 300, 0, 0), { min: -200, max: 3700 })

// Invariant: Content shorter than its viewport has one legal position at its top margin.
deepEqual(model.contentYBounds(0, 100, 300, 0, 0), { min: 0, max: 0 })
deepEqual(model.contentYBounds(0, 100, 300, 50, 70), { min: -50, max: -50 })

assert.strictEqual(model.clampContentY(9999, { min: -50, max: 4770 }), 4770)
assert.strictEqual(model.clampContentY(-9999, { min: -50, max: 4770 }), -50)
assert.strictEqual(model.clampContentY(100, { min: -50, max: 4770 }), 100)

// Invariant: Wheel distance depends on summed angleDelta, independent of event chunking.
const NOTCH = 120
assert.strictEqual(model.wheelDistance(-NOTCH), -model.WHEEL_PIXELS_PER_NOTCH,
  "a notch moves a notch's worth, whatever that is set to")
assert.strictEqual(model.WHEEL_PIXELS_PER_NOTCH, 120,
  "and it is three lines of text, which is what a GTK application moves")

let fractionalDistance = 0
for (let sampleIndex = 0; sampleIndex < 8; sampleIndex++) fractionalDistance += model.wheelDistance(-NOTCH / 8)
assert.strictEqual(fractionalDistance, -120, "eight fractions of a notch are still one notch")

assert.strictEqual(model.wheelDistance(-3 * NOTCH), -360, "three notches")
assert.strictEqual(model.wheelDistance(0), 0)
assert.strictEqual(model.wheelDistance(null), 0)

// Invariant: Capping each wheel event would make equal rotations travel different distances.
assert.strictEqual(model.wheelDistance(-10 * NOTCH), -1200)
let separateNotchDistance = 0
for (let sampleIndex = 0; sampleIndex < 10; sampleIndex++) separateNotchDistance += model.wheelDistance(-NOTCH)
assert.strictEqual(separateNotchDistance, model.wheelDistance(-10 * NOTCH),
  "ten notches move the same distance however they arrive")

assert.strictEqual(model.wheelScrollTarget(0, -NOTCH, 5000, 300), 120)
assert.strictEqual(model.wheelScrollTarget(500, NOTCH, 5000, 300), 380)
assert.strictEqual(model.wheelScrollTarget(0, 2 * NOTCH, 5000, 300), 0,
  "there is nothing above the first row")
assert.strictEqual(model.wheelScrollTarget(4700, -2 * NOTCH, 5000, 300), 4700)
assert.strictEqual(model.wheelScrollTarget(0, -2 * NOTCH, 100, 300), 0,
  "content shorter than its view cannot scroll")

assert.strictEqual(model.wheelScrollTarget(-50, NOTCH, 5000, 300, 0, 50, 70), -50)
assert.strictEqual(model.wheelScrollTarget(-50, -NOTCH, 5000, 300, 0, 50, 70), 70)
assert.strictEqual(model.wheelScrollTarget(4770, -NOTCH, 5000, 300, 0, 50, 70), 4770,
  "and the bottom margin is reachable rather than cut off")

assert.strictEqual(model.wheelScrollTarget(-200, -NOTCH, 4200, 300, -200, 0, 0), -80)
assert.strictEqual(model.wheelScrollTarget(-200, NOTCH, 4200, 300, -200, 0, 0), -200,
  "and the header stays reachable")

// Invariant: Touchpad pixelDelta uses the same scroll sign and bounds as wheel rotation.
assert.strictEqual(model.wheelScrollByPixels(0, -40, 5000, 300), 40)
assert.strictEqual(model.wheelScrollByPixels(500, 40, 5000, 300), 460)
assert.strictEqual(model.wheelScrollByPixels(0, 40, 5000, 300), 0,
  "there is nothing above the first row")
assert.strictEqual(model.wheelScrollTarget(0, -NOTCH, 5000, 300),
  model.wheelScrollByPixels(0, model.wheelDistance(-NOTCH), 5000, 300),
  "a notch is the pixel helper fed a notch's worth")

assert.strictEqual(model.WHEEL_GAIN, 2)
assert.strictEqual(model.wheelPixels(-NOTCH, 0), -240,
  "a notch on screen is two GTK notches, which is what Chromium travels")
assert.strictEqual(model.wheelPixels(0, -40), -80,
  "a touchpad's pixels get the same gain")
assert.strictEqual(model.wheelPixels(-NOTCH, -40), -80,
  "pixelDelta wins when the device reports both")

deepEqual(model.labelChangesFor("unarchive", "Label_17"),
  { add: ["INBOX"], remove: ["Label_17"] })
deepEqual(model.labelChangesFor("unarchive"), { add: ["INBOX"], remove: [] })
deepEqual(model.labelChangesFor("unarchive", ""), { add: ["INBOX"], remove: [] })

// Invariant: Unarchive removes a source user label, never a system-state label.
deepEqual(model.labelChangesFor("unarchive", "INBOX"), { add: ["INBOX"], remove: [] })
deepEqual(model.labelChangesFor("unarchive", "CATEGORY_PERSONAL"),
  { add: ["INBOX"], remove: [] })
assert.strictEqual(model.isSystemLabelId("Label_17"), false)
assert.strictEqual(model.isSystemLabelId("IMPORTANT"), true)
assert.strictEqual(model.isSystemLabelId("CATEGORY_UPDATES"), true)

// Invariant: IMAP folder moves issue new message IDs; a row with the old ID cannot remain in the source view.
assert.strictEqual(model.survivesAction("archive", "unarchive", "", false), false,
  "a folder provider relocates, so the row cannot stay")
assert.strictEqual(model.survivesAction("all", "unarchive", "label:TODO", false), false)

assert.strictEqual(model.survivesAction("all", "unarchive", "", true), true)
assert.strictEqual(model.survivesAction("all", "unarchive", "label:TODO", true), false,
  "a label view with nothing naming its label cannot say the label stayed")

deepEqual(model.labelChangesFor("unarchive", "IMPORTANT").remove, [])
assert.strictEqual(
  model.survivesAction("all", "unarchive", "label:important", true, "IMPORTANT"), true,
  "the label stays, so the row stays")
deepEqual(model.labelChangesFor("unarchive", "Label_17").remove, ["Label_17"])
assert.strictEqual(
  model.survivesAction("all", "unarchive", "label:todo", true, "Label_17"), false,
  "the label comes off, so the row goes")

// Invariant: The third survivesAction argument remains a query string for existing callers.
assert.strictEqual(model.survivesAction("inbox", "archive", ""), false,
  "archive still leaves the inbox")
assert.strictEqual(model.survivesAction("all", "archive", ""), true)

const filed = { id: "m1", labelIds: ["Label_17", "IMPORTANT"], unread: false,
  starred: false, inInbox: false }
const moved = model.applyLabelChange(filed, "unarchive", "Label_17")
deepEqual(moved.labelIds, ["IMPORTANT", "INBOX"])
assert.strictEqual(moved.inInbox, true)
assert.strictEqual(filed.labelIds.indexOf("Label_17"), 0)

// Invariant: Every derived mailbox flag must follow its label membership after an optimistic action.
const reported = model.applyLabelChange(
  { id: "m2", labelIds: ["UNREAD", "INBOX"], inInbox: true, inSpam: false }, "spam")
deepEqual(reported.labelIds, ["UNREAD", "SPAM"])
assert.strictEqual(reported.inInbox, false)
assert.strictEqual(reported.inSpam, true, "the row is in Spam the moment it is reported")
const binned = model.applyLabelChange(
  { id: "m3", labelIds: ["Label_17"], isSent: true, isDraft: true, inTrash: true },
  "unarchive", "Label_17")
assert.strictEqual(binned.isSent, false)
assert.strictEqual(binned.isDraft, false)
assert.strictEqual(binned.inTrash, false)

assert.strictEqual(model.readingStatusLine(false, "me@example.org", "Synced 2 min ago"),
  "me@example.org · 2 min ago")
assert.strictEqual(model.readingStatusLine(false, "me@example.org", ""), "me@example.org")

// Invariant: A unified view cannot attribute one account's address or sync age to all mailboxes.
assert.strictEqual(model.readingStatusLine(true, "me@example.org", "Synced 2 min ago"),
  "All mailboxes")
assert.strictEqual(model.readingStatusLine(true, "", ""), "All mailboxes")

assert.strictEqual(model.UNIFIED_LABEL, "All mailboxes")

assert.strictEqual(model.readingStatusLine(false, "", ""), "Not connected")

assert.strictEqual(model.marksReadOnArrival({ unread: true }, false), true)
assert.strictEqual(model.marksReadOnArrival({ unread: true }, true), false,
  "stepping down a list would otherwise read every message it passed")
assert.strictEqual(model.marksReadOnArrival({ unread: false }, false), false)
assert.strictEqual(model.marksReadOnArrival(null, false), false)

// Invariant: Only explicit true denotes preview mode; omitted mode retains normal open semantics.
assert.strictEqual(model.marksReadOnArrival({ unread: true }, undefined), true)

// Invariant: A message preview never fetches remote images, even when ordinary opened messages may show them.
assert.strictEqual(model.showsRemoteImages(true, false), true)
assert.strictEqual(model.showsRemoteImages(true, true), false,
  "the standing answer is about a message somebody chose to read")
assert.strictEqual(model.showsRemoteImages(false, false), false)
assert.strictEqual(model.showsRemoteImages(false, true), false)

const dwelt = [{ id: "m1", unread: true }, { id: "m2", unread: false }]
assert.strictEqual(model.previewReadable(dwelt, "m1"), true)
assert.strictEqual(model.previewReadable(dwelt, "m2"), false, "already read")
assert.strictEqual(model.previewReadable(dwelt, "gone"), false,
  "a search or a mailbox switch takes the row out from under the dwell")
assert.strictEqual(model.previewReadable([], "m1"), false)
assert.strictEqual(model.previewReadable(dwelt, ""), false)

{
  const list = [{ id: "a", starred: true }, { id: "b" }, { id: "c", starred: true }, { id: "d" }]

  deepEqual(model.toggleId([], "b"), ["b"])
  deepEqual(model.toggleId(["b", "c"], "b"), ["c"])
  deepEqual(model.toggleId(["b"], ""), ["b"], "an empty id toggles nothing")

  deepEqual(model.idsBetween(list, "b", "d"), ["b", "c", "d"])
  deepEqual(model.idsBetween(list, "d", "b"), ["b", "c", "d"], "either direction")
  deepEqual(model.idsBetween(list, "", "c"), ["c"], "no anchor means the row itself")
  deepEqual(model.idsBetween(list, "zz", "yy"), [])
  deepEqual(model.unionIds(["a"], ["a", "c"]), ["a", "c"])

  deepEqual(model.toggleRange(["a"], list, "b", "d"), ["a", "b", "c", "d"],
    "an unchecked endpoint selects the range and keeps selections outside it")
  deepEqual(model.toggleRange(["a", "b", "c", "d"], list, "d", "b"), ["a"],
    "a checked endpoint clears the range in either direction")
  deepEqual(model.toggleRange(["b", "d"], list, "b", "d"), [],
    "a checked endpoint clears a mixed range instead of inverting its gaps")
  deepEqual(model.toggleRange(["a"], list, "", "a"), [],
    "without an anchor the endpoint can still be unchecked")
  deepEqual(model.toggleRange(["a"], list, "a", "gone"), ["a"],
    "an endpoint removed from the list leaves selection alone")

  deepEqual(model.retainIds(["a", "gone", "c"], list), ["a", "c"])
  deepEqual(model.allIds(list), ["a", "b", "c", "d"])
  deepEqual(model.summariesById(list, ["c", "nope", "a"]), [list[2], list[0]])

  // Invariant: Batch removal advances past every departing row before choosing a surviving cursor.
  assert.strictEqual(model.cursorAfterRemovals(list, ["b", "c"], "b"), "d")
  assert.strictEqual(model.cursorAfterRemovals(list, ["c", "d"], "c"), "b")
  assert.strictEqual(model.cursorAfterRemovals(list, ["a", "b", "c", "d"], "b"), "")
  assert.strictEqual(model.cursorAfterRemovals(list, ["a"], "b"), "b", "a cursor off the selection stays")
  assert.strictEqual(model.cursorAfterRemovals(list, ["a"], "nope"), "")

  assert.strictEqual(model.starActionFor([list[0], list[2]]), "unstar")
  assert.strictEqual(model.starActionFor([list[0], list[1]]), "star", "a mixed selection stars")
  assert.strictEqual(model.starActionFor([]), "star")

  assert.strictEqual(model.batchNote(3, "Archived"), "3 messages archived")
  assert.strictEqual(model.batchNote(1, "Moved to Todo"), "1 message moved to Todo")
  assert.strictEqual(model.selectionStatus(0), "")
  assert.strictEqual(model.selectionStatus(2), "2 selected")
}

{
  const before = [{ id: "a" }, { id: "b" }, { id: "c" }, { id: "d" }]
  const afterAction = [{ id: "a" }, { id: "d" }]
  deepEqual(model.restoreRows(afterAction, before, ["c"]).map(function (r) { return r.id }), ["a", "c", "d"])
  deepEqual(model.restoreRows(afterAction, before, ["b", "c"]).map(function (r) { return r.id }), ["a", "b", "c", "d"])
  deepEqual(model.restoreRows([{ id: "a" }], before, ["d"]).map(function (r) { return r.id }), ["a", "d"], "no later row left means the end")
  deepEqual(model.restoreRows([{ id: "a", unread: false }], [{ id: "a", unread: true }], ["a"]), [{ id: "a", unread: true }],
    "a row still listed is put back as it was")
  deepEqual(model.restoreRows(afterAction, before, []).map(function (r) { return r.id }), ["a", "d"])
  assert.strictEqual(model.batchFailureNote(5, 2, "Moved to trash", "server said no"), "2 of 5 could not be moved to trash: server said no")
  assert.strictEqual(model.batchFailureNote(3, 1, "Archived", ""), "1 of 3 could not be archived")
}

{
  const labels = [
    { id: "INBOX", name: "INBOX", system: true },
    { id: "Archive/2025", name: "Archive/2025", rawName: "Archive/2025", delimiter: "/", unread: 2 },
    { id: "Archive", name: "Archive", rawName: "Archive", delimiter: "/", unread: 1 },
    { id: "Archive/2026/Q1", name: "Archive/2026/Q1", rawName: "Archive/2026/Q1", delimiter: "/", unread: 4 },
    { id: "Receipts", name: "Receipts", rawName: "Receipts", delimiter: "/", unread: 0 },
    { id: "Label_3", name: "todo", rawName: "todo", unread: 1 }]

  const open = model.labelTree(labels, [])
  deepEqual(open.map(function (r) { return [r.path, r.depth, r.selectable, r.hasChildren, r.unread] }), [
    ["Archive", 0, true, true, 1],
    ["Archive/2025", 1, true, false, 2],
    ["Archive/2026", 1, false, true, 0],
    ["Archive/2026/Q1", 2, true, false, 4],
    ["Receipts", 0, true, false, 0],
    ["todo", 0, true, false, 1]],
    "children hang under parents, a missing ancestor is a row of its own, siblings sort by name")
  assert.strictEqual(open[0].name, "Archive")
  assert.strictEqual(open[3].name, "Q1", "a row shows its own segment")
  assert.strictEqual(open[3].id, "Archive/2026/Q1", "and keeps the whole id")

  const folded = model.labelTree(labels, ["Archive"])
  deepEqual(folded.map(function (r) { return r.path }), ["Archive", "Receipts", "todo"])
  assert.strictEqual(folded[0].expanded, false)
  assert.strictEqual(folded[0].unread, 7, "a folded parent counts its subtree")

  const partly = model.labelTree(labels, ["Archive/2026"])
  deepEqual(partly.map(function (r) { return r.path }), ["Archive", "Archive/2025", "Archive/2026", "Receipts", "todo"])
  assert.strictEqual(partly[2].unread, 4)

  const dotted = model.labelTree([
    { id: "a.b", name: "a.b", delimiter: "." }, { id: "a", name: "a", delimiter: "." },
    { id: "x/y", name: "x/y" }], [])
  deepEqual(dotted.map(function (r) { return [r.path, r.depth] }), [["a", 0], ["a.b", 1], ["x", 0], ["x/y", 1]])

  deepEqual(model.visibleLabels(labels, ["Archive"]).map(function (l) { return l.id }),
    ["Archive", "Receipts", "Label_3"], "the digits follow what is on screen")
  deepEqual(model.visibleLabels(labels, []).map(function (l) { return l.id }),
    ["Archive", "Archive/2025", "Archive/2026/Q1", "Receipts", "Label_3"])
  deepEqual(model.togglePath(["Archive"], "Archive"), [])
  deepEqual(model.togglePath([], "Archive/2026"), ["Archive/2026"])
  deepEqual(model.labelTree(null, null), [])
  // Invariant: Object-prototype names are ordinary sender-controlled label names.
  const odd = model.labelTree([{ id: "constructor", name: "constructor" },
    { id: "constructor/2026", name: "constructor/2026" }, { id: "__proto__", name: "__proto__" },
    { id: "toString", name: "toString" }], [])
  deepEqual(odd.map(function (r) { return r.path }), ["__proto__", "constructor", "constructor/2026", "toString"])

  // Invariant: Absent hierarchy delimiter defaults to slash; an explicitly empty delimiter means a flat namespace.
  assert.strictEqual(model.labelDelimiter({ delimiter: "." }), ".")
  assert.strictEqual(model.labelDelimiter({ delimiter: "/" }), "/")
  assert.strictEqual(model.labelDelimiter({ name: "todo" }), "/")
  assert.strictEqual(model.labelDelimiter(null), "/")
  assert.strictEqual(model.labelDelimiter({ delimiter: "" }), "")
  const flat = model.labelTree([
    { id: "a/b", name: "a/b", rawName: "a/b", delimiter: "" },
    { id: "a", name: "a", rawName: "a", delimiter: "" },
    { id: "x.y", name: "x.y", rawName: "x.y", delimiter: "" }], [])
  deepEqual(flat.map(function (r) { return [r.path, r.depth, r.hasChildren, r.selectable] }),
    [["a", 0, false, true], ["a/b", 0, false, true], ["x.y", 0, false, true]],
    "a NIL delimiter makes a flat list, slashes and all")
  deepEqual(model.visibleLabels([{ id: "a/b", name: "a/b", delimiter: "" }, { id: "a", name: "a", delimiter: "" }], ["a"])
    .map(function (l) { return l.id }), ["a", "a/b"], "and nothing folds under anything")
  const slashed = model.labelTree([{ id: "a.b", name: "a.b", delimiter: "/" }, { id: "a", name: "a", delimiter: "/" }], [])
  deepEqual(slashed.map(function (r) { return [r.path, r.depth] }), [["a", 0], ["a.b", 0]],
    "a slash server does not nest on a dot")
}

// Invariant: Hydration rebuilds summary objects, so cache-first repaint decisions compare values rather than references.
function summaryRows() {
  return [
    { id: "m1", subject: "One", unread: true, from: { email: "a@x", display: "A" },
      to: [{ name: "Me", email: "me@x", display: "Me" }],
      thread: { id: "t1", count: 2, memberIds: ["m1", "m0"] }, date: new Date(3000) },
    { id: "m2", subject: "Two", unread: false, from: { email: "b@x", display: "B" },
      to: [], thread: { id: "t2", count: 0, memberIds: [] }, date: new Date(2000) }
  ]
}

const painted = summaryRows()
assert.strictEqual(model.sameSummaries(painted, summaryRows()), true,
  "rebuilt rows carrying the same values are the same list")
assert.strictEqual(model.sameSummaries(painted, painted), true)
assert.strictEqual(model.sameSummaries([], []), true)
assert.strictEqual(model.sameSummaries(null, undefined), true, "neither list has rows")

const markedRead = summaryRows()
markedRead[0].unread = false
assert.strictEqual(model.sameSummaries(painted, markedRead), false, "a row was read")

const renamed = summaryRows()
renamed[0].from.display = "Someone else"
assert.strictEqual(model.sameSummaries(painted, renamed), false,
  "a nested field is still a field")

const addressed = summaryRows()
addressed[0].to[0].email = "someone@else"
assert.strictEqual(model.sameSummaries(painted, addressed), false,
  "a recipient's own field, two levels down")

const grown = summaryRows()
grown[0].to.push({ email: "cc@x" })
assert.strictEqual(model.sameSummaries(painted, grown), false, "a recipient arrived")

const answered = summaryRows()
answered[0].thread.memberIds.push("m3")
assert.strictEqual(model.sameSummaries(painted, answered), false,
  "a conversation gained a member, three levels down")

const tagged = summaryRows()
tagged[0].pinned = true
assert.strictEqual(model.sameSummaries(painted, tagged), false, "a field appeared")

const reordered = summaryRows()
reordered.reverse()
assert.strictEqual(model.sameSummaries(painted, reordered), false,
  "the same rows in another order are another list")

assert.strictEqual(model.sameSummaries([{ id: "m", date: new Date(1000) }],
  [{ id: "m", date: new Date(1000) }]), true)
assert.strictEqual(model.sameSummaries([{ id: "m", date: new Date(1000) }],
  [{ id: "m", date: new Date(2000) }]), false)
assert.strictEqual(model.sameSummaries([{ id: "m", date: new Date(1000) }],
  [{ id: "m", date: null }]), false, "a row that lost its date changed")

// Invariant: JSON caching drops undefined fields; summary equality must treat absent and undefined keys symmetrically.
const withUndefined = [{ id: "m1", subject: "One", snippet: undefined }]
const withoutKey = [{ id: "m1", subject: "One" }]
assert.strictEqual(model.sameSummaries(withUndefined, withoutKey), true,
  "a key the cache drops is not a change")
assert.strictEqual(model.sameSummaries(withoutKey, withUndefined), true,
  "and it is not a change the other way round either")

const withValue = [{ id: "m1", subject: "One", snippet: "new" }]
assert.strictEqual(model.sameSummaries(withValue, withoutKey), false)
assert.strictEqual(model.sameSummaries(withoutKey, withValue), false,
  "a field that arrived is a change read from either side")

assert.strictEqual(model.sameSummaries(painted, [painted[0]]), false)
assert.strictEqual(model.sameSummaries([painted[0]], painted), false)

// Invariant: At the comparison depth bound, uncertain equality means changed so mail updates remain visible.
const deep = { id: "m", a: { b: { c: { d: { e: 1 } } } } }
const alsoDeep = { id: "m", a: { b: { c: { d: { e: 1 } } } } }
assert.strictEqual(model.sameSummaries([deep], [alsoDeep]), false,
  "the comparison stops rather than following an unbounded structure")

// Invariant: Reload preserves the depth already reached by pagination, within the provider request bound.
assert.strictEqual(model.reloadLimit(25, 0), 25)
assert.strictEqual(model.reloadLimit(25, 25), 25)
assert.strictEqual(model.reloadLimit(25, 50), 50, "two pages in, two pages back")
assert.strictEqual(model.reloadLimit(25, 63), 63,
  "rows trashed since do not round the depth down to a page")
assert.strictEqual(model.reloadLimit(50, 150), 100, "bounded by the IMAP window")
assert.strictEqual(model.reloadLimit(100, 300), 100)
assert.strictEqual(model.reloadLimit(25, -5), 25)
assert.strictEqual(model.reloadLimit(25, "nonsense"), 25)
assert.strictEqual(model.reloadLimit(0, 40), 40, "a page of nothing still asks for what was shown")
assert.strictEqual(model.reloadLimit(null, null), 1)

const adaT1 = { accountId: "ada@example.org", thread: { id: "t1" }, mailboxKey: "inbox" }
assert.strictEqual(model.projectionKey(adaT1), JSON.stringify(["ada@example.org", "t1", "inbox"]))
assert.strictEqual(model.projectionKey({ accountId: "ada@example.org", thread: { id: "t1" }, mailboxKey: "archive" }),
  JSON.stringify(["ada@example.org", "t1", "archive"]),
  "the same thread viewed from another mailbox is another rail")
// Invariant: Projection identity includes account, thread and mailbox as separate tuple fields.
const bobT1 = { accountId: "bob@example.net", thread: { id: "t1" }, mailboxKey: "inbox" }
assert.strictEqual(model.projectionKey(bobT1), JSON.stringify(["bob@example.net", "t1", "inbox"]))
assert.notStrictEqual(model.projectionKey(adaT1), model.projectionKey(bobT1),
  "the same thread id in another account is another rail")
assert.notStrictEqual(model.projectionKey({ accountId: "a", thread: { id: "b\nc" }, mailboxKey: "d" }),
  model.projectionKey({ accountId: "a\nb", thread: { id: "c" }, mailboxKey: "d" }),
  "and no id can run into the part beside it, whatever characters it carries")
assert.strictEqual(model.projectionKey({ accountId: "ada@example.org", thread: null, mailboxKey: "inbox" }),
  JSON.stringify(["ada@example.org", "", "inbox"]),
  "a message outside any thread has no thread in its key")
assert.strictEqual(model.projectionKey({ thread: { id: "t1" }, mailboxKey: "inbox" }),
  JSON.stringify(["", "t1", "inbox"]), "a source naming no account is keyed without one")
assert.strictEqual(model.projectionKey(null), JSON.stringify(["", "", ""]))
assert.strictEqual(model.projectionKey({ accountId: "ada@example.org", thread: "t1" }),
  JSON.stringify(["ada@example.org", "", ""]), "a thread that is not an object names nothing")

const drawn = { showsRail: true, stops: [{ id: "a" }, { id: "b" }], caption: "2 messages",
  navigation: { a: { next: "b" } }, memberIds: ["a", "b"], first: "b", last: "a" }
deepEqual(model.pendingProjection(drawn, true),
  { showsRail: true, stops: [{ id: "a" }, { id: "b" }], caption: "2 messages", navigation: {}, memberIds: ["a", "b"],
    first: "", last: "" },
  "the same rail keeps its stops and caption and loses the ways along it: the navigation, and the ends the keys fall back to")
assert.notStrictEqual(model.pendingProjection(drawn, true), drawn, "as a new object, so the view notices")
deepEqual(drawn.navigation, { a: { next: "b" } }, "and the one in hand is not written to")
assert.strictEqual(drawn.first, "b")
deepEqual(model.pendingProjection(drawn, false),
  { showsRail: false, stops: [], caption: "", navigation: {}, memberIds: [] },
  "a different rail starts from nothing")
deepEqual(model.pendingProjection(null, true), { showsRail: false, stops: [], caption: "", navigation: {}, memberIds: [] })
{
  const one = model.pendingProjection(null, false)
  const other = model.pendingProjection(null, false)
  assert.notStrictEqual(one, other, "a blank is a fresh object each time")
  assert.notStrictEqual(one.stops, other.stops, "down to its lists")
  assert.notStrictEqual(one.navigation, other.navigation)
  assert.notStrictEqual(one.memberIds, other.memberIds)
}

assert.strictEqual(model.activityStatus({}), "", "nothing in flight says nothing")
assert.strictEqual(model.activityStatus({ sending: 1 }), "Sending")
assert.strictEqual(model.activityStatus({ sending: 2, queuedSends: 3 }), "Sending 2 \u00b7 3 queued to send")
assert.strictEqual(model.activityStatus({ running: 1, waiting: 4 }), "1 action running \u00b7 4 waiting")
assert.strictEqual(model.activityStatus({ sending: "x", waiting: -2 }), "", "nonsense counts are zero")

{
  assert.strictEqual(model.labelLeaf("Archive/2026/Q1", "/"), "Q1")
  assert.strictEqual(model.labelLeaf("Receipts", "/"), "Receipts")
  assert.strictEqual(model.labelParent("Archive/2026/Q1", "/"), "Archive/2026")
  assert.strictEqual(model.labelParent("Receipts", "/"), "")
  assert.strictEqual(model.labelPathJoin("Archive", " 2026 ", "/"), "Archive/2026")
  assert.strictEqual(model.labelPathJoin("", "Receipts", "/"), "Receipts")
  assert.strictEqual(model.labelPathJoin("a", "b", "."), "a.b")
  assert.strictEqual(model.labelDelimiter({ delimiter: "." }), ".")
  assert.strictEqual(model.labelDelimiter({}), "/")
  assert.strictEqual(model.labelNameProblem("  ", "/"), "A label needs a name")
  assert.strictEqual(model.labelNameProblem("a/b", "/").indexOf("cannot contain /") > 0, true)
  assert.strictEqual(model.labelNameProblem("Receipts", "/"), "")

  const labels = [
    { id: "INBOX", name: "INBOX", system: true },
    { id: "Archive", rawName: "Archive" },
    { id: "Archive/2026", rawName: "Archive/2026" },
    { id: "Archive/2026/Q1", rawName: "Archive/2026/Q1" },
    { id: "Receipts", rawName: "Receipts" }]
  deepEqual(model.labelMoveTargets(labels, "Archive/2026", "/").map(function (t) { return t.path }),
    ["", "Receipts"], "not itself, not its children, not its current parent, never a system label")
  deepEqual(model.labelMoveTargets(labels, "Receipts", "/").map(function (t) { return t.path }),
    ["", "Archive", "Archive/2026", "Archive/2026/Q1"])
  assert.strictEqual(model.labelMoveTargets(labels, "Receipts", "/")[0].name, "Top level")
}

assert.strictEqual(model.monitoredNote([{ name: "Receipts", delta: 3 }]), "3 new in Receipts")
assert.strictEqual(model.monitoredNote([{ name: "A", delta: 1 }, { name: "B", delta: 4 }, { name: "C", delta: 2 }]),
  "4 new in B, 2 new in C and 1 more")
assert.strictEqual(model.monitoredNote([]), "")

{
  // Invariant: An explicitly empty hierarchy delimiter makes slashes and dots ordinary name characters.
  assert.strictEqual(model.labelLeaf("a/b", ""), "a/b")
  assert.strictEqual(model.labelParent("a/b", ""), "")
  assert.strictEqual(model.labelPathJoin("", "a/b", ""), "a/b")
  assert.strictEqual(model.labelNameProblem("a/b", ""), "", "a slash is only a slash")
  assert.ok(model.labelNameProblem("a/b", "/").indexOf("cannot contain /") >= 0)
  assert.strictEqual(model.labelNestProblem("", ""), "")
  assert.strictEqual(model.labelNestProblem("Work", "/"), "")
  assert.ok(model.labelNestProblem("Work", "").indexOf("flat list") >= 0)
  deepEqual(model.labelMoveTargets([{ id: "a", name: "a" }, { id: "b", name: "b" }], "a", ""),
    [{ id: "", name: "Top level", path: "" }], "nowhere to move to but where it is")
  assert.strictEqual(model.labelLeaf("a.b", "."), "b")
  assert.strictEqual(model.labelParent("a.b", "."), "a")
  assert.strictEqual(model.labelLeaf("a.b", undefined), "a.b", "no word from the provider means a slash")
  assert.strictEqual(model.labelPathJoin("a", "b", undefined), "a/b")
}

{
  // Invariant: IMAP folder renames change descendant wire IDs; watches follow the fresh listing at the renamed path.
  const before = [
    { id: "Work", name: "Work", delimiter: "/" }, { id: "Work/2026", name: "Work/2026", delimiter: "/" },
    { id: "Work/2026/Q1", name: "Work/2026/Q1", delimiter: "/" }, { id: "Receipts", name: "Receipts", delimiter: "/" }]
  const after = [
    { id: "Jobs", name: "Jobs", delimiter: "/" }, { id: "Jobs/2026", name: "Jobs/2026", delimiter: "/" },
    { id: "Jobs/2026/Q1", name: "Jobs/2026/Q1", delimiter: "/" }, { id: "Receipts", name: "Receipts", delimiter: "/" }]
  deepEqual(model.migrateMonitoredIds(["Work", "Receipts", "Work/2026/Q1"], before, after, "Work", "Jobs", "/"),
    ["Jobs", "Receipts", "Jobs/2026/Q1"])
  deepEqual(model.migrateMonitoredIds(["Work/2026"], before, after, "Work", "Jobs", "/"), ["Jobs/2026"])

  const moved = [
    { id: "Archive", name: "Archive", delimiter: "/" }, { id: "Archive/Work", name: "Archive/Work", delimiter: "/" },
    { id: "Archive/Work/2026", name: "Archive/Work/2026", delimiter: "/" }, { id: "Receipts", name: "Receipts", delimiter: "/" }]
  deepEqual(model.migrateMonitoredIds(["Work/2026", "Receipts"], before, moved, "Work", "Archive/Work", "/"),
    ["Archive/Work/2026", "Receipts"])

  const gone = [{ id: "Receipts", name: "Receipts", delimiter: "/" }]
  deepEqual(model.migrateMonitoredIds(["Work", "Work/2026", "Receipts"], before, gone, "Work", "", "/"), ["Receipts"])
  // Invariant: Gmail label IDs survive renames; unaffected watch lists preserve their original array identity.
  const same = ["Receipts"]
  assert.strictEqual(model.migrateMonitoredIds(same, before, after, "Work", "Jobs", "/"), same)
  const gmail = [{ id: "Label_1", name: "Work" }, { id: "Label_2", name: "Work/2026" }]
  const gmailAfter = [{ id: "Label_1", name: "Jobs" }, { id: "Label_2", name: "Jobs/2026" }]
  const kept = ["Label_2"]
  assert.strictEqual(model.migrateMonitoredIds(kept, gmail, gmailAfter, "Work", "Jobs", "/"), kept)

  const flatBefore = [{ id: "Work", name: "Work", delimiter: "" }, { id: "Work/2026", name: "Work/2026", delimiter: "" }]
  const flatAfter = [{ id: "Jobs", name: "Jobs", delimiter: "" }, { id: "Work/2026", name: "Work/2026", delimiter: "" }]
  deepEqual(model.migrateMonitoredIds(["Work", "Work/2026"], flatBefore, flatAfter, "Work", "Jobs", ""), ["Jobs", "Work/2026"])
  deepEqual(model.migrateMonitoredIds(null, before, after, "Work", "Jobs", "/"), [])
}

// Invariant: A queued rename chain resolves watched IDs against the final listing only.
{
  const old = [{id: "Work", name: "Work"}, {id: "Receipts", name: "Receipts"}]
  const moves = [
    {before: old, oldPath: "Work", newPath: "Jobs", delimiter: "/"},
    {before: old, oldPath: "Receipts", newPath: "Bills", delimiter: "/"},
    {before: [{id: "Jobs", name: "Jobs"}], oldPath: "Jobs", newPath: "Tasks", delimiter: "/"}
  ]
  deepEqual(model.migrateMonitoredChanges(["Work", "Receipts"], moves,
    [{id: "Tasks", name: "Tasks"}, {id: "Bills", name: "Bills"}]), ["Tasks", "Bills"])
}

{
  assert.ok(model.fuzzyScore("sfl", "SFL") > 0)
  assert.ok(model.fuzzyScore("sfl", "jack@the-sfl.com") > 0)
  assert.ok(model.fuzzyScore("sfl", "jack@example.com") === 0)
  assert.ok(model.fuzzyScore("wk", "Work") > 0, "letters in order, not adjacent")
  assert.ok(model.fuzzyScore("kw", "Work") === 0, "but in order")
  assert.ok(model.fuzzyScore("work", "Work") > model.fuzzyScore("work", "Homework"), "the start of the text beats the middle")
  assert.ok(model.fuzzyScore("inv", "Work/Invoices") > model.fuzzyScore("inv", "Convinced"), "the start of a word beats the middle of one")
  assert.strictEqual(model.fuzzyScore("", "anything"), 1)
  assert.strictEqual(model.fuzzyScore("a", ""), 0)

  const rows = [
    { name: "Inbox", key: "inbox" },
    { name: "Work", id: "Work" },
    { name: "Work/Invoices", id: "Work/Invoices" },
    { label: "SFL", email: "jack@the-sfl.com", name: "" },
    { label: "jack", email: "jack@icloud.com", name: "jack" }]
  deepEqual(model.filterRows(rows, "").map(r => r.sourceIndex), [0, 1, 2, 3, 4], "nothing typed keeps every row in place")
  deepEqual(model.filterRows(rows, "inv").map(r => r.sourceIndex), [2])
  deepEqual(model.filterRows(rows, "work").map(r => r.sourceIndex), [1, 2], "the shorter name first, then its child")
  deepEqual(model.filterRows(rows, "sfl").map(r => r.sourceIndex), [3], "an address is searched too")
  deepEqual(model.filterRows(rows, "jack").map(r => r.sourceIndex), [4, 3], "the name outranks an address that only contains it")
  deepEqual(model.filterRows(rows, "zzz"), [])
  deepEqual(model.filterRows(null, "x"), [])
  assert.strictEqual(model.filterRows(rows, "  ").length, 5, "blank is nothing typed")
  assert.strictEqual(model.filterRows(rows, "inv")[0].index, undefined, "no `index` on a row: a Repeater owns that word")
  assert.strictEqual(rows[2].sourceIndex, undefined, "the rows given are not written on")
}

{
  const labels = [
    { id: "INBOX", name: "INBOX", system: true },
    { id: "Work/2026", name: "Work/2026", rawName: "Work/2026", delimiter: "/" },
    { id: "Receipts", name: "Receipts", rawName: "Receipts", delimiter: "/" },
    { id: "Work", name: "Work", rawName: "Work", delimiter: "/" },
    { id: "Work/Invoices", name: "Work/Invoices", rawName: "Work/Invoices", delimiter: "/" }]

  deepEqual(model.movableLabels(labels, "", "").map(l => [l.id, l.depth, l.leaf]),
    [["Receipts", 0, "Receipts"], ["Work", 0, "Work"], ["Work/2026", 1, "2026"], ["Work/Invoices", 1, "Invoices"]])
  deepEqual(model.movableLabels(labels, "", "Work").map(l => l.id), ["Receipts", "Work/2026", "Work/Invoices"],
    "the label the list is in is not a destination")

  deepEqual(model.movableLabels(labels, "inv", "").map(l => [l.id, l.depth, l.leaf]), [["Work/Invoices", 0, "Work/Invoices"]])
  deepEqual(model.movableLabels(labels, "wk", "").map(l => l.id), ["Work", "Work/2026", "Work/Invoices"], "letters in order find the whole family")
  deepEqual(model.movableLabels(labels, "zzz", ""), [])
  deepEqual(model.movableLabels(null, "", ""), [])
  assert.strictEqual(labels[1].depth, undefined, "the labels given are not written on")
}

deepEqual(model.unavailableActions({ archive: true, star: true, move: true }), [])
deepEqual(model.unavailableActions({ archive: true, star: true }), ["move"])

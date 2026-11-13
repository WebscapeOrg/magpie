const assert = require("assert")
const { load, deepEqual } = require("./load")

const cache = load("cache/Cache.js")

const NOW = 1755600000000

function summary(id, ms, extra) {
  return Object.assign({
    id: id,
    threadId: "t" + id,
    from: { name: "张伟", email: "wei@example.cn", display: "张伟" },
    subject: "发票 — 2026 年 8 月",
    snippet: "您好，附件是本月的服务发票",
    date: new Date(ms),
    time: "10m",
    fullTime: "Aug 19, 2026 10:24",
    unread: true,
    starred: false,
    labelIds: ["INBOX", "UNREAD"]
  }, extra || {})
}


deepEqual(cache.emptyStore(), {
  version: cache.VERSION, account: "", profile: null, labels: [], queries: {}
})


const dehydrated = cache.dehydrate([summary("m1", NOW - 600000)])
assert.strictEqual(dehydrated[0].dateMs, NOW - 600000)
assert.strictEqual(dehydrated[0].date, undefined, "the Date object does not go to disk")
assert.strictEqual(JSON.parse(JSON.stringify(dehydrated))[0].dateMs, NOW - 600000)

const rehydrated = cache.hydrate(dehydrated)
assert.strictEqual(typeof rehydrated[0].date.getTime, "function", "a real Date comes back")
assert.strictEqual(rehydrated[0].date.getTime(), NOW - 600000)
assert.strictEqual(rehydrated[0].subject, "发票 — 2026 年 8 月")
assert.strictEqual(rehydrated[0].dateMs, undefined)

const undated = cache.hydrate(cache.dehydrate([summary("m2", NaN)]))
assert.strictEqual(undated[0].date, null)
deepEqual(cache.hydrate(null), [])
deepEqual(cache.dehydrate(null), [])

const conversation = summary("m3", NOW - 60000)
conversation.thread = { id: "d", count: 3, unread: true, flagged: false,
  memberIds: ["maaaaad", "maaaaae", "maaaaaf"] }
deepEqual(cache.hydrate(JSON.parse(JSON.stringify(
  cache.dehydrate([conversation]))))[0].thread, conversation.thread)


assert.strictEqual(cache.queryKey("in:inbox", 25), "in:inbox|25")
assert.strictEqual(cache.queryKey("  in:inbox  ", 25), "in:inbox|25")
assert.strictEqual(cache.queryKey("", 25), "|25")
assert.strictEqual(cache.queryFromKey("in:inbox|25"), "in:inbox")
assert.strictEqual(cache.queryFromKey("a|query|100"), "a|query")
assert.notStrictEqual(cache.queryKey("in:inbox", 25), cache.queryKey("in:inbox", 50))


let store = cache.emptyStore()
store = cache.putQuery(store, "in:inbox|25", {
  summaries: [summary("m1", NOW - 600000)],
  estimate: 87,
  nextPageToken: "PAGE2"
}, NOW)

const got = cache.getQuery(store, "in:inbox|25")
assert.strictEqual(got.estimate, 87)
assert.strictEqual(got.nextPageToken, "PAGE2")
assert.strictEqual(got.at, NOW)
assert.strictEqual(cache.hydrate(got.summaries)[0].id, "m1")
assert.strictEqual(cache.getQuery(store, "nothing|25"), null)
assert.strictEqual(cache.getQuery(cache.emptyStore(), "in:inbox|25"), null)

store = cache.putQuery(store, "in:inbox|25", { summaries: [], estimate: 0, nextPageToken: "" }, NOW + 1)
assert.strictEqual(cache.getQuery(store, "in:inbox|25").summaries.length, 0)
assert.strictEqual(Object.keys(store.queries).length, 1)

let searchable = cache.emptyStore()
searchable = cache.putQuery(searchable, "in:inbox|25", {
  summaries: [
    summary("older", NOW - 2000, {
      from: { name: "Jane Doe", email: "jane@example.com", display: "Jane Doe" },
      subject: "Quarterly invoice",
      snippet: "Ready for review",
      to: [{ name: "Buyer", email: "buyer@example.org", display: "Buyer" }]
    }),
    summary("newer", NOW - 1000, { subject: "Invoice approved", snippet: "Jane signed it" })
  ],
  estimate: 2,
  nextPageToken: ""
}, NOW)
searchable = cache.putQuery(searchable, "is:unread|25", {
  summaries: [summary("older", NOW - 2000, {
    from: { name: "Jane Doe", email: "jane@example.com", display: "Jane Doe" },
    subject: "Quarterly invoice",
    snippet: "Ready for review",
    unread: false
  })],
  estimate: 1,
  nextPageToken: ""
}, NOW + 1)

deepEqual(cache.searchSummaries(searchable, "jane invoice").map(row => row.id),
  ["newer", "older"], "local results are deduplicated and newest first")
assert.strictEqual(cache.searchSummaries(searchable, "jane invoice")[1].unread, false,
  "the newest cached copy supplies the row")
deepEqual(cache.searchSummaries(searchable, "buyer@example.org").map(row => row.id), ["older"],
  "recipients are searchable too")
deepEqual(cache.searchSummaries(searchable, '"quarterly invoice"').map(row => row.id), ["older"])
deepEqual(cache.searchSummaries(searchable, "from:jane"), [],
  "provider operators are not guessed by the local fallback")
deepEqual(cache.searchSummaries(searchable, ""), [])

// Invariant: An older Inbox copy cannot resurrect a row whose newest cached copy moved to Trash.
let scoped = cache.emptyStore()
scoped = cache.putQuery(scoped, "in:inbox|25", {
  summaries: [summary("moved", NOW - 3000, { subject: "Scoped invoice" }),
    summary("kept", NOW - 2000, { subject: "Scoped invoice" })],
  estimate: 2,
  nextPageToken: ""
}, NOW)
scoped = cache.putQuery(scoped, "in:trash|25", {
  summaries: [summary("moved", NOW - 3000,
    { subject: "Scoped invoice", labelIds: ["TRASH"] })],
  estimate: 1,
  nextPageToken: ""
}, NOW + 1)
deepEqual(cache.searchSummaries(scoped, "scoped invoice", function(sourceQuery) {
  return sourceQuery !== "in:trash"
}).map(row => row.id), ["kept"], "an out-of-scope newest copy excludes the id")

// Invariant: Truncating cached rows also removes their stale continuation token.
const tooMany = []
for (let summaryIndex = 0; summaryIndex < cache.MAX_SUMMARIES_PER_QUERY + 5; summaryIndex++)
  tooMany.push(summary("cap-" + summaryIndex, NOW - summaryIndex))
let cappedStore = cache.putQuery(cache.emptyStore(), "in:anywhere|25", {
  summaries: tooMany,
  estimate: tooMany.length,
  nextPageToken: "after-omitted-rows"
}, NOW)
const cappedQuery = cache.getQuery(cappedStore, "in:anywhere|25")
assert.strictEqual(cappedQuery.summaries.length, cache.MAX_SUMMARIES_PER_QUERY)
assert.strictEqual(cappedQuery.nextPageToken, "")
assert.strictEqual(cappedQuery.estimate, tooMany.length)


let big = cache.emptyStore()
for (let queryIndex = 0; queryIndex < cache.MAX_QUERIES + 6; queryIndex++) {
  big = cache.putQuery(big, "q" + queryIndex + "|25",
    { summaries: [summary("m" + queryIndex, NOW)], estimate: 1, nextPageToken: "" }, NOW + queryIndex)
}
big = cache.prune(big)
assert.strictEqual(Object.keys(big.queries).length, cache.MAX_QUERIES)
assert.ok(cache.getQuery(big, "q0|25") === null, "the oldest goes first")
assert.ok(cache.getQuery(big, "q" + (cache.MAX_QUERIES + 5) + "|25") !== null, "the newest stays")

big.queries["oversized|25"] = {
  summaries: cache.dehydrate(tooMany), estimate: tooMany.length,
  nextPageToken: "unsafe", at: NOW + 100
}
big = cache.prune(big)
assert.strictEqual(big.queries["oversized|25"].summaries.length,
  cache.MAX_SUMMARIES_PER_QUERY)
assert.strictEqual(big.queries["oversized|25"].nextPageToken, "")



let owned = cache.putProfile(cache.emptyStore(), { email: "a@example.com" }, NOW)
owned = cache.putQuery(owned, "in:inbox|25", { summaries: [summary("m1", NOW)], estimate: 1, nextPageToken: "" }, NOW)

const same = cache.forAccount(owned, "a@example.com")
assert.strictEqual(cache.getQuery(same, "in:inbox|25") !== null, true)

const different = cache.forAccount(owned, "b@example.com")
assert.strictEqual(cache.getQuery(different, "in:inbox|25"), null, "a different account starts empty")
assert.strictEqual(different.account, "b@example.com")

assert.strictEqual(cache.getQuery(cache.forAccount(owned, ""), "in:inbox|25") !== null, true)

let unowned = cache.putQuery(cache.emptyStore(), "in:inbox|25",
  { summaries: [summary("m1", NOW)], estimate: 1, nextPageToken: "" }, NOW)
const adopted = cache.forAccount(unowned, "a@example.com")
assert.strictEqual(adopted.account, "a@example.com")
assert.strictEqual(cache.getQuery(adopted, "in:inbox|25") !== null, true,
  "an unclaimed cache belongs to whoever claims it")

const recased = cache.forAccount(owned, "A@Example.COM")
assert.strictEqual(cache.getQuery(recased, "in:inbox|25") !== null, true,
  "the same mailbox spelled differently is the same mailbox")


assert.strictEqual(cache.isStale(NOW, NOW + 1000, 60000), false)
assert.strictEqual(cache.isStale(NOW, NOW + 61000, 60000), true)
assert.strictEqual(cache.isStale(0, NOW, 60000), true)
assert.strictEqual(cache.isStale(null, NOW, 60000), true)
assert.strictEqual(cache.isStale(NOW + 999999, NOW, 60000), false)


const text = JSON.stringify(store)
const reloaded = JSON.parse(text)
assert.strictEqual(cache.getQuery(reloaded, "in:inbox|25").estimate, 0)
assert.strictEqual(reloaded.version, cache.VERSION)





const readRow = {
  id: "18f3a", subject: "Lunch", snippet: "Are you free",
  from: { name: "Jane", email: "jane@example.com" }, to: [], cc: [],
  date: new Date("2026-08-20T10:00:00Z"), time: "10:00", fullTime: "Aug 20, 2026 10:00",
  unread: false, starred: true, inInbox: true, labelIds: ["INBOX", "STARRED"]
}

const throughDisk = cache.hydrate(
  cache.getQuery(
    JSON.parse(JSON.stringify(
      cache.putQuery(cache.emptyStore(), "k",
        { summaries: [readRow], estimate: 1, nextPageToken: "" }, 1000))),
    "k").summaries)[0]

assert.strictEqual(throughDisk.unread, false, "a row read before the write stays read")
assert.strictEqual(throughDisk.starred, true)
deepEqual(throughDisk.labelIds, ["INBOX", "STARRED"])
assert.strictEqual(throughDisk.date.getTime(), readRow.date.getTime(),
  "and the date is a Date again, because relativeTime asks it for one")

const unreadRow = { id: "18f3b", date: new Date("2026-08-20T11:00:00Z"), unread: true }
assert.strictEqual(cache.hydrate(cache.dehydrate([unreadRow]))[0].unread, true)


console.log("test_cache.js ok")

const assert = require("node:assert/strict")
const { test } = require("node:test")
const vm = require("node:vm")
const { load } = require("./load")

test("provider oracle definitions use their own queries and capabilities", () => {
  const registry = load("tests/oracles/providers/Registry.js")
  const provider = registry.define({
    ID: "gmail", NATIVE_SYNC: false, CAPABILITIES: { labels: false },
    MAILBOXES: [{ key: "inbox", query: "fixture:inbox" }],
    webHomeUrl: function() { return "https://fixture.example/" }
  })
  assert.equal(provider.mailboxes[0].query, "fixture:inbox")
  assert.equal(provider.capabilities.labels, false)
  assert.equal(provider.nativeSync, false)
  assert.equal(provider.webHomeUrl(), "https://fixture.example/")
})

test("historical IMAP archive queries remain independent of current mailbox names", () => {
  const registry = load("tests/oracles/providers/Registry.js")
  for (const provider of ["imap", "outlook"]) {
    assert.equal(registry.query(provider, "archive", "", ""), "folder:\\Archive")
  }
})

test("conversation lookup does not invent summaries from the object prototype", () => {
  const conversation = load("tests/oracles/Conversation.js")
  assert.equal(conversation.summaryFor({}, "__proto__"), null)
  const summaries = Object.create({ inherited: { id: "inherited" } })
  assert.equal(conversation.summaryFor(summaries, "inherited"), null)
})

test("conversation merges retain literal prototype-like IDs without inherited rows", () => {
  const conversation = load("tests/oracles/Conversation.js")
  const existing = Object.create({ inherited: { id: "inherited" } })
  existing.kept = { id: "kept" }
  const additions = JSON.parse('{"__proto__":{"id":"__proto__"}}')
  const merged = conversation.mergedSummaries(existing, additions, 10, [])
  assert.deepEqual(Object.keys(merged).sort(), ["__proto__", "kept"])
  assert.equal(Object.getPrototypeOf(merged), null)
  assert.equal(merged.__proto__, additions.__proto__)
  assert.equal(Object.hasOwn(existing, "__proto__"), false)
  const retained = conversation.mergedSummaries(merged, {}, 1, ["__proto__"])
  assert.deepEqual(Object.keys(retained), ["__proto__"])
})

function messageJob(overrides) {
  return Object.assign({ id: "job", accountId: "account", messageId: "message", state: "done", created: 1 }, overrides)
}

test("job dictionaries retain prototype-like message IDs as own data", () => {
  const agent = load("tests/oracles/agent/Agent.js")
  const job = messageJob({ messageId: "__proto__" })
  const jobs = agent.jobsByMessage([job], "account")
  assert.deepEqual(Object.keys(jobs), ["__proto__"])
  assert.equal(Object.getPrototypeOf(jobs), null)
  assert.equal(jobs.__proto__, job)
})

test("attention dictionaries retain prototype-like message IDs", () => {
  const agent = load("tests/oracles/agent/Agent.js")
  const attention = agent.attentionByMessage([messageJob({ messageId: "__proto__" })], [], "account")
  assert.deepEqual(Object.keys(attention), ["__proto__"])
  assert.equal(Object.getPrototypeOf(attention), null)
  assert.equal(attention.__proto__, true)
})

test("completion transitions retain prototype-like job IDs", () => {
  const agent = load("tests/oracles/agent/Agent.js")
  const before = messageJob({ id: "__proto__", state: "running" })
  const after = Object.assign({}, before, { state: "done" })
  assert.deepEqual(Array.from(agent.newlyFinished([before], [after])), [after])
})

test("history dictionaries retain prototype-like conversation IDs", () => {
  const agent = load("tests/oracles/agent/Agent.js")
  const job = messageJob({ conversationId: "__proto__" })
  assert.deepEqual(Array.from(agent.historyFor([job], "account", ["message"], "")), [job])
})

test("history matches message sets without separator collisions", () => {
  const agent = load("tests/oracles/agent/Agent.js")
  const other = messageJob({ id: "other", messageId: "", messageIds: ["a", "b"] })
  const wanted = messageJob({ id: "wanted", messageId: "a\u001fb" })
  assert.deepEqual(Array.from(agent.historyFor([other, wanted], "account", ["a\u001fb"], "")), [wanted])
  assert.deepEqual(Array.from(agent.historyFor([other, wanted], "account", ["b", "a"], "")), [other])
  assert.deepEqual(Array.from(agent.historyFor([other, wanted], "another-account", ["b", "a"], "")), [])
  assert.deepEqual(Array.from(agent.historyFor([other, wanted], "account", [], "")), [])
})

test("sender identity tuples do not collide at embedded separators", () => {
  const senders = load("tests/oracles/Senders.js")
  const identities = senders.identities([
    { id: "account\nalias", ready: true, email: "mail@example.test" },
    { id: "account", ready: true, email: "alias\nmail@example.test" }
  ])
  assert.equal(identities.length, 2)
  assert.equal(identities[0].accountId, "account\nalias")
  assert.equal(identities[1].accountId, "account")
})

test("QML list normalization rejects non-finite lengths without looping", () => {
  const senders = load("tests/oracles/Senders.js")
  const result = vm.runInContext("asList({0: 'entry', length: Infinity})", senders, { timeout: 200 })
  assert.deepEqual(Array.from(result), [])
})

test("QML list normalization rejects fractional lengths", () => {
  const senders = load("tests/oracles/Senders.js")
  assert.deepEqual(Array.from(senders.asList({ 0: "entry", length: 1.5 })), [])
  assert.deepEqual(Array.from(senders.asList({ 0: "first", 1: "second", length: 2 })), ["first", "second"])
})

test("per-message job projections agree with the first active job lookup", () => {
  const agent = load("tests/oracles/agent/Agent.js")
  const jobs = [messageJob({ id: "new", state: "running", created: 2 }),
    messageJob({ id: "old", state: "queued", created: 1 })]
  assert.equal(agent.jobFor(jobs, "message", "account"), jobs[0])
  assert.equal(agent.jobsByMessage(jobs, "account").message, jobs[0])
  const finished = jobs.map(job => Object.assign({}, job, { state: "done" }))
  assert.equal(agent.jobsByMessage(finished.reverse(), "account").message.id, "new")
})

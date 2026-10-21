const assert = require("node:assert/strict")
const { test } = require("node:test")
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

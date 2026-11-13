const assert = require("node:assert/strict")
const { load, deepEqual } = require("./load")

const Status = load("bar/Status.js")
const now = 1763000000000

function status(overrides = {}) {
  return JSON.stringify({
    ready: true,
    windowOpen: false,
    showBarIcon: true,
    unreadTotal: 3,
    updated: now,
    ...overrides,
  })
}

const fresh = Status.snapshot(status(), now)
deepEqual(fresh, {
  ready: true,
  windowOpen: false,
  showBarIcon: true,
  unreadTotal: 3,
  updated: now,
})
assert.equal(Status.displayCount(fresh.unreadTotal), "3")
assert.equal(Status.tooltip(fresh, false), "Open Magpie Mail · 3 unread messages")

const boundary = Status.snapshot(status({ updated: now - 45000 }), now)
assert.equal(boundary.unreadTotal, 3)
assert.equal(Status.snapshot(status({ updated: now - 45001 }), now), null)
assert.equal(Status.snapshot(status({ updated: now + 5000 }), now).ready, true)
assert.equal(Status.snapshot(status({ updated: now + 5001 }), now), null)

for (const malformed of [
  "",
  "null",
  "[]",
  "{",
  status({ ready: "yes" }),
  status({ windowOpen: 1 }),
  status({ showBarIcon: null }),
  status({ unreadTotal: -1 }),
  status({ unreadTotal: 1.5 }),
  status({ unreadTotal: 1000001 }),
  status({ unreadTotal: "3" }),
  status({ updated: "now" }),
  status({ updated: -1 }),
]) {
  assert.equal(Status.snapshot(malformed, now), null, malformed)
}
assert.equal(Status.snapshot(" ".repeat(4097), now), null)
assert.equal(Status.snapshot(status(), Number.NaN), null)

const withPrivateFields = Status.snapshot(status({
  accountEmail: "private@example.test",
  subject: "private subject",
  token: "not-a-real-token",
}), now)
deepEqual(Object.keys(withPrivateFields).sort(), [
  "ready", "showBarIcon", "unreadTotal", "updated", "windowOpen",
])
assert.equal(JSON.stringify(withPrivateFields).includes("private"), false)

assert.equal(Status.displayCount(0), "")
assert.equal(Status.displayCount(1), "1")
assert.equal(Status.displayCount(999), "999")
assert.equal(Status.displayCount(1000), "999+")
assert.equal(Status.tooltip({ ready: true, unreadTotal: 0 }, false),
  "Open Magpie Mail · No unread mail")
assert.equal(Status.tooltip({ ready: true, unreadTotal: 1 }, false),
  "Open Magpie Mail · 1 unread message")
assert.equal(Status.tooltip(null, false), "Open Magpie Mail")
assert.equal(Status.tooltip(fresh, true), "Magpie Mail could not open. Click to try again.")

console.log("test_bar_status.js ok")

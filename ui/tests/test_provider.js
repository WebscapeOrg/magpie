const assert = require("assert")
const { load, deepEqual } = require("./load")
const provider = load("providers/Registry.js")

deepEqual(provider.ids(), ["gmail"])
assert.strictEqual(provider.get("gmail").name, "Gmail")
assert.strictEqual(provider.get("").id, "gmail")
for (const unsupported of ["imap", "jmap", "hey", "outlook", "unknown"]) {
  assert.strictEqual(provider.exists(unsupported), false)
  assert.throws(() => provider.get(unsupported), /Only Gmail/)
}
assert.strictEqual(provider.can("gmail", "threads"), true)
assert.strictEqual(provider.can("gmail", "conversations"), false)
for (const capability of ["archive", "spam", "star", "move", "labels", "send", "manageLabels"]) {
  assert.strictEqual(provider.can("gmail", capability), true)
  assert.strictEqual(provider.can("gmail", capability, {[capability]:""}), false)
  assert.strictEqual(provider.refusal("gmail", capability, {[capability]:"Account access refused"}), "Account access refused")
}
assert.strictEqual(provider.can("gmail", "unknown"), false)
assert.strictEqual(provider.mailboxFor("gmail", "all").query, "in:anywhere -in:spam -in:trash")
assert.strictEqual(provider.mailboxFor("gmail", "trash").query, "in:trash")
assert.strictEqual(provider.unreadQuery("gmail"), "in:inbox is:unread -category:promotions -category:social -category:forums")
assert.strictEqual(provider.mailboxes("gmail", ["spam"]).some(box => box.key === "spam"), false)
assert.strictEqual(provider.mailboxFor("gmail", "unknown").key, "inbox")
assert.strictEqual(provider.get("gmail").searchOperators.filter(value => value.primary).length, 10)
assert.strictEqual(provider.calendarAttendanceUrl("gmail", "me@company.example"), "https://calendar.google.com/calendar/u/0/r?authuser=me%40company.example")
assert.strictEqual(provider.webHomeUrl("gmail"), "https://mail.google.com/mail/u/0/")
assert.strictEqual(provider.logo("gmail"), "gmail.png")
console.log("Gmail provider ok")

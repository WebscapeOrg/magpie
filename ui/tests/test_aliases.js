const assert = require("assert")
const { load, deepEqual } = require("./load.js")

const aliases = load("account/Aliases.js")

deepEqual(aliases.parse("alias1@icloud.com, alias2@example.org"), [
  { email: "alias1@icloud.com", displayName: "", isPrimary: false, isDefault: false },
  { email: "alias2@example.org", displayName: "", isPrimary: false, isDefault: false }
])
deepEqual(aliases.parse("alias1@icloud.com (default), alias2@example.org"), [
  { email: "alias1@icloud.com", displayName: "", isPrimary: false, isDefault: true },
  { email: "alias2@example.org", displayName: "", isPrimary: false, isDefault: false }
])
deepEqual(aliases.parse("Work <alias1@icloud.com> (default), alias2@example.org"), [
  { email: "alias1@icloud.com", displayName: "Work", isPrimary: false, isDefault: true },
  { email: "alias2@example.org", displayName: "", isPrimary: false, isDefault: false }
])
deepEqual(aliases.parse(["alias@me.com", "not an email", "duplicate@me.com", "duplicate@me.com"]), [
  { email: "alias@me.com", displayName: "", isPrimary: false, isDefault: false },
  { email: "duplicate@me.com", displayName: "", isPrimary: false, isDefault: false }
])

deepEqual(
  aliases.parse("a@me.com (default), b@me.com (default)").map(row => row.isDefault),
  [true, false])

assert.strictEqual(aliases.format([
  { email: "a@icloud.com" },
  { email: "b@icloud.com" }
]), "a@icloud.com, b@icloud.com")
assert.strictEqual(aliases.format([
  { email: "a@icloud.com", isDefault: true },
  { email: "b@icloud.com", displayName: "Work" }
]), "a@icloud.com (default), Work <b@icloud.com>")

// Invariant: Opening settings reformats aliases; parse/format disagreement would lose an untouched display name.
function roundTrip(text) {
  return aliases.format(aliases.parse(text))
}

const commaName = "\"Lee, Jason\" <j@icloud.com>, second@icloud.com (default)"
deepEqual(aliases.parse(commaName), [
  { email: "j@icloud.com", displayName: "Lee, Jason", isPrimary: false, isDefault: false },
  { email: "second@icloud.com", displayName: "", isPrimary: false, isDefault: true }
])
assert.strictEqual(roundTrip(commaName), commaName,
  "a display name holding a comma survives being written back")
assert.strictEqual(roundTrip(roundTrip(commaName)), commaName,
  "and survives it a second time")

const quotedName = "\"Jay \\\"JJ\\\" Lee\" <jj@icloud.com>"
deepEqual(aliases.parse(quotedName), [
  { email: "jj@icloud.com", displayName: "Jay \"JJ\" Lee", isPrimary: false, isDefault: false }
])
assert.strictEqual(roundTrip(quotedName), quotedName)

assert.strictEqual(roundTrip("Work <b@icloud.com>"), "Work <b@icloud.com>")

deepEqual(aliases.parse("a@me.com\nb@me.com").map(row => row.email),
  ["a@me.com", "b@me.com"])

deepEqual(aliases.parse("\"Not (default) really\" <c@me.com>"), [
  { email: "c@me.com", displayName: "Not (default) really", isPrimary: false, isDefault: false }
])

assert.strictEqual(aliases.format(""), "")
deepEqual(aliases.parse(null), [])
deepEqual(aliases.parse(42), [])

deepEqual(aliases.sendAsList("me@icloud.com", "work@icloud.com"), [
  { email: "me@icloud.com", displayName: "", isPrimary: true, isDefault: true },
  { email: "work@icloud.com", displayName: "", isPrimary: false, isDefault: false }
])

deepEqual(aliases.sendAsList("me@icloud.com", "work@icloud.com (default)"), [
  { email: "me@icloud.com", displayName: "", isPrimary: true, isDefault: false },
  { email: "work@icloud.com", displayName: "", isPrimary: false, isDefault: true }
])

deepEqual(aliases.sendAsList("me@icloud.com", "ME@icloud.com, other@icloud.com")
  .map(row => row.email), ["me@icloud.com", "other@icloud.com"])

deepEqual(aliases.sendAsList("", ""), [])
deepEqual(aliases.sendAsList("", "work@icloud.com").map(row => row.email), ["work@icloud.com"])
deepEqual(aliases.sendAsList("me@icloud.com", null), [
  { email: "me@icloud.com", displayName: "", isPrimary: true, isDefault: true }
])

{
  const rows = aliases.sendAsList("me@icloud.com", '"Work Desk" <work@icloud.com>, other@icloud.com')
  const before = JSON.stringify(rows)
  deepEqual(aliases.withSenderName(rows, "  Jane Example "), [
    { email: "me@icloud.com", displayName: "Jane Example", isPrimary: true, isDefault: true },
    { email: "work@icloud.com", displayName: "Work Desk", isPrimary: false, isDefault: false },
    { email: "other@icloud.com", displayName: "", isPrimary: false, isDefault: false }
  ])
  assert.strictEqual(JSON.stringify(rows), before, "the provider's list is not edited in place")
  assert.strictEqual(aliases.withSenderName(rows, "   "), rows)
  deepEqual(aliases.withSenderName(null, "Jane"), [])
}

console.log("Aliases.js ok")

const assert = require("assert")
const { load, deepEqual } = require("./load")

const recovery = load("tests/oracles/Recovery.js")

const draft = {
  accountId: "me@example.com",
  sourceDraftId: "draft-7",
  mode: "reply",
  threadId: "thread-7",
  inReplyTo: "<message-7@example.com>",
  fromEmail: "alias@example.com",
  to: "jane@example.com",
  cc: "copy@example.com",
  bcc: "",
  subject: "Quarterly plan",
  body: "First draft",
  ccVisible: true,
  bccVisible: false,
  fromWasChosen: true,
  replyRecipients: [{ email: "jane@example.com" }],
  originalAttachments: [],
  forwardedAttachments: [],
  draftAttachments: [{
    filename: "plan.txt", mimeType: "text/plain", size: 10,
    path: "/tmp/plan.txt", owned: true
  }]
}

deepEqual(recovery.parse(""), recovery.empty())
deepEqual(recovery.parse("not json"), recovery.empty())
deepEqual(recovery.parse('{"version":2,"active":true}'), recovery.empty())
deepEqual(recovery.parse('{"version":1,"active":false}'), recovery.empty())

const encoded = recovery.serialize("reader", draft)
const parsed = recovery.parse(encoded)
assert.strictEqual(parsed.active, true)
assert.strictEqual(parsed.returnView, "reader")
assert.strictEqual(parsed.draft.sourceDraftId, "draft-7")
deepEqual(parsed.draft, recovery.draft(draft))
assert.strictEqual(parsed.draft.draftAttachments[0].data, "",
  "a file path is durable, so autosave does not rewrite its base64 on every key")

assert.strictEqual(recovery.hasMeaningfulDraft({ subject: " Plan " }), true)
assert.strictEqual(recovery.hasMeaningfulDraft({ body: "\n\n" }), false)

// Invariant: an unchanged placed body is an untouched composer, not a user-authored draft to recover.
assert.strictEqual(recovery.hasMeaningfulDraft({
  body: "\n\nMaarten", placedBody: "\n\nMaarten"
}), false, "an untouched signed compose is not a draft")
assert.strictEqual(recovery.hasMeaningfulDraft({
  body: "Something\n\nMaarten", placedBody: "\n\nMaarten"
}), true, "a sentence above the sign-off is")
assert.strictEqual(recovery.hasMeaningfulDraft({
  body: "\n\nMaarten", placedBody: "\n\nMaarten", bodyWasEdited: true
}), true, "typing and deleting back to the sign-off is still an edit")

// Invariant: legacy records lack placedBody and must retain their body as recoverable work.
assert.strictEqual(recovery.hasMeaningfulDraft({ body: "\n\nMaarten" }), true)
// Invariant: compare placedBody verbatim; trimming its leading editing space would manufacture a user edit.
assert.strictEqual(recovery.draft({ placedBody: "\n\nMaarten" }).placedBody, "\n\nMaarten")
assert.strictEqual(recovery.hasMeaningfulDraft({
  draftAttachments: [{ filename: "plan.txt" }]
}), true)
assert.strictEqual(recovery.serialize("list", { body: "  " }), "")

const unsafe = JSON.parse(encoded)
unsafe.draft.extra = "drop me"
unsafe.draft.draftAttachments[0].extra = "drop me"
const cleaned = recovery.parse(JSON.stringify(unsafe))
assert.strictEqual(cleaned.draft.extra, undefined)
assert.strictEqual(cleaned.draft.draftAttachments[0].extra, undefined)


{
  const withParked = recovery.parse(recovery.serialize("reader", draft, [draft, { to: "" }]))
  assert.strictEqual(withParked.parked.length, 1, "other parked drafts ride along; empty ones do not")
  assert.strictEqual(withParked.parked[0].to, draft.to)
  assert.strictEqual(recovery.parse(recovery.serialize("reader", draft)).parked.length, 0)
  assert.strictEqual(recovery.empty().parked.length, 0)
}

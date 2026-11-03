const assert = require("assert")
const { load } = require("./load")

const unsaved = load("account/Unsaved.js")

assert.strictEqual(unsaved.summary(null), "")
assert.strictEqual(unsaved.summary({}), "")
assert.strictEqual(unsaved.summary({ unsaved: 0, unsavedReasons: {} }), "")
assert.strictEqual(unsaved.summary({ unsaved: 1, unsavedReasons: { local_text_unreadable: 1 } }),
  "1 message could not be saved in full because Gmail's copy of its text is damaged.")
assert.strictEqual(unsaved.summary({ unsaved: 2, unsavedReasons: { local_text_unreadable: 2 } }),
  "2 messages could not be saved in full because Gmail's copy of their text is damaged.")
assert.strictEqual(unsaved.summary({ unsaved: 1, unsavedReasons: { gmail_response_too_large: 1 } }),
  "1 message could not be saved in full because it is too large to download.")
assert.strictEqual(unsaved.summary({ unsaved: 3, unsavedReasons: { gmail_response_too_large: 1, local_content_too_large: 2 } }),
  "3 messages could not be saved in full because they are too large to download.")
assert.strictEqual(unsaved.summary({ unsaved: 3, unsavedReasons: { local_text_unreadable: 2, local_content_too_large: 1 } }),
  "3 messages could not be saved in full: 2 with damaged text in Gmail and 1 too large to download.")
// A reason this window does not know, or counts that disagree, still give the total.
assert.strictEqual(unsaved.summary({ unsaved: 2, unsavedReasons: { some_new_reason: 2 } }), "2 messages could not be saved in full.")
assert.strictEqual(unsaved.summary({ unsaved: 4, unsavedReasons: { local_text_unreadable: 1 } }), "4 messages could not be saved in full.")
assert.strictEqual(unsaved.summary({ unsaved: "x" }), "")
// Counts are grouped as on the iPhone.
assert.strictEqual(unsaved.summary({ unsaved: 1200, unsavedReasons: { local_text_unreadable: 1000, local_content_too_large: 200 } }),
  "1,200 messages could not be saved in full: 1,000 with damaged text in Gmail and 200 too large to download.")
console.log("unsaved ok")

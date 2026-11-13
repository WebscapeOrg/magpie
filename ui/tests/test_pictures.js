const assert = require("assert")
const { load } = require("./load")

const pictures = load("inbox/Pictures.js")

assert.strictEqual(pictures.money(184), "$1.84")
assert.strictEqual(pictures.money(-3), "$0.00")
assert.strictEqual(pictures.money("x"), "$0.00")

assert.strictEqual(pictures.summary(null), "")
assert.strictEqual(pictures.summary({ present: null, problem: "pictures_key_storage", painted: 4 }),
  "The keyring could not be used. Unlock it, then open Settings again.")
assert.ok(pictures.summary({ present: false }).startsWith("Add an OpenAI API key"))
assert.ok(pictures.summary({ present: false, problem: "pictures_key_invalid" }).startsWith("Add an OpenAI API key"))
assert.ok(pictures.summary({ present: false }).includes("company domains are sent to OpenAI; names, email addresses and mail are not"))
assert.strictEqual(
  pictures.summary({ present: true, painted: 38, waiting: 3, spentTodayCents: 184, dailyLimitCents: 300 }),
  "38 sender pictures painted, 3 waiting. About $1.84 of the $3.00 daily limit used today.")
assert.strictEqual(
  pictures.summary({ present: true, painted: 1, waiting: 0, spentTodayCents: 7, dailyLimitCents: 300 }),
  "1 sender picture painted. About $0.07 of the $3.00 daily limit used today.")
assert.strictEqual(
  pictures.summary({ present: true, painted: 38, waiting: 0, failed: 2, spentTodayCents: 90, dailyLimitCents: 300 }),
  "38 sender pictures painted, 2 could not be painted. About $0.90 of the $3.00 daily limit used today.")
assert.ok(pictures.summary({ present: true, painted: 40, waiting: 2, spentTodayCents: 294, dailyLimitCents: 300 })
  .endsWith("The rest are painted tomorrow."))
assert.strictEqual(
  pictures.summary({ present: true, problem: "pictures_key_invalid" }),
  "OpenAI did not accept this key. Paste a current key.")
assert.strictEqual(pictures.problem("pictures_key_format"), "That is not an OpenAI API key. OpenAI keys start with sk-.")
assert.strictEqual(pictures.problem("pictures_request_rejected"), "OpenAI rejected Magpie Mail's picture requests several times in a row, so painting has stopped. Magpie Mail tries again tomorrow.")
assert.strictEqual(pictures.problem("<b>untrusted</b>"), "Sender pictures are not available right now.")
assert.strictEqual(pictures.problem(""), "")
console.log("pictures ok")

const assert = require("assert")
const { load } = require("./load")

const direction = load("message/Direction.js")

for (const code of [0x05b0, 0x064b, 0x037e, 0x10d40, 0x20c1]) {
  const prefix = String.fromCodePoint(code)
  assert.strictEqual(direction.directionOfCode(code), "", "non-strong Unicode class " + code.toString(16))
  assert.strictEqual(direction.strongDirectionOf(prefix + "hello"), "ltr")
  assert.strictEqual(direction.strongDirectionOf(prefix + "שלום"), "rtl")
}
for (const code of [0x00aa, 0x2102, 0x1f1e6]) {
  assert.strictEqual(direction.directionOfCode(code), "ltr", "Unicode L class " + code.toString(16))
  assert.strictEqual(direction.strongDirectionOf(String.fromCodePoint(code) + "שלום"), "ltr")
}
for (const code of [0x0590, 0x086b, 0x10ec0]) {
  assert.strictEqual(direction.directionOfCode(code), "rtl", "reserved RTL default " + code.toString(16))
}

assert.strictEqual(direction.strongDirectionOf("Hello world"), "ltr")
assert.strictEqual(direction.strongDirectionOf("مرحبا بالعالم"), "rtl")
assert.strictEqual(direction.strongDirectionOf("سلام دنیا"), "rtl", "Persian")
assert.strictEqual(direction.strongDirectionOf("שלום עולם"), "rtl", "Hebrew")
assert.strictEqual(direction.strongDirectionOf("ܫܠܡܐ"), "rtl", "Syriac")
assert.strictEqual(direction.strongDirectionOf("ދިވެހި"), "rtl", "Thaana")

assert.strictEqual(direction.strongDirectionOf("2024 مرحبا"), "rtl", "digits are neutral")
assert.strictEqual(direction.strongDirectionOf("— مرحبا"), "rtl", "dash is neutral")
assert.strictEqual(direction.strongDirectionOf("(!) שלום"), "rtl", "punctuation is neutral")
assert.strictEqual(direction.strongDirectionOf("١٢٣ مرحبا"), "rtl", "Arabic-Indic digits are neutral")
assert.strictEqual(direction.strongDirectionOf("2024 hello"), "ltr")

assert.strictEqual(direction.strongDirectionOf("١٢٣ hello"), "ltr",
  "Arabic-Indic digits are in the Arabic block and still assert nothing")
assert.strictEqual(direction.strongDirectionOf("۲۰۲۴ hello"), "ltr",
  "and so are the extended ones Persian writes")
assert.strictEqual(direction.strongDirectionOf("٢٠٢٤٫٥ hello"), "ltr",
  "with the separators that hold a number together")
assert.strictEqual(direction.strongDirectionOf("١٢٣"), "",
  "a subject that is nothing but Arabic-Indic digits chose no direction")

assert.strictEqual(direction.strongDirectionOf("\uFEFFHello world"), "ltr",
  "a byte order mark is not an Arabic letter")
assert.strictEqual(direction.strongDirectionOf("\uFEFFمرحبا"), "rtl")
assert.strictEqual(direction.strongDirectionOf("\uFEFC"), "rtl",
  "and the last character that really is one still is")

assert.strictEqual(direction.strongDirectionOf("🎉 مرحبا"), "rtl", "an emoji is neutral")
assert.strictEqual(direction.strongDirectionOf("🇸🇦 مرحبا"), "ltr", "regional indicators have Unicode class L")
assert.strictEqual(direction.strongDirectionOf("🎉 Hello"), "ltr")
assert.strictEqual(direction.strongDirectionOf("\u0301 مرحبا"), "rtl", "a combining mark is neutral")
assert.strictEqual(direction.strongDirectionOf("\uFF01 مرحبا"), "rtl", "fullwidth punctuation is neutral")
assert.strictEqual(direction.strongDirectionOf("\uFF21bc"), "ltr",
  "but a fullwidth letter is a letter")

assert.strictEqual(direction.strongDirectionOf("\u200Fhello"), "rtl",
  "a right-to-left mark answers even before a Latin word")
assert.strictEqual(direction.strongDirectionOf("\u200Eمرحبا"), "ltr",
  "and a left-to-right mark answers before an Arabic one")

assert.strictEqual(direction.strongDirectionOf(""), "")
assert.strictEqual(direction.strongDirectionOf("123 —— !!"), "")
assert.strictEqual(direction.strongDirectionOf(null), "")
assert.strictEqual(direction.strongDirectionOf(undefined), "")

assert.strictEqual(direction.strongDirectionOf("こんにちは"), "ltr", "Japanese")
assert.strictEqual(direction.strongDirectionOf("你好"), "ltr", "Chinese")
assert.strictEqual(direction.strongDirectionOf("नमस्ते"), "ltr", "Devanagari")
assert.strictEqual(direction.strongDirectionOf("Привет"), "ltr", "Cyrillic")

assert.strictEqual(direction.strongDirectionOf("\u{1E900}"), "rtl", "Adlam")
assert.strictEqual(direction.strongDirectionOf("\u{10A00}"), "rtl", "Kharoshthi")
assert.strictEqual(direction.strongDirectionOf("\u{1D400}"), "ltr", "maths capital A")

assert.strictEqual(direction.strongDirectionOf("‏مرحبا"), "rtl", "RLM")
assert.strictEqual(direction.strongDirectionOf("‎Hello"), "ltr", "LRM")
assert.strictEqual(direction.strongDirectionOf("‫مرحبا"), "rtl", "RLE")
assert.strictEqual(direction.strongDirectionOf("‪Hello"), "ltr", "LRE")

assert.strictEqual(
  direction.strongDirectionOf("⁦مرحبا⁩ hello"), "ltr",
  "an isolated Arabic run does not set the paragraph direction")
assert.strictEqual(
  direction.strongDirectionOf("⁦hello⁩ مرحبا"), "rtl",
  "the first strong character outside the isolate wins")

assert.strictEqual(direction.strongDirectionOf("Re: مرحبا"), "ltr", "the bug, unfixed")
assert.strictEqual(direction.subjectDirectionOf("Re: مرحبا"), "rtl", "the bug, fixed")

assert.strictEqual(direction.subjectDirectionOf("Fwd: שלום"), "rtl")
assert.strictEqual(direction.subjectDirectionOf("FW: مرحبا"), "rtl")
assert.strictEqual(direction.subjectDirectionOf("AW: مرحبا"), "rtl", "German reply")
assert.strictEqual(direction.subjectDirectionOf("TR: مرحبا"), "rtl", "French forward")
assert.strictEqual(direction.subjectDirectionOf("SV: שלום"), "rtl", "Swedish reply")
assert.strictEqual(direction.subjectDirectionOf("Re[2]: مرحبا"), "rtl", "a counted reply")
assert.strictEqual(direction.subjectDirectionOf("Re(3): مرحبا"), "rtl")
assert.strictEqual(direction.subjectDirectionOf("(fwd) مرحبا"), "rtl")

assert.strictEqual(direction.subjectDirectionOf("Fwd: Re: مرحبا"), "rtl")
assert.strictEqual(direction.subjectDirectionOf("[team] Re: مرحبا"), "rtl")
assert.strictEqual(direction.subjectDirectionOf("Re: [announce] Fwd: שלום"), "rtl")

assert.strictEqual(direction.subjectDirectionOf("Re: hello there"), "ltr")
assert.strictEqual(direction.subjectDirectionOf("hello there"), "ltr")

assert.strictEqual(direction.subjectDirectionOf("Re:"), "")
assert.strictEqual(direction.subjectDirectionOf("Re: 2024"), "")

assert.strictEqual(direction.subjectDirectionOf("Retirement مرحبا"), "ltr",
  "`Retirement` is not `Re:`")
assert.strictEqual(direction.subjectDirectionOf("Results: مرحبا"), "ltr",
  "an unlisted word before a colon is part of the subject")

assert.strictEqual(direction.subjectDirectionOf("Re: Re: Re: Re: Re: Re:"), "")

assert.strictEqual(direction.normalizeMode("Right to left"), "Right to left")
assert.strictEqual(direction.normalizeMode("Left to right"), "Left to right")
assert.strictEqual(direction.normalizeMode("Auto"), "Auto")
assert.strictEqual(direction.normalizeMode("nonsense"), "Auto", "an unknown mode is Auto")
assert.strictEqual(direction.normalizeMode(null), "Auto")
assert.strictEqual(direction.normalizeMode(undefined), "Auto")
assert.strictEqual(direction.MODE_DEFAULT, "Auto")

assert.strictEqual(direction.resolve("Hello world", "Right to left"), "rtl")
assert.strictEqual(direction.resolve("مرحبا", "Left to right"), "ltr")
assert.strictEqual(direction.resolve("Hello world", "Auto"), "ltr")
assert.strictEqual(direction.resolve("مرحبا", "Auto"), "rtl")
assert.strictEqual(direction.resolve("123", "Auto"), "", "Auto may still have no answer")
assert.strictEqual(direction.resolve("123", "Right to left"), "rtl",
  "a forced mode answers even where the text does not")

assert.strictEqual(direction.forced("Auto"), "", "Auto adds nothing of its own")
assert.strictEqual(direction.forced("Right to left"), "rtl")
assert.strictEqual(direction.forced("Left to right"), "ltr")
assert.strictEqual(direction.forced(null), "")

assert.strictEqual(direction.resolveSubject("Re: مرحبا", "Auto"), "rtl")
assert.strictEqual(direction.resolveSubject("Re: مرحبا", "Left to right"), "ltr")

assert.strictEqual(direction.isRightToLeft("rtl"), true)
assert.strictEqual(direction.isRightToLeft("ltr"), false)
assert.strictEqual(direction.isRightToLeft(""), false)

assert.strictEqual(direction.hasAnswer("rtl"), true)
assert.strictEqual(direction.hasAnswer("ltr"), true)
assert.strictEqual(direction.hasAnswer(""), false)

assert.strictEqual(direction.attributeFor("rtl"), " dir=\"rtl\"")
assert.strictEqual(direction.attributeFor("ltr"), " dir=\"ltr\"")
assert.strictEqual(direction.attributeFor(""), "",
  "no answer puts no attribute in the document")

assert.strictEqual(direction.startEdge("rtl"), "right")
assert.strictEqual(direction.startEdge("ltr"), "left")
assert.strictEqual(direction.startEdge(""), "left")
assert.strictEqual(direction.endEdge("rtl"), "left")
assert.strictEqual(direction.endEdge("ltr"), "right")

assert.strictEqual(direction.resolveBody("[image 1]مرحبا بالعالم", "Auto"), "rtl",
  "a marker this client wrote is not the message saying which way it runs")
assert.strictEqual(direction.resolveBody("[image 1][image 2]مرحبا", "Auto"), "rtl")
assert.strictEqual(direction.resolveBody("[image] مرحبا", "Auto"), "rtl",
  "the reader's own bare marker too")
assert.strictEqual(direction.resolveBody("[image 1]Hello", "Auto"), "ltr")
assert.strictEqual(direction.resolveBody("[image 1]", "Auto"), "",
  "a body that is nothing but pictures chose no direction")

assert.strictEqual(direction.resolveBody("Hello [image 1] مرحبا", "Auto"), "ltr")

assert.strictEqual(direction.resolveBody("[image 1]Hello", "Right to left"), "rtl")
assert.strictEqual(direction.resolveBody("مرحبا", "Left to right"), "ltr")

const { spawnSync } = require("child_process")
const path = require("path")
const generator = path.join(__dirname, "../../scripts/generate-direction-data.py")
const checked = spawnSync("python3", [generator, "--check"], { encoding: "utf8" })
assert.strictEqual(checked.status, 0, checked.stderr)
const reference = spawnSync("python3", [generator, "--classes"], { maxBuffer: 2 * 1024 * 1024 })
assert.strictEqual(reference.status, 0, String(reference.stderr))
assert.strictEqual(reference.stdout.length, 0x110000)
for (var code = 0; code < reference.stdout.length; code++) {
  const expected = code >= 0xD800 && code <= 0xDFFF ? "" : ["", "ltr", "rtl"][reference.stdout[code]]
  assert.strictEqual(direction.directionOfCode(code), expected, "Unicode class U+" + code.toString(16))
}
for (const code of [-1, 1.5, 0x110000, NaN, Infinity, "65", null]) {
  assert.strictEqual(direction.directionOfCode(code), "", "invalid code point must not assert a direction")
}

console.log("direction tests passed")

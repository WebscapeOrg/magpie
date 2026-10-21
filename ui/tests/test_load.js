const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { test } = require("node:test")
const { load, ROOT, deepEqual } = require("./load")

function modules(sources, run) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "magpie-load-"))
  try {
    for (const [name, source] of Object.entries(sources)) {
      const file = path.join(directory, name)
      fs.mkdirSync(path.dirname(file), { recursive: true })
      fs.writeFileSync(file, source)
    }
    run(name => load(path.relative(ROOT, path.join(directory, name))), directory)
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
}

test("QML library imports share one instance within a loaded graph", () => {
  modules({
    "Shared.js": ".pragma library\nvar count = 0; function next() { return ++count }",
    "branch/Left.js": '.pragma library\n.import "../Shared.js" as Shared\nfunction next() { return Shared.next() }',
    "Right.js": '.pragma library\n.import "Shared.js" as Shared\nfunction next() { return Shared.next() }',
    "Main.js": '.pragma library\n.import "branch/Left.js" as Left\n.import "Right.js" as Right'
  }, read => {
    const first = read("Main.js")
    assert.equal(first.Left.next(), 1)
    assert.equal(first.Right.next(), 2)
    assert.equal(read("Main.js").Right.next(), 1, "separate loads remain isolated")
  })
})

test("scripts without pragma library remain local to each importer", () => {
  modules({
    "Local.js": "var count = 0; function next() { return ++count }",
    "Left.js": '.pragma library\n.import "Local.js" as Local\nfunction next() { return Local.next() }',
    "Right.js": '.pragma library\n.import "Local.js" as Local\nfunction next() { return Local.next() }',
    "Main.js": '.pragma library\n.import "Left.js" as Left\n.import "Right.js" as Right'
  }, read => {
    const script = read("Main.js")
    assert.equal(script.Left.next(), 1)
    assert.equal(script.Right.next(), 1)
  })
})

for (const [name, actual, expected] of [
  ["missing properties", { missing: undefined }, {}],
  ["NaN", { count: NaN }, { count: null }],
  ["Infinity", [Infinity], [null]],
  ["negative zero", [-0], [0]],
  ["array holes", Array(1), [null]]
]) {
  test("cross-realm comparisons preserve " + name, () => {
    assert.throws(() => deepEqual(actual, expected), { code: "ERR_ASSERTION" })
  })
}

test("cross-realm comparisons preserve nested values and assertion messages", () => {
  modules({ "Values.js": "var record = { nested: [undefined, NaN, Infinity, -0] }" }, read => {
    deepEqual(read("Values.js").record, { nested: [undefined, NaN, Infinity, -0] })
    assert.throws(() => deepEqual([1], [2], "mailbox mismatch"), /mailbox mismatch/)
  })
})

test("module failures identify the source file", () => {
  modules({ "Broken.js": 'throw new Error("fixture failure")' }, (read, directory) => {
    assert.throws(() => read("Broken.js"), error => {
      assert.ok(error.stack.includes(path.join(directory, "Broken.js")))
      return true
    })
  })
})

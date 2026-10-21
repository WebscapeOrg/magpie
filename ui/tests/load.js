const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("node:assert/strict")

const ROOT = path.dirname(__dirname)

// Invariant: Tests execute repository QML scripts after resolving their QML directives.
const IMPORT_SOURCE = '^\\s*\\.import\\s+"([^"]+)"\\s+as\\s+(\\w+)\\s*$'

function load(relativePath) {
  return loadModule(path.resolve(ROOT, relativePath), new Map())
}

function loadModule(file, libraries) {
  if (libraries.has(file)) return libraries.get(file)
  const raw = fs.readFileSync(file, "utf8")

  const context = {}
  vm.createContext(context)

  const imports = [...raw.matchAll(new RegExp(IMPORT_SOURCE, "gm"))]

  for (const [, target, qualifier] of imports) {
    context[qualifier] = loadModule(path.resolve(path.dirname(file), target), libraries)
  }

  const source = raw
    .replace(/^\.pragma library\s*$/m, "")
    .replace(new RegExp(IMPORT_SOURCE, "gm"), "")

  vm.runInContext(source, context, { filename: file })
  if (/^\.pragma library\s*$/m.test(raw)) libraries.set(file, context)
  return context
}

// Invariant: Comparing across VM realms must preserve undefined, non-finite numbers and sparse arrays.
function deepEqual(actual, expected, message) {
  const actualValue = structuredClone(actual)
  const expectedValue = structuredClone(expected)
  if (message === undefined) assert.deepEqual(actualValue, expectedValue)
  else assert.deepEqual(actualValue, expectedValue, message)
}

module.exports = { load, ROOT, deepEqual }

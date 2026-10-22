const assert = require("assert")
const { load } = require("./load")

const appearance = load("settings/Appearance.js")

assert.strictEqual(appearance.MODES.join(","), "System,Light,Dark")
assert.strictEqual(appearance.MODE_DEFAULT, "System")

assert.strictEqual(appearance.normalizeMode("Light"), "Light")
assert.strictEqual(appearance.normalizeMode("dark"), "Dark")
assert.strictEqual(appearance.normalizeMode(" SYSTEM "), "System")

assert.strictEqual(appearance.normalizeMode(""), "System")
assert.strictEqual(appearance.normalizeMode(undefined), "System")
assert.strictEqual(appearance.normalizeMode(null), "System")
assert.strictEqual(appearance.normalizeMode("auto"), "System")
assert.strictEqual(appearance.normalizeMode(42), "System")

assert.strictEqual(appearance.paletteFor("System"), "")
assert.strictEqual(appearance.paletteFor("Light"), "light")
assert.strictEqual(appearance.paletteFor("dark"), "dark")
assert.strictEqual(appearance.paletteFor("nonsense"), "")

console.log("test_appearance.js ok")

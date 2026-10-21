const assert = require("assert")
const fs = require("fs")
const path = require("path")
const { load } = require("./load")

const icons = load("components/Icons.js")
const foreground = { r: 0.2, g: 0.4, b: 0.6, a: 0.75 }
function drawing(name, filled) {
  return decodeURIComponent(icons.source(name, foreground, filled).split(",").slice(1).join(","))
}

for (const name of icons.names()) {
  const source = icons.source(name, foreground)
  assert.ok(source.startsWith("data:image/svg+xml,"), `${name} is bundled vector artwork`)
  const svg = drawing(name)
  assert.ok(svg.includes('viewBox="0 0 24 24"'), `${name} preserves Lucide's coordinates`)
  assert.ok(svg.includes('stroke-width="1"'), `${name} uses the requested light stroke`)
  assert.ok(svg.includes('stroke="rgb(51,102,153)"'), `${name} follows the theme`)
  assert.ok(svg.includes('opacity="0.75"'), `${name} preserves theme opacity`)
  assert.ok(/<(?:path|rect|circle|line|polyline|polygon|ellipse) /.test(svg), `${name} has artwork`)
  assert.ok(!/<(?:script|image|use|foreignObject|style)\b|\b(?:href|src|on[a-z]+)=|url\(/i.test(svg), `${name} has no external resources or executable content`)
}
for (const name of ["nope", "", null, "__proto__", "constructor", "https://example.org/track.svg", '<image href="https://example.org/"/>']) {
  assert.strictEqual(icons.source(name, foreground), "", "unknown names cannot supply an image source")
}
assert.ok(drawing("star", true).includes('fill="rgb(51,102,153)"'), "a set star is filled")
assert.ok(drawing("star", false).includes('fill="none"'), "an unset star is outlined")
assert.strictEqual(drawing("unread", true), drawing("unread", false), "other icons remain outlined")
assert.notStrictEqual(drawing("forward"), drawing("chevronRight"), "forward is distinct from next")
assert.notStrictEqual(drawing("sent"), drawing("mail"), "Sent has a send symbol")
assert.strictEqual(icons.LUCIDE.snooze, "clock-3", "snooze keeps the conventional clock")
const hostileColor = { r: '" href="https://example.org/', g: Infinity, b: -1, a: NaN }
const bounded = decodeURIComponent(icons.source("mail", hostileColor))
assert.ok(!bounded.includes("example.org") && !bounded.includes("NaN") && !bounded.includes("Infinity"), "only bounded numeric color channels reach SVG")

// Every icon a view asks for by name is defined. Scans the QML for the
// literal names handed to ActionIcon, IconButton, IconTextButton and
// ProviderLogo's fallback, so a typo in a view is a failed test rather than
// an empty slot in the window.
const root = path.join(__dirname, "..")
const files = [path.join(root, "App.qml")]
for (const entry of fs.readdirSync(path.join(root, "components"))) {
  if (entry.endsWith(".qml")) files.push(path.join(root, "components", entry))
}
function literalIconNames(text) {
  const names = []
  for (const match of text.matchAll(/\b(?:iconName|fallbackIcon)\s*:\s*(["'])(.*?)\1/g)) {
    if (match[2]) names.push(match[2])
  }
  for (const match of text.matchAll(/\bActionIcon\s*\{[^}]*?\bname\s*:\s*(["'])(.*?)\1/gs)) {
    if (match[2]) names.push(match[2])
  }
  return names
}

assert.deepStrictEqual(literalIconNames(`
  IconButton { iconName: "bad-icon" }
  IconTextButton { iconName: "name2" }
  ProviderLogo { fallbackIcon: "typo_name" }
  ActionIcon { name: "bad.name" }
`), ["bad-icon", "name2", "typo_name", "bad.name"], "unknown punctuation and digits must reach the icon validator")
assert.deepStrictEqual(literalIconNames(`
  IconButton { iconName : 'mail' }
  ProviderLogo { fallbackIcon:\n    "inbox" }
  ActionIcon{ name : 'archive' }
`), ["mail", "inbox", "archive"], "QML whitespace and either quote style preserve coverage")

assert.deepStrictEqual(literalIconNames('iconName: ""; fallbackIcon: ""'), [], "optional empty icons are not requests")

const asked = new Set()
for (const file of files) {
  const text = fs.readFileSync(file, "utf8")
  for (const name of literalIconNames(text)) asked.add(name)
}
assert.ok(asked.size >= 20, `found the icon names the views use (${asked.size})`)
for (const name of asked) assert.ok(icons.has(name), `the views ask for "${name}", which Icons.js defines`)

console.log("test_icons.js ok")

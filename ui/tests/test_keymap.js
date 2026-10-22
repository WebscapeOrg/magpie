const assert = require("assert")
const { load, deepEqual } = require("./load")

const keymap = load("keys/Keymap.js")


assert.ok(keymap.BINDINGS.length > 20, "the table describes the whole keyboard")

keymap.BINDINGS.forEach(function (binding) {
  assert.ok(binding.id, "every binding has an id")
  assert.ok(binding.group, binding.id + " needs a group for the help sheet")
  assert.ok(binding.label, binding.id + " needs a label for the help sheet")
  assert.ok(binding.keys.length > 0, binding.id + " binds at least one key")
  binding.contexts.forEach(function (context) {
    assert.ok(context === "*" || keymap.CONTEXTS.indexOf(context) >= 0,
      binding.id + " names a context that exists: " + context)
  })
})

const ids = keymap.BINDINGS.map(function (binding) { return binding.id })
assert.strictEqual(new Set(ids).size, ids.length, "ids are unique")


deepEqual(keymap.conflicts(), [],
  "no sequence is bound twice within one context")


function byId(id) {
  return keymap.BINDINGS.filter(function (binding) { return binding.id === id })[0]
}

// Invariant: text-entry contexts bind no bare keys; Qt gives those keys to the active field.
;["search", "compose", "page"].forEach(function (context) {
  keymap.bindingsFor(context).forEach(function (binding) {
    binding.keys.forEach(function (key) {
      var bare = key.indexOf("Ctrl+") < 0 && key.indexOf("Alt+") < 0
        && key.indexOf("Meta+") < 0 && !/^F[0-9]+$/.test(key)
      assert.ok(!bare || key === "Escape",
        context + " must bind no bare key but Escape, and binds " + key
          + " for " + binding.id)
    })
  })
})

const undoSend = byId("undoSend")
assert.strictEqual(keymap.contextFor({ assistantEditing: true, composing: true }), "assistant")
assert.strictEqual(keymap.contextFor({ assistantEditing: true, assistantCommands: true, composing: true }), "assistantCommands")
assert.strictEqual(keymap.contextFor({ assistantEditing: false, composing: true }), "compose")
deepEqual(byId("assistantSend").keys, ["Return", "Enter", "Ctrl+Return", "Ctrl+Enter"])
assert.ok(!keymap.sequencesFor("assistant").some(entry => ["Up", "Down"].includes(entry.sequence)))
for (const key of ["Return", "Enter"]) {
  assert.strictEqual(keymap.sequencesFor("assistant").find(entry => entry.sequence === key).id, "assistantSend")
  assert.strictEqual(keymap.sequencesFor("assistantCommands").find(entry => entry.sequence === key).id, "assistantChooseCommand")
  assert.ok(!keymap.sequencesFor("assistant").some(entry => entry.sequence === "Shift+" + key))
}
assert.ok(!keymap.sequencesFor("compose").some(entry => entry.id === "assistantSend"))
assert.ok(undoSend, "the delayed-send state offers an undo action")
assert.strictEqual(keymap.displayFor(undoSend), "Alt+Z")
keymap.CONTEXTS.forEach(function (context) {
  assert.strictEqual(keymap.isEnabled(undoSend, context, false), true,
    "Alt+Z must undo a delayed send from " + context)
})

assert.strictEqual(keymap.contextFor({
  sendPending: true,
  currentView: "reader"
}), "reader", "a delayed send must not replace the reader's keyboard context")
assert.strictEqual(keymap.contextFor({
  sendPending: true,
  currentView: "list"
}), "list", "a delayed send must not replace the list's keyboard context")


const archive = byId("archive")
assert.strictEqual(keymap.isEnabled(archive, "list", false), true)
assert.strictEqual(keymap.isEnabled(archive, "reader", false), true)
assert.strictEqual(keymap.isEnabled(archive, "page", false), false,
  "a settings form is a form; e is not archive there")
assert.strictEqual(keymap.isEnabled(archive, "compose", false), false,
  "nor is it archive in the middle of a sentence")
assert.strictEqual(keymap.isEnabled(archive, "search", false), false,
  "nor in a query being typed")
assert.strictEqual(keymap.isEnabled(archive, "list", true), false,
  "an overlay stands it down")

const back = byId("back")
keymap.CONTEXTS.forEach(function (context) {
  assert.strictEqual(keymap.isEnabled(back, context, false), true,
    "Escape is the way out of " + context)
})
assert.strictEqual(keymap.isEnabled(back, "list", true), true,
  "including out of the overlay itself")

const help = byId("help")
assert.strictEqual(keymap.isEnabled(help, "list", true), true,
  "the sheet's own key has to close the sheet")

deepEqual(help.keys, ["?"])
assert.strictEqual(keymap.isSequenceEnabled(help, "?", "compose", false), false,
  "a question mark remains text inside a draft")
assert.strictEqual(keymap.isSequenceEnabled(help, "?", "list", false), true)
assert.strictEqual(byId("helpAnywhere"), undefined,
  "one help action must render as one row")
assert.strictEqual(keymap.isEnabled(byId("search"), "compose", false), false,
  "while the bare slash is a character in the draft")

const settings = byId("settings")
assert.strictEqual(keymap.displayFor(settings), "Ctrl+,")
keymap.CONTEXTS.forEach(function (context) {
  const entries = keymap.sequencesFor(context).filter(entry => entry.sequence === "Ctrl+,")
  assert.strictEqual(entries.length, 1, "Ctrl+, has exactly one action in " + context)
  assert.strictEqual(entries[0].id, "settings")
  assert.strictEqual(keymap.isSequenceEnabled(settings, "Ctrl+,", context, false), true)
})
assert.strictEqual(keymap.isEnabled(settings, "calendar", false), true,
  "settings must open from the calendar")
assert.strictEqual(keymap.isEnabled(settings, "page", false), true,
  "the settings route is available from every screen")

// Invariant: modified refresh remains available during text entry while bare letters remain text.
deepEqual(byId("refresh").keys, ["F5", "Ctrl+R"],
  "F5 and Ctrl+R both check for mail")
// Invariant: exercise the router table itself; arbitrary-sequence eligibility cannot prove that the sequence is bound.
keymap.CONTEXTS.forEach(function (context) {
  var live = keymap.sequencesFor(context).some(function (entry) {
    return entry.id === "refresh" && entry.sequence === "Ctrl+R"
  })
  assert.strictEqual(live, true, "Ctrl+R must check for mail from " + context)
})

const zoomIn = byId("zoomIn")
assert.strictEqual(keymap.isEnabled(zoomIn, "reader", false), true)
assert.strictEqual(keymap.isEnabled(zoomIn, "page", false), false,
  "there is no message body to size on a form")


const groups = keymap.helpGroups()
const rowCount = groups.reduce(function (n, group) { return n + group.rows.length }, 0)
assert.strictEqual(rowCount, keymap.BINDINGS.length,
  "the help sheet shows every binding — it cannot drift from the table again")
groups.forEach(function (group) {
  assert.ok(group.name, "a group is named")
  group.rows.forEach(function (row) {
    assert.ok(row.keys, "a help row shows its keys")
    assert.ok(row.action, "a help row says what the keys do")
  })
})

// Invariant: help lists actions separately while status hints may combine opposite movement keys.
assert.strictEqual(keymap.displayFor(byId("cursorUp")), "k, Up",
  "the sheet names every key that works")
assert.strictEqual(keymap.displayFor(byId("cursorDown")), "j, Down")
assert.strictEqual(keymap.displayFor(byId("help")), "?")

assert.strictEqual(keymap.readableSequence("g,i"), "g then i",
  "a chord reads as a chord, not as Qt's comma")
assert.strictEqual(keymap.readableSequence("Escape"), "Esc")
assert.strictEqual(keymap.readableSequence("Ctrl+Return"), "Ctrl+Enter")
assert.strictEqual(keymap.displayFor(byId("goMailbox")), "Ctrl+1…9",
  "nine mailbox keys are one row on the sheet, not nine")

const goAccount = byId("goAccount")
assert.ok(goAccount, "number keys switch directly to email accounts")
assert.strictEqual(keymap.displayFor(goAccount), "Alt+1…0",
  "ten account keys are one row on the sheet")
assert.strictEqual(keymap.slotFor("goAccount", "Alt+1"), 0)
assert.strictEqual(keymap.slotFor("goAccount", "Alt+9"), 8)
assert.strictEqual(keymap.slotFor("goAccount", "Alt+0"), 9)

assert.strictEqual(keymap.slotFor("goMailbox", "Ctrl+1"), 0)
assert.strictEqual(keymap.slotFor("goMailbox", "Ctrl+9"), 8)
assert.strictEqual(keymap.slotFor("goMailbox", "Ctrl+0"), -1,
  "Ctrl+0 is reset zoom, as in every browser, not a tenth row")
assert.strictEqual(keymap.slotFor("goMailbox", "Alt+1"), -1)
assert.strictEqual(keymap.slotFor("goMailbox", ""), -1)
assert.strictEqual(keymap.slotFor("nothing", "Alt+1"), -1)
assert.strictEqual(keymap.displayFor(byId("open")), "Enter, o")
assert.strictEqual(keymap.displayFor(byId("openReader")), "Right")
assert.strictEqual(keymap.displayFor(byId("scrollDown")), "Shift+J")
assert.strictEqual(keymap.displayFor(byId("back")), "Esc")
assert.strictEqual(keymap.displayFor(byId("switchAccount")), "Alt+A")
{
  const going = groups.filter(function (group) { return group.name === "Going" })[0]
  assert.ok(going, "Switch account lives with the other go-to keys")
  const sheet = going.rows.filter(function (row) { return row.action === "Switch account" })[0]
  assert.strictEqual(sheet.keys, "Alt+A")
}

assert.strictEqual(keymap.isEnabled(byId("cursorDown"), "list", true), true)
assert.strictEqual(keymap.isEnabled(byId("cursorUp"), "list", true), true)
assert.strictEqual(keymap.isEnabled(byId("scrollDown"), "reader", true), true)
assert.strictEqual(keymap.isEnabled(byId("scrollUp"), "reader", true), true)
assert.strictEqual(keymap.isEnabled(byId("openReader"), "list", false), true)
assert.strictEqual(keymap.isEnabled(byId("openReader"), "reader", false), false)
assert.strictEqual(keymap.isEnabled(byId("archive"), "list", true), false,
  "nothing acts on mail behind the sheet")
assert.strictEqual(keymap.isEnabled(byId("open"), "list", true), false)
assert.strictEqual(keymap.isEnabled(byId("compose"), "list", true), false)

const switchAccount = byId("switchAccount")
assert.strictEqual(keymap.isEnabled(switchAccount, "list", false), true)
assert.strictEqual(keymap.isEnabled(switchAccount, "reader", false), true)
assert.strictEqual(keymap.isEnabled(switchAccount, "compose", false), false,
  "a draft is not a mailbox to leave")
assert.strictEqual(keymap.isEnabled(switchAccount, "search", false), false)
assert.strictEqual(keymap.isEnabled(switchAccount, "page", false), false)
const calendar = byId("calendar")
assert.strictEqual(keymap.displayFor(calendar), "Alt+C")
assert.strictEqual(keymap.isEnabled(calendar, "list", false), true)
assert.strictEqual(keymap.isEnabled(calendar, "reader", false), true)
assert.strictEqual(keymap.isEnabled(calendar, "calendar", false), true)
assert.strictEqual(keymap.isEnabled(calendar, "page", false), false)
const createEvent = byId("createEvent")
assert.strictEqual(keymap.displayFor(createEvent), "c")
assert.strictEqual(keymap.isEnabled(createEvent, "calendar", false), true)
assert.strictEqual(keymap.isEnabled(createEvent, "list", false), false)
assert.strictEqual(keymap.isEnabled(createEvent, "compose", false), false)
;["calendarNext", "calendarPrevious", "openCalendarEvent", "calendarPreviousPeriod",
  "calendarNextPeriod", "calendarToday", "calendarWeek", "calendarMonth"].forEach(function(id) {
  assert.ok(byId(id), id + " must be listed in the shared key map")
  assert.strictEqual(keymap.isEnabled(byId(id), "calendar", false), true)
  assert.strictEqual(keymap.isEnabled(byId(id), "list", false), false)
})
assert.strictEqual(keymap.displayFor(byId("calendarToday")), "t",
  "t returns the calendar to today")
const mailView = byId("mailView")
const calendarView = byId("calendarView")
assert.strictEqual(keymap.displayFor(mailView), "Ctrl+Shift+M")
assert.strictEqual(keymap.displayFor(calendarView), "Ctrl+Shift+C")
assert.strictEqual(keymap.isEnabled(mailView, "calendar", false), true)
assert.strictEqual(keymap.isEnabled(calendarView, "list", false), true)
assert.strictEqual(keymap.isEnabled(calendarView, "reader", false), true)
assert.strictEqual(keymap.isEnabled(calendarView, "compose", false), false)
assert.strictEqual(keymap.displayFor(byId("zoomReset")), "Ctrl+0")
const sidebar = byId("toggleSidebar")
assert.strictEqual(keymap.displayFor(sidebar), "[")
assert.strictEqual(keymap.isEnabled(sidebar, "list", false), true)
assert.strictEqual(keymap.isEnabled(sidebar, "reader", false), true)
assert.strictEqual(keymap.isEnabled(sidebar, "calendar", false), true)

assert.strictEqual(keymap.hintKeyFor(byId("cursorDown")), "j / k",
  "the status bar shows one line for the pair")
assert.strictEqual(keymap.hintKeyFor(byId("open")), "o",
  "and the short form of a row with several keys")
assert.strictEqual(keymap.hintKeyFor(byId("archive")), "e",
  "falling back to the keys when there is nothing to shorten")

const listHints = keymap.hintsFor("list")
assert.strictEqual(keymap.keycapLabel("Shift+J / Shift+K"), "shift+j / shift+k")
assert.strictEqual(keymap.keycapLabel("Ctrl+Enter, Esc, Space"), "ctrl+enter, esc, space")
assert.ok(!keymap.hintsFor("reader").some(function (hint) { return hint.label === "open" }))
deepEqual(listHints.map(function (hint) { return hint.key + " " + hint.label }),
  ["j / k move", "e archive", "d trash", "Space select", "c compose"],
  "the status bar offers what the list can do, in its short form")
const selectedListHints = keymap.hintsFor("list", [], true)
deepEqual(selectedListHints.map(function (hint) { return hint.key + " " + hint.label }),
  ["j / k move", "e archive", "d trash", "v move to", "Space select", "c compose"],
  "the move hint joins the existing row only while a message is selected")
assert.ok(!keymap.hintsFor("list", ["move"], true).some(function (hint) {
  return hint.key === "v"
}), "a provider without move does not offer the move hint")
const composeHints = keymap.hintsFor("compose")
deepEqual(composeHints.map(function (hint) { return hint.label }),
  ["send", "close"],
  "Escape discards a draft, so it says close rather than back")
deepEqual(keymap.hintsFor("page").map(function (hint) { return hint.label }),
  ["back"],
  "a form's whole keyboard contract is leaving it")


const listSequences = keymap.sequencesFor("list")
const expectedCount = keymap.bindingsFor("list").reduce(
  function (n, binding) { return n + binding.keys.length }, 0)
assert.strictEqual(listSequences.length, expectedCount,
  "every key of every row in the context is present")
listSequences.forEach(function (row) {
  assert.ok(row.id && row.sequence && row.binding,
    "each entry carries its id, its sequence, and the row it came from")
})
assert.strictEqual(keymap.sequencesFor("compose").filter(function (row) {
  return row.id === "help"
}).length, 0, "Help stays out of text-entry contexts")


// Invariant: the documentation table is checked against the binding source because independent copies previously drifted.
{
  const fs = require("fs")
  const path = require("path")
  const doc = fs.readFileSync(
    path.join(__dirname, "..", "..", "docs", "KEYS.md"), "utf8")
  const body = doc.split("<!-- BEGIN BINDINGS -->")[1]
  assert.ok(body, "docs/KEYS.md must fence its table with BEGIN/END BINDINGS")
  const rows = body.split("<!-- END BINDINGS -->")[0]
    .split("\n")
    .filter(function (line) { return line.indexOf("| `") === 0 })

  function shorthand(binding) {
    return binding.contexts.join("+")
      .replace("list+reader", "mail")
      .replace("*", "all")
  }

  assert.strictEqual(rows.length, keymap.BINDINGS.length,
    "docs/KEYS.md lists every binding and no others")

  keymap.BINDINGS.forEach(function (binding, rowIndex) {
    const expected = "| `" + binding.id + "` | "
      + binding.keys.map(function (k) { return "`" + k + "`" }).join(", ")
      + " | " + shorthand(binding) + " | " + binding.label + " |"
    assert.strictEqual(rows[rowIndex].trim(), expected,
      "docs/KEYS.md row " + (rowIndex + 1) + " is out of step with keys/Keymap.js")
  })
}

const offered = keymap.hintsFor("list")
const withoutBoth = keymap.hintsFor("list", ["archive", "star"])
assert.ok(offered.length > withoutBoth.length, "two hints go")
assert.ok(offered.some(hint => hint.label === "archive"))
assert.ok(!withoutBoth.some(hint => hint.label === "archive"))
assert.ok(!withoutBoth.some(hint => hint.label === "star"))
deepEqual(keymap.hintsFor("list", []), offered, "nothing missing changes nothing")
deepEqual(keymap.hintsFor("list", null), offered)

// Invariant: help columns prevent the prior single-column overflow and misplaced central scrollbar.

const all = keymap.helpGroups().map(group => group.name)
const weight = group => group.rows.length + 1
const totalWeight = keymap.helpGroups().reduce((sum, group) => sum + weight(group), 0)
const withoutAgent = keymap.helpGroups(["askAgent", "assistantSend", "assistantChooseCommand", "assistantCommandNext", "assistantCommandPrevious"])
assert.ok(!withoutAgent.some(group => group.name === "AI"),
  "a host without the agent does not advertise AI shortcuts")
assert.ok(!withoutAgent.some(group => group.rows.some(row => row.action.indexOf("Ask AI") >= 0)),
  "the Ask AI shortcut leaves the host-specific reference sheet")

for (const count of [1, 2, 3, 4]) {
  const columns = keymap.helpColumns(count)
  assert.strictEqual(columns.length, Math.min(count, all.length),
    count + ": one list per column")
  deepEqual([].concat(...columns).map(group => group.name), all,
    count + ": the declared order survives the split")
  for (const column of columns) {
    assert.ok(column.length > 0, count + ": no column is left empty")
  }
  const heaviest = Math.max(...columns.map(column => column.reduce((sum, group) => sum + weight(group), 0)))
  assert.ok(heaviest <= Math.ceil(totalWeight / count) + 6,
    count + ": no column runs away with the sheet (" + heaviest + ")")
}

// Invariant: move uses Gmail's v binding; reusing m would force incoming Gmail users to unlearn mute (issue58).
const move = keymap.BINDINGS.filter(binding => binding.id === "moveToLabel")
assert.strictEqual(move.length, 1, "one move row")
deepEqual(move[0].keys, ["v"], "Gmail moves with v")
assert.ok(keymap.BINDINGS.every(binding => binding.keys.indexOf("m") < 0 || binding.contexts.indexOf("calendar") >= 0),
  "m stays out of the mailbox, where Gmail means mute by it")

deepEqual(keymap.bindingsFor("list").filter(binding => binding.id === "moveToLabel").length, 1)
deepEqual(keymap.bindingsFor("reader").filter(binding => binding.id === "moveToLabel").length, 1)
deepEqual(keymap.bindingsFor("calendar").filter(binding => binding.id === "moveToLabel").length, 0)

deepEqual(keymap.helpColumns(0), [keymap.helpGroups()])
deepEqual(keymap.helpColumns(-3), [keymap.helpGroups()])
deepEqual(keymap.helpColumns(99).length, all.length, "never more columns than groups")

console.log("test_keymap.js ok")

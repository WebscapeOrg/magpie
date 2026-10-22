const assert = require("assert")
const { load, deepEqual } = require("./load")

const nav = load("account/Navigation.js")

function serializedSnapshot(stack) {
  return JSON.stringify(stack)
}


deepEqual(nav.OVERLAYS, ["compose", "eventComposer", "help"])

deepEqual(nav.entry("reader", { id: "m1" }), { id: "m1", kind: "reader" })
deepEqual(nav.entry("list"), { kind: "list" })
deepEqual(nav.entry("nothing-of-the-sort"), { kind: "list" }, "an unknown kind is the list")
deepEqual(nav.entry(null), { kind: "list" })
deepEqual(nav.entry("settings", { kind: "bogus" }), { kind: "settings" },
  "a field named kind cannot smuggle an unknown one in")

assert.strictEqual(nav.isOverlay("compose"), true)
assert.strictEqual(nav.isOverlay("eventComposer"), true)
assert.strictEqual(nav.isOverlay("help"), true)
assert.strictEqual(nav.isOverlay("reader"), false)
assert.strictEqual(nav.isOverlay(""), false)
assert.strictEqual(nav.isOverlay(null), false)

deepEqual(nav.top([]), { kind: "list" })
deepEqual(nav.top(null), { kind: "list" })
deepEqual(nav.top(undefined), { kind: "list" })
deepEqual(nav.page([]), { kind: "list" })
assert.strictEqual(nav.overlay([]), null)
assert.strictEqual(nav.depth([]), 0)
assert.strictEqual(nav.depth(null), 0)
deepEqual(nav.kinds([]), [])
deepEqual(nav.kinds(null), [])


const list = [nav.entry("list")]

let stack = nav.push(list, nav.entry("settings"))
deepEqual(nav.kinds(stack), ["list", "settings"])
assert.strictEqual(nav.depth(stack), 2)
deepEqual(nav.top(stack), { kind: "settings" })

stack = nav.push(stack, nav.entry("picker"))
stack = nav.push(stack, nav.entry("setup", { provider: "imap", draft: true }))
deepEqual(nav.kinds(stack), ["list", "settings", "picker", "setup"])
deepEqual(nav.top(stack), { kind: "setup", provider: "imap", draft: true })

stack = nav.pop(stack)
deepEqual(nav.kinds(stack), ["list", "settings", "picker"])
stack = nav.pop(stack)
deepEqual(nav.kinds(stack), ["list", "settings"])
stack = nav.pop(stack)
deepEqual(nav.kinds(stack), ["list"])

deepEqual(nav.kinds(nav.replace(nav.push(list, nav.entry("settings")), nav.entry("picker"))),
  ["list", "picker"], "replace swaps the top without recording a step")
deepEqual(nav.replace([], nav.entry("settings")), [{ kind: "settings" }],
  "replacing the top of nothing is a stack of that one entry")

deepEqual(nav.kinds(nav.push(list, null)), ["list"])
deepEqual(nav.kinds(nav.push([], nav.entry("settings"))), ["list", "settings"],
  "an empty stack is the list, so a push lands over it")

deepEqual(nav.kinds(nav.push(list, { kind: "no-such-page" })), ["list", "list"])

const reader1 = nav.push(list, nav.entry("reader", { id: "m1" }))
const reader2 = nav.push(reader1, nav.entry("reader", { id: "m2" }))
deepEqual(nav.kinds(reader2), ["list", "reader"])
deepEqual(nav.top(reader2), { kind: "reader", id: "m2" })
deepEqual(nav.kinds(nav.pop(reader2)), ["list"], "one Back leaves both messages")

const help1 = nav.push(reader1, nav.entry("help"))
const help2 = nav.push(help1, nav.entry("help"))
deepEqual(nav.kinds(help2), ["list", "reader", "help"])
const compose1 = nav.push(reader1, nav.entry("compose"))
const compose2 = nav.push(compose1, nav.entry("compose"))
deepEqual(nav.kinds(compose2), ["list", "reader", "compose"])
assert.strictEqual(nav.top(compose2).returnTo, 2,
  "the second draft keeps a returnTo measured with the first one gone")

const helpOverCompose = nav.push(compose1, nav.entry("help"))
deepEqual(nav.kinds(helpOverCompose), ["list", "reader", "compose", "help"])

const fromList = nav.push(list, nav.entry("reader", { id: "m1" }))
const replyFromList = nav.push(fromList, nav.entry("compose", { returnTo: 1 }))
deepEqual(nav.kinds(replyFromList), ["list", "reader", "compose"])
deepEqual(nav.kinds(nav.pop(replyFromList)), ["list"])

const replyFromReader = nav.push(fromList, nav.entry("compose", { returnTo: 2 }))
deepEqual(nav.kinds(replyFromReader), ["list", "reader", "compose"])
deepEqual(nav.kinds(nav.pop(replyFromReader)), ["list", "reader"])

assert.strictEqual(nav.top(nav.push(list, nav.entry("compose"))).returnTo, 1)
assert.strictEqual(nav.top(nav.push(fromList, nav.entry("compose"))).returnTo, 2)
assert.strictEqual(nav.top(nav.push(fromList, nav.entry("eventComposer"))).returnTo, 2)
assert.strictEqual(nav.top(nav.push(fromList, nav.entry("compose", { returnTo: 1 }))).returnTo, 1)
assert.strictEqual(nav.top(nav.push(fromList, nav.entry("help"))).returnTo, undefined,
  "only a draft records where it was raised from")

deepEqual(nav.kinds(nav.pop([nav.entry("list"), nav.entry("reader", { id: "m1" }),
  nav.entry("compose", { returnTo: 7 })])), ["list", "reader"],
  "a returnTo past the top still pops one step")
deepEqual(nav.kinds(nav.pop([nav.entry("list"), nav.entry("compose", { returnTo: 0 })])),
  ["list"], "a returnTo below the root stops at the root")
deepEqual(nav.kinds(nav.pop([nav.entry("list"), nav.entry("reader", { id: "m1" }),
  nav.entry("compose", { returnTo: "1" })])), ["list", "reader"],
  "a returnTo that is not a number is not a returnTo")

// Invariant: Popping the root returns the same array so the window can distinguish closing from navigation.
const calendar = [nav.entry("calendar")]
assert.strictEqual(nav.pop(list), list)
assert.strictEqual(nav.pop(calendar), calendar)
const picker = [nav.entry("picker")]
assert.strictEqual(nav.pop(picker), picker, "a first-run picker is a root too")
assert.notStrictEqual(nav.pop(reader1), reader1)

deepEqual(nav.pop([]), [{ kind: "list" }])
deepEqual(nav.pop(null), [{ kind: "list" }])
deepEqual(nav.pop(undefined), [{ kind: "list" }])
deepEqual(nav.pop("list"), [{ kind: "list" }])

const readerHelp = nav.push(reader1, nav.entry("help"))
deepEqual(nav.page(readerHelp), { kind: "reader", id: "m1" })
deepEqual(nav.overlay(readerHelp), { kind: "help" })
deepEqual(nav.page(helpOverCompose), { kind: "reader", id: "m1" })
deepEqual(nav.overlay(helpOverCompose), { kind: "help" })
deepEqual(nav.overlay(nav.pop(helpOverCompose)), { kind: "compose", returnTo: 2 })
assert.strictEqual(nav.overlay(reader1), null)
deepEqual(nav.page(reader1), { kind: "reader", id: "m1" })
deepEqual(nav.page(list), { kind: "list" })

deepEqual(nav.page([nav.entry("help")]), { kind: "list" })


deepEqual(nav.replaceRoot(reader1, "calendar"), [{ kind: "calendar" }])
deepEqual(nav.replaceRoot(helpOverCompose, "list"), [{ kind: "list" }])
deepEqual(nav.resetTo(helpOverCompose, "list"), [{ kind: "list" }])
deepEqual(nav.resetTo(reader1, "picker"), [{ kind: "picker" }],
  "a first-run root resets to the picker, not the list")
deepEqual(nav.replaceRoot(reader1, "not-a-kind"), [{ kind: "list" }])
deepEqual(nav.replaceRoot(null, "calendar"), [{ kind: "calendar" }])

deepEqual(nav.rootFor({ anyReady: true, view: "list" }), [{ kind: "list" }])
deepEqual(nav.rootFor({ anyReady: true, view: "calendar" }), [{ kind: "calendar" }])
deepEqual(nav.rootFor({ anyReady: true, view: "reader" }), [{ kind: "list" }],
  "only the calendar is a root; anything else is the list")
deepEqual(nav.rootFor({ anyReady: true }), [{ kind: "list" }])

deepEqual(nav.rootFor({ anyReady: false, hasSavedAccounts: false }), [{ kind: "picker" }])

deepEqual(nav.rootFor({ anyReady: false, hasSavedAccounts: true, setupUnderway: true, provider: "imap" }),
  [{ kind: "picker" }, { kind: "setup", provider: "imap", draft: false }])

deepEqual(nav.rootFor({ anyReady: false, hasSavedAccounts: true, setupUnderway: false, provider: "imap" }),
  [{ kind: "picker" }])

deepEqual(nav.rootFor({ anyReady: false, hasSavedAccounts: false, view: "calendar" }), [{ kind: "picker" }])
deepEqual(nav.rootFor({ anyReady: false, hasSavedAccounts: true, setupUnderway: true, provider: "gmail", view: "calendar" }),
  [{ kind: "picker" }, { kind: "setup", provider: "gmail", draft: false }])

deepEqual(nav.rootFor({ anyReady: false, hasSavedAccounts: false, setupUnderway: true, provider: "imap" }),
  [{ kind: "picker" }])
deepEqual(nav.rootFor(null), [{ kind: "picker" }])
deepEqual(nav.rootFor({}), [{ kind: "picker" }])


deepEqual(nav.kinds(helpOverCompose), ["list", "reader", "compose", "help"])
deepEqual(nav.kinds(nav.rootFor({ anyReady: false, hasSavedAccounts: true, setupUnderway: true, provider: "hey" })),
  ["picker", "setup"])


const before = [nav.entry("list"), nav.entry("reader", { id: "m1" }), nav.entry("compose", { returnTo: 1 })]
const snapshot = serializedSnapshot(before)
const draft = nav.entry("compose")
const draftSnapshot = serializedSnapshot(draft)

nav.push(before, draft)
nav.push(before, nav.entry("reader", { id: "m2" }))
nav.push(before, nav.entry("help"))
nav.pop(before)
nav.replace(before, nav.entry("settings"))
nav.replaceRoot(before, "calendar")
nav.resetTo(before, "list")
nav.top(before)
nav.page(before)
nav.overlay(before)
nav.kinds(before)
assert.strictEqual(serializedSnapshot(before), snapshot, "no function edits the stack it was given")
assert.strictEqual(serializedSnapshot(draft), draftSnapshot, "push fills returnTo on a copy, not on the caller's entry")

// Invariant: Mutators must not change arrays or entries already displayed by QML.
const pushed = nav.push(before, nav.entry("help"))
assert.notStrictEqual(pushed, before)
assert.notStrictEqual(pushed[0], before[0])
const popped = nav.pop(before)
assert.notStrictEqual(popped, before)
assert.notStrictEqual(popped[0], before[0])
const replaced = nav.replace(before, nav.entry("settings"))
assert.notStrictEqual(replaced, before)
const settings = nav.entry("settings")
const withSettings = nav.push(list, settings)
assert.notStrictEqual(withSettings[1], settings, "an entry is copied onto the stack")

console.log("test_navigation.js ok")

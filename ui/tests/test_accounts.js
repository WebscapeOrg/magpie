const assert = require("assert")
const { load, deepEqual } = require("./load")

const accounts = load("account/Accounts.js")

function account(email, extra) {
  return Object.assign({ email: email, clientId: "cid", clientSecret: "secret", label: "" }, extra || {})
}

function serializedSnapshot(list) {
  return JSON.stringify(list)
}


deepEqual(accounts.emptyList(), { version: accounts.VERSION, accounts: [], activeId: "" })
assert.strictEqual(accounts.calendarProvider({ email: "person@work.example" }), "google")
assert.strictEqual(accounts.calendarProvider({ provider: "gmail" }), "google")
assert.strictEqual(accounts.calendarProvider({ provider: "imap" }), "")
assert.strictEqual(accounts.VERSION, 1)
assert.strictEqual(accounts.count(accounts.emptyList()), 0)

// Invariant: Saved account existence is independent of asynchronous sign-in readiness.
assert.strictEqual(accounts.hasSavedAccounts({ accounts: [
  { id: "saved@example.com", email: "saved@example.com" }
] }), true)
assert.strictEqual(accounts.hasSavedAccounts({ accounts: [
  { id: "", email: "" }
] }), false)
assert.strictEqual(accounts.hasSavedAccounts({ accounts: [
  { id: "", email: "ada" }
] }), false, "a username in the address field is setup state, not an account")
assert.strictEqual(accounts.hasSavedAccounts({ accounts: [
  { id: "", email: "ada" },
  { id: "ada@example.com", email: "ada@example.com" }
] }), true, "one real mailbox alongside it is still a saved list")
assert.strictEqual(accounts.active(accounts.emptyList()), null)
assert.strictEqual(accounts.find(accounts.emptyList(), "a@example.com"), null)


assert.strictEqual(accounts.isValidEmail("a@example.com"), true)
assert.strictEqual(accounts.isValidEmail("first.last+tag@mail.example.co.uk"), true)
assert.strictEqual(accounts.isValidEmail(""), false)
assert.strictEqual(accounts.isValidEmail("nobody"), false)
assert.strictEqual(accounts.isValidEmail("nobody@example"), false, "a bare host is not an address")
assert.strictEqual(accounts.isValidEmail("@example.com"), false)
assert.strictEqual(accounts.isValidEmail("two words@example.com"), false)
assert.strictEqual(accounts.isValidEmail(null), false)
assert.strictEqual(accounts.isValidEmail(undefined), false)

assert.strictEqual(accounts.accountId("  Ada@Example.COM "), "ada@example.com")
assert.strictEqual(accounts.accountId("nobody"), "")
assert.strictEqual(accounts.accountId(""), "")
assert.strictEqual(accounts.accountId(null), "")
assert.throws(() => accounts.accountId("Ada@Hotmail.com", "outlook"), /accounts_provider_unsupported/)


assert.strictEqual(accounts.label({ email: "ada@example.com", label: "Work" }), "Work")
assert.strictEqual(accounts.label({ email: "ada@example.com", label: "" }), "ada")
assert.strictEqual(accounts.label({ email: "", label: "" }), "New account")
assert.strictEqual(accounts.label({ email: "  ", label: "  " }), "New account")
assert.strictEqual(accounts.label(null), "New account")
assert.strictEqual(accounts.label({ email: "ada@example.com", label: "工作邮箱" }), "工作邮箱")


let one = accounts.add(accounts.emptyList(), account("Ada@Example.com"))
assert.strictEqual(accounts.count(one), 1)
assert.strictEqual(one.accounts[0].id, "ada@example.com")
assert.strictEqual(one.activeId, "ada@example.com", "the first account is the one on screen")
assert.strictEqual(accounts.active(one).id, "ada@example.com")
assert.strictEqual(accounts.find(one, "ada@example.com").clientId, "cid")
assert.strictEqual(accounts.find(one, "ADA@example.com"), null, "ids are looked up as stored")

const beforeAdd = serializedSnapshot(one)
let two = accounts.add(one, account("bob@example.com", { label: "Personal" }))
assert.notStrictEqual(two, one)
assert.strictEqual(serializedSnapshot(one), beforeAdd, "add leaves its input alone")
assert.strictEqual(accounts.count(two), 2)
assert.strictEqual(two.activeId, "ada@example.com", "a second account does not steal the selection")

let corrected = accounts.add(two, account("ADA@example.com", { clientId: "cid2", label: "Work" }))
assert.strictEqual(accounts.count(corrected), 2)
assert.strictEqual(corrected.accounts[0].id, "ada@example.com", "the corrected account keeps its place")
assert.strictEqual(corrected.accounts[0].clientId, "cid2")
assert.strictEqual(corrected.accounts[0].label, "Work")
assert.strictEqual(corrected.accounts[1].id, "bob@example.com")
assert.strictEqual(corrected.activeId, "ada@example.com")


let pending = accounts.add(accounts.emptyList(), account("", { clientId: "cid3" }))
assert.strictEqual(accounts.count(pending), 1)
assert.strictEqual(pending.accounts[0].id, "")
assert.strictEqual(pending.accounts[0].clientId, "cid3")
assert.strictEqual(pending.activeId, "", "a pending account cannot be active")
assert.strictEqual(accounts.active(pending), null)
assert.strictEqual(accounts.find(pending, ""), null, "an empty id names nothing")

let typo = accounts.add(accounts.emptyList(), account("not-an-address"))
assert.strictEqual(typo.accounts[0].id, "")
assert.strictEqual(typo.accounts[0].email, "not-an-address")
assert.strictEqual(typo.activeId, "")

let bothPending = accounts.add(pending, account("", { clientId: "cid4" }))
assert.strictEqual(accounts.count(bothPending), 2)
assert.strictEqual(bothPending.activeId, "")

let settled = accounts.add(bothPending, account("ada@example.com"))
assert.strictEqual(settled.activeId, "ada@example.com")
assert.strictEqual(accounts.count(settled), 3)


let three = accounts.add(corrected, account("cid@example.com"))
assert.strictEqual(accounts.count(three), 3)
const beforeRemove = serializedSnapshot(three)

// Invariant: A removal request describes the observed identity and position; accepting a stale request must not remove a replacement.
const removal = accounts.removalRequest(three, 0)
deepEqual(removal, {
  id: "ada@example.com",
  email: "ADA@example.com",
  index: 0
})
assert.strictEqual(serializedSnapshot(three), beforeRemove)
assert.strictEqual(accounts.removalRequest(three, -1), null)
assert.strictEqual(accounts.removalRequest(three, 99), null)
assert.strictEqual(accounts.removalRequest(one, 0), null,
  "the only account cannot be removed")
assert.strictEqual(accounts.removalRequest(bothPending, 1), null,
  "a draft has no stable identity and is canceled rather than removed")
assert.strictEqual(accounts.confirmRemoval(three, { id: "gone@example.com", index: 0 }), -1,
  "confirmation must not remove whichever account later occupies a stale row")
assert.strictEqual(accounts.confirmRemoval(three, removal), 0)

let withoutBob = accounts.remove(three, "bob@example.com")
assert.strictEqual(serializedSnapshot(three), beforeRemove, "remove leaves its input alone")
assert.strictEqual(accounts.count(withoutBob), 2)
assert.strictEqual(accounts.find(withoutBob, "bob@example.com"), null)
assert.strictEqual(withoutBob.activeId, "ada@example.com", "removing another account keeps the selection")

let withoutAda = accounts.remove(three, "ada@example.com")
assert.strictEqual(accounts.count(withoutAda), 2)
assert.strictEqual(accounts.find(withoutAda, withoutAda.activeId) !== null, true)
assert.strictEqual(withoutAda.activeId, "bob@example.com")

let lastGone = accounts.remove(accounts.remove(withoutAda, "bob@example.com"), "cid@example.com")
assert.strictEqual(accounts.count(lastGone), 0)
assert.strictEqual(lastGone.activeId, "")
assert.strictEqual(accounts.active(lastGone), null)

let realAndPending = accounts.add(accounts.add(accounts.emptyList(), account("ada@example.com")), account(""))
assert.strictEqual(accounts.remove(realAndPending, "ada@example.com").activeId, "")
assert.strictEqual(accounts.count(accounts.remove(realAndPending, "ada@example.com")), 1)

deepEqual(accounts.remove(three, "nobody@example.com"), three)
deepEqual(accounts.remove(realAndPending, ""), realAndPending, "an empty id must not sweep out every pending row")
assert.notStrictEqual(accounts.remove(three, "nobody@example.com"), three)


const beforeSet = serializedSnapshot(three)
let switched = accounts.setActive(three, "cid@example.com")
assert.strictEqual(serializedSnapshot(three), beforeSet, "setActive leaves its input alone")
assert.strictEqual(switched.activeId, "cid@example.com")
assert.strictEqual(accounts.active(switched).id, "cid@example.com")
assert.strictEqual(accounts.count(switched), 3)

deepEqual(accounts.setActive(three, "nobody@example.com"), three)
deepEqual(accounts.setActive(three, ""), three)
deepEqual(accounts.setActive(realAndPending, ""), realAndPending)


deepEqual(accounts.load(""), accounts.emptyList())
deepEqual(accounts.load("{not json"), accounts.emptyList())
deepEqual(accounts.load("[]"), accounts.emptyList(), "an array is not a list of accounts")
deepEqual(accounts.load("null"), accounts.emptyList())
deepEqual(accounts.load(null), accounts.emptyList())
assert.strictEqual(accounts.isSerializedList(""), false)
assert.strictEqual(accounts.isSerializedList("{not json"), false)
assert.strictEqual(accounts.isSerializedList(JSON.stringify({
  version: accounts.VERSION, accounts: []
})), true, "a real empty first-run file is distinguishable from a failed read")
assert.strictEqual(accounts.isSerializedList(JSON.stringify({
  version: accounts.VERSION + 1, accounts: []
})), false, "a newer format must not be mistaken for this build's list")
deepEqual(accounts.load(JSON.stringify({ accounts: [] })), accounts.emptyList(), "no version at all")
deepEqual(accounts.load(JSON.stringify({
  version: accounts.VERSION + 99,
  accounts: [{ id: "ada@example.com", email: "ada@example.com" }],
  activeId: "ada@example.com"
})), accounts.emptyList(), "a newer format is discarded rather than half-read")
deepEqual(accounts.load(JSON.stringify({ version: accounts.VERSION, accounts: "nope", activeId: "x" })),
  accounts.emptyList(), "accounts that is not an array")

const repaired = accounts.load(JSON.stringify({
  version: accounts.VERSION,
  accounts: [{ email: "ada@example.com" }, { email: "bob@example.com" }],
  activeId: "gone@example.com"
}))
assert.strictEqual(repaired.activeId, "ada@example.com")
assert.strictEqual(repaired.accounts[0].id, "ada@example.com", "the id is recomputed from the address")

const pendingFile = accounts.load(JSON.stringify({
  version: accounts.VERSION, accounts: [{ email: "" }], activeId: "ada@example.com"
}))
assert.strictEqual(accounts.count(pendingFile), 1)
assert.strictEqual(pendingFile.activeId, "")

const messy = accounts.load(JSON.stringify({
  version: accounts.VERSION,
  accounts: [null, "ada@example.com", { email: "bob@example.com" }, 7],
  activeId: "bob@example.com"
}))
assert.strictEqual(accounts.count(messy), 1)
assert.strictEqual(messy.activeId, "bob@example.com")


let saved = accounts.emptyList()
saved = accounts.add(saved, account("ada@example.com", { label: "工作邮箱" }))
saved = accounts.add(saved, account("bob@example.com", { label: "Personal" }))
saved = accounts.add(saved, account("", { clientId: "cid5", pending: true }))
saved = accounts.setActive(saved, "bob@example.com")

const text = accounts.serialize(saved)
assert.strictEqual(text.indexOf("\n"), -1, "serialize must produce a single line")
assert.strictEqual(accounts.serialize(accounts.emptyList()).indexOf("\n"), -1)

const reloaded = accounts.load(text)
deepEqual(reloaded, saved, "order, ids and the selection all survive")
assert.strictEqual(reloaded.activeId, "bob@example.com")
assert.strictEqual(accounts.label(reloaded.accounts[0]), "工作邮箱", "non-ASCII labels survive")
assert.strictEqual(accounts.count(reloaded), 3)

const multiline = accounts.serialize(accounts.add(accounts.emptyList(), account("ada@example.com", { label: "a\nb" })))
assert.strictEqual(multiline.indexOf("\n"), -1)
assert.strictEqual(accounts.load(multiline).accounts[0].label, "a\nb")

const damaged = JSON.stringify({ version: accounts.VERSION, accounts: [{
  email: "ada", clientId: "saved-client", clientSecret: "saved-secret"
}], activeId: "" })
const unfixable = accounts.load(damaged)
assert.strictEqual(unfixable.accounts[0].email, "ada")
assert.strictEqual(unfixable.accounts[0].id, "")
const typing = accounts.add(accounts.emptyList(), { email: "", pending: true })
assert.strictEqual(typing.accounts[0].email, "")
const configured = accounts.add(accounts.emptyList(), { email: "ada@example.org", pending: true })
assert.strictEqual(configured.accounts[0].pending, false)
let recovered = accounts.add(accounts.load(damaged), account("bob@example.com"))
const payload = accounts.savedOnly(recovered)
assert.strictEqual(accounts.count(payload), 2, "adding a mailbox must preserve a damaged saved row")
deepEqual(payload.accounts.map(currentAccount => currentAccount.email), ["ada", "bob@example.com"])
assert.strictEqual(accounts.dropsNamedMailbox(recovered, payload), false)

const withDraft = accounts.savedOnly(saved)
assert.strictEqual(accounts.count(saved), 3, "savedOnly leaves its input alone")
assert.strictEqual(accounts.count(withDraft), 2, "the draft row is not written")
deepEqual(withDraft.accounts.map(currentAccount => currentAccount.id), ["ada@example.com", "bob@example.com"])
assert.strictEqual(withDraft.activeId, "bob@example.com", "the selection is kept")
assert.strictEqual(accounts.draftCount(saved), 1)

// Invariant: Missing id alone cannot classify a configured saved mailbox as a discardable draft.
let broken = accounts.emptyList()
broken = accounts.add(broken, account("ada@example.com"))
broken = accounts.add(broken, account("ada", { clientId: "saved-client" }))
assert.strictEqual(accounts.count(accounts.savedOnly(broken)), 2,
  "a mailbox with an unusable address is kept, not quietly deleted")
assert.strictEqual(accounts.draftCount(broken), 0)

let hollow = accounts.emptyList()
hollow = accounts.add(hollow, account("ada@example.com"))
hollow = accounts.add(hollow, { email: "" })
assert.strictEqual(accounts.count(accounts.savedOnly(hollow)), 1)
assert.strictEqual(accounts.carriesData({ email: "" }), false)
assert.ok(accounts.carriesData({ id: "", clientId: "saved-client" }))

// Invariant: Retaining one new mailbox does not authorize dropping any previously persisted identity.
assert.ok(accounts.dropsNamedMailbox(broken, accounts.emptyList()))
assert.strictEqual(accounts.dropsNamedMailbox(saved, accounts.savedOnly(saved)), false)
assert.strictEqual(accounts.dropsNamedMailbox(broken, accounts.savedOnly(broken)), false)

let activeDraft = accounts.add(accounts.emptyList(), account("ada@example.com"))
activeDraft = accounts.add(activeDraft, account(""))
activeDraft.activeId = ""
assert.strictEqual(accounts.savedOnly(activeDraft).activeId, "ada@example.com",
  "a list written with no selection still names a mailbox")

assert.strictEqual(accounts.count(accounts.savedOnly(
  accounts.add(accounts.emptyList(), { email: "", pending: true }))), 0)
assert.strictEqual(accounts.serialize(accounts.savedOnly(saved)).indexOf("\n"), -1)

const damagedDraftLookalike = accounts.add(accounts.emptyList(), {
  email: "ada", clientId: "saved-client"
})
assert.strictEqual(accounts.count(accounts.discardDraftAt(damagedDraftLookalike, 0)), 1,
  "only a row marked pending may be discarded as a draft")


let pendingList = accounts.emptyList()
pendingList = accounts.add(pendingList, { email: "one@example.com", clientId: "c1" })
pendingList = accounts.add(pendingList, { email: "", clientId: "c2", pending: true })
pendingList = accounts.add(pendingList, { email: "two@example.com", clientId: "c3" })
assert.strictEqual(accounts.count(pendingList), 3)

const withoutPending = accounts.removeAt(pendingList, 1)
assert.strictEqual(accounts.count(withoutPending), 2)
assert.strictEqual(withoutPending.accounts[1].email, "two@example.com")
assert.strictEqual(accounts.count(pendingList), 3, "the input is left alone")

const activeGone = accounts.removeAt(withoutPending, 0)
assert.strictEqual(accounts.count(activeGone), 1)
assert.strictEqual(activeGone.activeId, "two@example.com")

assert.strictEqual(accounts.count(accounts.removeAt(pendingList, 99)), 3)
assert.strictEqual(accounts.count(accounts.removeAt(pendingList, -1)), 3)
assert.strictEqual(accounts.count(accounts.removeAt(pendingList, "nonsense")), 3)

assert.strictEqual(accounts.count(accounts.discardDraftAt(pendingList, 1)), 2)
assert.strictEqual(accounts.count(accounts.discardDraftAt(pendingList, 0)), 3)


{
  const legacy = accounts.load(JSON.stringify({version:1, accounts:[{
    email:"Jane@workspace.example", clientId:"saved-client", clientSecret:"saved-secret"
  }], activeId:"jane@workspace.example"}))
  assert.strictEqual(accounts.active(legacy).provider, "gmail")
  assert.strictEqual(accounts.active(legacy).id, "jane@workspace.example")
  assert.strictEqual(accounts.active(legacy).clientId, "saved-client")
  assert.strictEqual(accounts.active(legacy).clientSecret, "saved-secret")
  assert.strictEqual(accounts.makeAccount({email:"person@work.example",provider:" GMAIL "}).provider, "gmail")
  const persisted = accounts.namedIds(legacy)
  assert.ok(accounts.dropsAnyId(persisted, accounts.emptyList()))
  assert.strictEqual(accounts.dropsAnyId(persisted, accounts.savedOnly(legacy)), false)
  assert.strictEqual(accounts.withoutId(["a", "b", "c"], "b").join(","), "a,c")
  assert.strictEqual(accounts.withoutId(null, "b").length, 0)
}

{
  assert.strictEqual(accounts.makeAccount({ email: "j@gmail.com" }).signature, "")
  assert.strictEqual(accounts.makeAccount({
    email: "j@gmail.com", signature: "  Maarten\nmadra.nl  "
  }).signature, "Maarten\nmadra.nl", "the ends are trimmed, the middle is not")

  const list = accounts.add(accounts.emptyList(), account("jane@gmail.com"))
  const before = serializedSnapshot(list)

  const signed = accounts.setSignature(list, "jane@gmail.com", "Jane\nRoe")
  assert.strictEqual(accounts.find(signed, "jane@gmail.com").signature, "Jane\nRoe")
  assert.strictEqual(serializedSnapshot(list), before, "the list handed in is not edited")

  const entry = accounts.find(signed, "jane@gmail.com")
  assert.strictEqual(entry.clientId, "cid")
  assert.strictEqual(entry.clientSecret, "secret")
  assert.strictEqual(entry.provider, "gmail")
  assert.strictEqual(signed.activeId, "jane@gmail.com")

  assert.strictEqual(accounts.find(accounts.setSignature(signed, "jane@gmail.com", ""),
    "jane@gmail.com").signature, "")

  assert.strictEqual(serializedSnapshot(accounts.setSignature(list, "nobody@gmail.com", "x")), before)
  assert.strictEqual(serializedSnapshot(accounts.setSignature(list, "", "x")), before)

  // Invariant: Newlines in signatures must remain escaped inside one persistence frame.
  const stored = accounts.serialize(signed)
  assert.ok(stored.indexOf("\n") < 0, "no raw newline reaches the writer")
  const reloaded = accounts.load(stored)
  assert.strictEqual(accounts.find(reloaded, "jane@gmail.com").signature, "Jane\nRoe",
    "what was typed comes back")

  const both = accounts.add(signed, account("john@gmail.com"))
  assert.strictEqual(accounts.find(both, "john@gmail.com").signature, "")
  assert.strictEqual(accounts.find(both, "jane@gmail.com").signature, "Jane\nRoe")
}


const named = accounts.setLabel(
  accounts.add(accounts.emptyList(), { email: "me@gmail.com", provider: "gmail" }),
  "me@gmail.com", "  Private  ")
assert.strictEqual(named.accounts[0].label, "Private", "trimmed on the way in")
assert.strictEqual(accounts.label(named.accounts[0]), "Private")

const cleared = accounts.setLabel(named, "me@gmail.com", "   ")
assert.strictEqual(cleared.accounts[0].label, "")
assert.strictEqual(accounts.label(cleared.accounts[0]), "me")

assert.strictEqual(
  accounts.serialize(accounts.setLabel(named, "nobody@example.org", "Ghost")),
  accounts.serialize(named))

const withBoth = accounts.setSignature(named, "me@gmail.com", "Best, me")
assert.strictEqual(withBoth.accounts[0].label, "Private")
assert.strictEqual(withBoth.accounts[0].signature, "Best, me")
assert.strictEqual(
  accounts.setLabel(withBoth, "me@gmail.com", "Personal").accounts[0].signature,
  "Best, me", "naming a mailbox does not forget its signature")

// Invariant: Rebuilding an edited row must preserve the active selection instead of applying Add's first-account behavior.
const trio = accounts.add(accounts.add(accounts.add(accounts.emptyList(),
  account("ada@example.com")),
  account("bob@example.com")),
  account("cid@example.com"))
const bobActive = accounts.setActive(trio, "bob@example.com")
const cidActive = accounts.setActive(trio, "cid@example.com")
const beforeReplace = serializedSnapshot(cidActive)

const cidEdited = accounts.replaceAt(cidActive, 2,
  Object.assign({}, cidActive.accounts[2], { clientId: "changed-client" }))
assert.strictEqual(serializedSnapshot(cidActive), beforeReplace, "replaceAt leaves its input alone")
assert.strictEqual(accounts.count(cidEdited), 3)
assert.strictEqual(cidEdited.activeId, "cid@example.com",
  "editing the active row keeps it active")
assert.strictEqual(cidEdited.accounts[2].clientId, "changed-client")
assert.strictEqual(cidEdited.accounts[2].provider, "gmail", "and keeps the rest of the row")

const adaEditedUnderCid = accounts.replaceAt(cidActive, 0,
  Object.assign({}, cidActive.accounts[0], { label: "Work" }))
assert.strictEqual(adaEditedUnderCid.activeId, "cid@example.com",
  "editing another row does not move the selection to it")
assert.strictEqual(adaEditedUnderCid.accounts[0].label, "Work")

const bobEditedUnderCid = accounts.replaceAt(cidActive, 1,
  Object.assign({}, cidActive.accounts[1], { label: "Home" }))
assert.strictEqual(bobEditedUnderCid.activeId, "cid@example.com",
  "nor to the first row, whichever row was edited")

const bobRenamed = accounts.replaceAt(bobActive, 1,
  Object.assign({}, bobActive.accounts[1], { email: "robert@example.com" }))
assert.strictEqual(bobRenamed.accounts[1].id, "robert@example.com")
assert.strictEqual(bobRenamed.activeId, "robert@example.com")

const collision = Object.assign({}, cidActive.accounts[1], { email: "ada@example.com", provider: "gmail" })
assert.strictEqual(accounts.collidingId(cidActive, 1, collision), "ada@example.com")
const refusedEdit = accounts.replaceAt(cidActive, 1, collision)
assert.strictEqual(accounts.count(refusedEdit), 3)
assert.strictEqual(refusedEdit.accounts[0].id, "ada@example.com")
assert.strictEqual(refusedEdit.accounts[1].id, "bob@example.com")
assert.strictEqual(refusedEdit.activeId, "cid@example.com")

const draftBeside = accounts.add(bobActive, { email: "", pending: true })
assert.strictEqual(draftBeside.activeId, "bob@example.com")
const draftNamed = accounts.replaceAt(draftBeside, 3,
  Object.assign({}, draftBeside.accounts[3], { email: "dee@example.com" }))
assert.strictEqual(draftNamed.accounts[3].id, "dee@example.com")
assert.strictEqual(draftNamed.activeId, "bob@example.com")

const nothingActive = accounts.replaceAt(
  { version: accounts.VERSION, accounts: [{ id: "", email: "", provider: "gmail", pending: true }], activeId: "" },
  0, { email: "eve@example.com" })
assert.strictEqual(nothingActive.activeId, "eve@example.com")

assert.strictEqual(serializedSnapshot(accounts.replaceAt(cidActive, 3, account("x@example.com"))), beforeReplace)
assert.strictEqual(serializedSnapshot(accounts.replaceAt(cidActive, -1, account("x@example.com"))), beforeReplace)
{
  const watched = accounts.toggleMonitored(named, "me@gmail.com", "Label_7")
  deepEqual(watched.accounts[0].monitored, ["Label_7"])
  deepEqual(accounts.toggleMonitored(watched, "me@gmail.com", "Label_7").accounts[0].monitored, [],
    "toggling again stops watching")
  const two = accounts.toggleMonitored(watched, "me@gmail.com", "Label_9")
  deepEqual(two.accounts[0].monitored, ["Label_7", "Label_9"])
  deepEqual(accounts.setLabel(two, "me@gmail.com", "Work").accounts[0].monitored, ["Label_7", "Label_9"],
    "naming the mailbox keeps what it watches")
  deepEqual(accounts.toggleMonitored(two, "nobody@example.org", "x").accounts[0].monitored, ["Label_7", "Label_9"])
  deepEqual(accounts.toggleMonitored(two, "me@gmail.com", "  ").accounts[0].monitored, ["Label_7", "Label_9"])
  deepEqual(accounts.load(accounts.serialize(two)).accounts[0].monitored, ["Label_7", "Label_9"],
    "and it is written to disk and read back")
}


{
  const rich = accounts.setSignatureHtml(named, "me@gmail.com", " <p>Ada</p> ")
  assert.strictEqual(rich.accounts[0].signatureHtml, "<p>Ada</p>")
  assert.strictEqual(accounts.setSignature(rich, "me@gmail.com", "Ada").accounts[0].signatureHtml, "<p>Ada</p>")
  assert.strictEqual(accounts.setSignatureHtml(rich, "me@gmail.com", "").accounts[0].signatureHtml, "")
  assert.strictEqual(accounts.load(accounts.serialize(rich)).accounts[0].signatureHtml, "<p>Ada</p>")
}

{
  const gmail = accounts.add(accounts.emptyList(),
    { email: "me@example.org", provider: "gmail" })
  const id = gmail.accounts[0].id
  assert.strictEqual(gmail.accounts[0].senderName, "", "no name until one is given")

  const named = accounts.setSenderName(gmail, id, "  Jane   Example ")
  assert.strictEqual(named.accounts[0].senderName, "Jane Example")
  assert.strictEqual(serializedSnapshot(gmail), serializedSnapshot(accounts.add(accounts.emptyList(),
    { email: "me@example.org", provider: "gmail" })),
    "the input list is left alone")
  assert.strictEqual(accounts.load(accounts.serialize(named)).accounts[0].senderName, "Jane Example",
    "a saved name comes back from the file")
  assert.strictEqual(accounts.setLabel(named, id, "Personal").accounts[0].senderName, "Jane Example",
    "naming the mailbox does not forget the sender name")
  assert.strictEqual(accounts.setSenderName(named, id, "   ").accounts[0].senderName, "",
    "empty clears it, so the address goes out alone")

  assert.strictEqual(accounts.senderNameText("Jane\r\nExample\t\u0007"), "Jane Example")
}

for (const provider of ["outlook", "imap", "jmap", "hey", "pigeon", " IMAP ", 42, {}, []]) {
  const original = {version:1, activeId:"owner@example.org", accounts:[
    {email:"owner@example.org", provider:"gmail"},
    {email:"other@example.org", provider, imap:{username:"other@example.org"}}
  ]}
  const serialized = JSON.stringify(original)
  assert.strictEqual(accounts.supportsGmailAccounts(serialized), false)
  assert.strictEqual(accounts.isSerializedList(serialized), false)
  assert.throws(() => accounts.load(serialized), /accounts_provider_unsupported/)
  assert.throws(() => accounts.makeAccount(original.accounts[1]), /accounts_provider_unsupported/)
  assert.throws(() => accounts.add(original, account("third@example.org")), /accounts_provider_unsupported/)
  assert.throws(() => accounts.serialize(original), /accounts_provider_unsupported/)
  assert.strictEqual(JSON.stringify(original), serialized, "an unsupported list is never changed")
}
assert.strictEqual(accounts.supportsGmailAccounts("broken"), true, "read failures retain their separate handling")
for (const invalid of ["imap:owner@example.org", "ow\u0000ner@example.org", "ow\u007fner@example.org"]) {
  assert.strictEqual(accounts.accountId(invalid), "")
}

const restricted = accounts.add(accounts.emptyList(), {
  email:"restricted@workspace.example", refusals:{send:"Read only", archive:false}
})
const renamedRestricted = accounts.setLabel(restricted, "restricted@workspace.example", "Work")
deepEqual(renamedRestricted.accounts[0].refusals, {send:"Read only", archive:false})
deepEqual(accounts.load(accounts.serialize(renamedRestricted)).accounts[0].refusals, restricted.accounts[0].refusals)
renamedRestricted.accounts[0].refusals.send = "Changed"
assert.strictEqual(restricted.accounts[0].refusals.send, "Read only", "withdrawals are copied rather than shared")

console.log("test_accounts.js ok")

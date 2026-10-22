.pragma library

.import "Aliases.js" as Aliases

// Invariant: Account changes return fresh records so QML bindings observe them.

var VERSION = 1

var EMAIL_PATTERN = /^[^\s@]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/

function emptyList() {
  return { version: VERSION, accounts: [], activeId: "" }
}

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function isObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function parseJson(text, fallback) {
  try {
    var parsed = JSON.parse(String(text || ""))
    return parsed === null || parsed === undefined ? fallback : parsed
  } catch (error) {
    return fallback
  }
}

// Invariant: A failed read must remain distinguishable from an empty account file before replacing live accounts.
function isSerializedList(text) {
  var raw = parseJson(text, null)
  return isObject(raw) && Number(raw.version) === VERSION
    && Array.isArray(raw.accounts)
}

function isValidEmail(value) {
  return EMAIL_PATTERN.test(trimmed(value))
}

function calendarProvider(raw) {
  var account = raw || {}
  var provider = trimmed(account.provider).toLowerCase()
  if (provider === "gmail" || provider === "") return "google"
  if (provider === "outlook") return "microsoft"
  if (provider !== "imap") return ""
  var host = trimmed(account.imap && account.imap.imapHost).toLowerCase()
  var email = trimmed(account.email).toLowerCase()
  var domain = email.lastIndexOf("@") >= 0 ? email.substring(email.lastIndexOf("@") + 1) : ""
  return host === "imap.mail.me.com" || ["icloud.com", "me.com", "mac.com"].indexOf(domain) >= 0
    ? "icloud" : ""
}

// Invariant: Gmail keeps its historical bare-address id; other providers need prefixes so one address can name separate mailboxes.
function accountId(email, provider) {
  if (!isValidEmail(email)) return ""
  var address = trimmed(email).toLowerCase()
  var kind = normalizeProvider(provider)
  return kind === DEFAULT_PROVIDER ? address : kind + ":" + address
}

// Invariant: Accounts written before provider selection existed are Gmail accounts.
var PROVIDERS = ["gmail", "outlook", "hey", "imap", "jmap"]
var DEFAULT_PROVIDER = "gmail"

function normalizeProvider(value) {
  var name = trimmed(value).toLowerCase()
  for (var providerIndex = 0; providerIndex < PROVIDERS.length; providerIndex++) {
    if (PROVIDERS[providerIndex] === name) return name
  }
  return DEFAULT_PROVIDER
}

// Invariant: Persist only non-secret server settings. Invalid ports use defaults; clamping would silently select an unintended endpoint.
function portOr(value, fallback) {
  var port = Math.floor(Number(value))
  if (!isFinite(port) || port < 1 || port > 65535) return fallback
  return port
}

function makeImapSettings(raw) {
  var values = raw || {}
  return {
    imapHost: trimmed(values.imapHost),
    imapPort: portOr(values.imapPort, 993),
    smtpHost: trimmed(values.smtpHost),
    smtpPort: portOr(values.smtpPort, 465),
    username: trimmed(values.username),
    aliases: Aliases.parse(values.aliases),
    insecure: values.insecure === true,
    tenant: trimmed(values.tenant),
    send: trimmed(values.send)
  }
}

// Invariant: Persist learned JMAP identity fields, not credentials or mutable session URLs and capabilities.
function makeJmapSettings(raw) {
  var values = raw || {}
  return {
    sessionUrl: trimmed(values.sessionUrl),
    username: trimmed(values.username),
    authScheme: jmapScheme(values.authScheme),
    accountId: trimmed(values.accountId)
  }
}

// Invariant: A partial sign-in result must not erase a previously learned field or the typed username.
function jmapSettingsAfterSignIn(settings, result) {
  var current = makeJmapSettings(settings)
  var learned = result || {}
  return makeJmapSettings({
    sessionUrl: trimmed(learned.sessionUrl) !== "" ? learned.sessionUrl : current.sessionUrl,
    username: current.username,
    authScheme: trimmed(learned.authScheme) !== "" ? learned.authScheme : current.authScheme,
    accountId: trimmed(learned.accountId) !== "" ? learned.accountId : current.accountId
  })
}

// Invariant: Discovery mode none is not an account authentication scheme.
function jmapScheme(value) {
  var name = trimmed(value).toLowerCase()
  return name === "bearer" ? "bearer" : "basic"
}

// Invariant: Pending setup retains its settings without acquiring an addressable account id.
function makeAccount(account) {
  var raw = account || {}
  var email = trimmed(raw.email)
  var provider = normalizeProvider(raw.provider)
  return {
    id: accountId(email, provider),
    email: email,
    provider: provider,
    clientId: trimmed(raw.clientId),
    clientSecret: trimmed(raw.clientSecret),
    imap: makeImapSettings(raw.imap),
    jmap: makeJmapSettings(raw.jmap),
    label: trimmed(raw.label),
    senderName: senderNameText(raw.senderName),
    signature: trimmed(raw.signature),
    // Invariant: Stored signature markup has passed through Signature.js sanitization; raw file bytes are never persisted here.
    signatureHtml: trimmed(raw.signatureHtml),
    monitored: idList(raw.monitored),
    // Invariant: A damaged saved address is not a setup draft; a valid address clears pending status automatically.
    pending: raw.pending === true && !isValidEmail(email)
  }
}

// Invariant: Repair legacy IMAP addresses only on load; adopting usernames while editing would change the address field unexpectedly.
function repairedAddress(entry) {
  var raw = entry || {}
  if (isValidEmail(raw.email)) return raw
  var provider = normalizeProvider(raw.provider)
  if (provider !== "imap" && provider !== "outlook") return raw
  var username = trimmed((raw.imap || {}).username)
  if (!isValidEmail(username)) return raw
  var next = {}
  for (var key in raw) next[key] = raw[key]
  next.email = username
  return next
}

function copyList(list) {
  var source = list || emptyList()
  return {
    version: VERSION,
    accounts: Array.isArray(source.accounts) ? source.accounts.slice() : [],
    activeId: String(source.activeId || "")
  }
}

// Invariant: Empty ids must not select an arbitrary pending account.
function indexOfId(accounts, id) {
  var key = trimmed(id)
  if (!key) return -1
  for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
    if (accounts[accountIndex] && accounts[accountIndex].id === key) return accountIndex
  }
  return -1
}

function find(list, id) {
  var source = copyList(list)
  var at = indexOfId(source.accounts, id)
  return at < 0 ? null : source.accounts[at]
}

function active(list) {
  return find(list, (list || {}).activeId)
}

function count(list) {
  var source = list || {}
  return Array.isArray(source.accounts) ? source.accounts.length : 0
}

// Invariant: Session readiness is not account existence; asynchronous restore must never make Add overwrite a saved mailbox.
function hasSavedAccounts(list) {
  var source = list || {}
  var values = Array.isArray(source.accounts) ? source.accounts : []
  for (var accountIndex = 0; accountIndex < values.length; accountIndex++) {
    var entry = values[accountIndex] || {}
    if (trimmed(entry.id) !== "" || isValidEmail(entry.email)) return true
  }
  return false
}

function label(account) {
  var raw = account || {}
  var name = trimmed(raw.label)
  if (name) return name
  var local = trimmed(raw.email).split("@")[0]
  return local || "New account"
}

// Invariant: Re-adding an existing identity preserves its list position instead of creating a duplicate.
function add(list, account) {
  var next = copyList(list)
  var entry = makeAccount(account)
  var at = indexOfId(next.accounts, entry.id)
  if (at >= 0) next.accounts[at] = entry
  else next.accounts.push(entry)
  // Invariant: Adding another mailbox must not replace an existing active selection.
  if (entry.id && indexOfId(next.accounts, next.activeId) < 0) next.activeId = entry.id
  return next
}

// Invariant: Editing a row into another mailbox identity must refuse the collision instead of deleting either mailbox.
function collidingId(list, index, account) {
  var entry = makeAccount(account)
  if (!entry.id) return ""
  var other = indexOfId((list || {}).accounts || [], entry.id)
  var at = Math.floor(Number(index))
  if (other >= 0 && other !== at) return entry.id
  return ""
}

function replaceAt(list, index, account) {
  var next = copyList(list)
  var at = Math.floor(Number(index))
  if (!isFinite(at) || at < 0 || at >= next.accounts.length) return next
  if (collidingId(next, at, account)) return next
  var entry = makeAccount(account)
  next.accounts[at] = entry
  if (entry.id && (next.activeId === "" || indexOfId(next.accounts, next.activeId) < 0))
    next.activeId = entry.id
  return next
}

function namedIds(list) {
  var values = Array.isArray((list || {}).accounts) ? list.accounts : []
  var ids = []
  for (var accountIndex = 0; accountIndex < values.length; accountIndex++) {
    var id = trimmed((values[accountIndex] || {}).id)
    if (id) ids.push(id)
  }
  return ids
}

function withoutId(ids, id) {
  var kept = []
  var values = Array.isArray(ids) ? ids : []
  for (var accountIndex = 0; accountIndex < values.length; accountIndex++) {
    if (values[accountIndex] !== id) kept.push(values[accountIndex])
  }
  return kept
}

function dropsAnyId(ids, payload) {
  var wanted = Array.isArray(ids) ? ids : []
  var kept = namedIds(payload)
  for (var wantedIndex = 0; wantedIndex < wanted.length; wantedIndex++) {
    var found = false
    for (var keptIndex = 0; keptIndex < kept.length; keptIndex++) {
      if (kept[keptIndex] === wanted[wantedIndex]) { found = true; break }
    }
    if (!found) return true
  }
  return false
}

function nextActiveId(accounts, from) {
  for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
    var entry = accounts[(from + accountIndex) % accounts.length]
    if (entry && entry.id) return entry.id
  }
  return ""
}

function remove(list, id) {
  var next = copyList(list)
  var at = indexOfId(next.accounts, id)
  if (at < 0) return next
  var wasActive = next.accounts[at].id === next.activeId
  next.accounts.splice(at, 1)
  if (wasActive) next.activeId = nextActiveId(next.accounts, at)
  return next
}

// Invariant: Missing ids are stale requests, not permission to remove an arbitrary pending row.
function removeAt(list, index) {
  var source = copyList(list)
  var at = Math.floor(Number(index))
  if (!isFinite(at) || at < 0 || at >= source.accounts.length) return source
  var removed = source.accounts[at]
  source.accounts.splice(at, 1)
  if (removed.id !== "" && source.activeId === removed.id)
    source.activeId = nextActiveId(source.accounts, at)
  return source
}

// Invariant: Confirmation retains both identity and position so a changed list cannot redirect removal.
function removalRequest(list, index) {
  var values = Array.isArray((list || {}).accounts) ? list.accounts : []
  if (values.length <= 1) return null
  var at = Math.floor(Number(index))
  if (!isFinite(at) || at < 0 || at >= values.length) return null
  var entry = values[at] || {}
  if (!entry.id) return null
  return { id: String(entry.id || ""), email: String(entry.email || ""), index: at }
}

function confirmRemoval(list, request) {
  if (!request) return -1
  var values = Array.isArray((list || {}).accounts) ? list.accounts : []
  var at = Math.floor(Number(request.index))
  if (!isFinite(at) || at < 0 || at >= values.length) return -1
  var entry = values[at] || {}
  var id = String(request.id || "")
  return id !== "" && String(entry.id || "") === id ? at : -1
}

function discardDraftAt(list, index) {
  var source = copyList(list)
  var at = Math.floor(Number(index))
  if (!isFinite(at) || at < 0 || at >= source.accounts.length) return source
  // Invariant: Only explicitly pending setup may be discarded without confirmation; a damaged saved mailbox may also lack an id.
  if (source.accounts[at].pending !== true) return source
  return removeAt(source, at)
}

function idList(value) {
  var list = Array.isArray(value) ? value : []
  var result = []
  for (var aliasIndex = 0; aliasIndex < list.length; aliasIndex++) {
    var item = trimmed(list[aliasIndex])
    if (item !== "" && result.indexOf(item) < 0) result.push(item)
  }
  return result
}

function setMonitored(list, id, labelIds) {
  var next = copyList(list)
  var at = indexOfId(next.accounts, id)
  if (at < 0) return next
  var entry = makeAccount(next.accounts[at])
  entry.monitored = idList(labelIds)
  next.accounts[at] = entry
  return next
}

function toggleMonitored(list, id, labelId) {
  var next = copyList(list)
  var at = indexOfId(next.accounts, id)
  if (at < 0) return next
  var entry = makeAccount(next.accounts[at])
  var key = trimmed(labelId)
  if (key === "") return next
  var index = entry.monitored.indexOf(key)
  if (index >= 0) entry.monitored.splice(index, 1)
  else entry.monitored.push(key)
  next.accounts[at] = entry
  return next
}

function setLabel(list, id, text) {
  var next = copyList(list)
  var at = indexOfId(next.accounts, id)
  if (at < 0) return next
  var entry = makeAccount(next.accounts[at])
  entry.label = trimmed(text)
  next.accounts[at] = entry
  return next
}

// Invariant: IMAP and Outlook use the local sender name; the other providers own their sender identities.
function namesSender(provider) {
  var id = String(provider || "")
  return id === "imap" || id === "outlook"
}

// Invariant: A sender name is one header value; pasted control whitespace cannot introduce a header.
function senderNameText(value) {
  return trimmed(String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/ {2,}/g, " "))
}

function setSenderName(list, id, text) {
  var next = copyList(list)
  var at = indexOfId(next.accounts, id)
  if (at < 0) return next
  var entry = makeAccount(next.accounts[at])
  entry.senderName = senderNameText(text)
  next.accounts[at] = entry
  return next
}

// Invariant: signatures belong to one mailbox and receive no automatic separator.
function setSignatureHtml(list, id, html) {
  var next = copyList(list)
  var at = indexOfId(next.accounts, id)
  if (at < 0) return next
  var entry = makeAccount(next.accounts[at])
  entry.signatureHtml = trimmed(html)
  next.accounts[at] = entry
  return next
}

function setSignature(list, id, text) {
  var next = copyList(list)
  var at = indexOfId(next.accounts, id)
  if (at < 0) return next
  var entry = makeAccount(next.accounts[at])
  entry.signature = trimmed(text)
  next.accounts[at] = entry
  return next
}

function setActive(list, id) {
  var next = copyList(list)
  var at = indexOfId(next.accounts, id)
  if (at >= 0) next.activeId = next.accounts[at].id
  return next
}

// Invariant: Unreadable startup data must still allow first-run setup; live replacement has a separate validation gate.
function load(text) {
  var raw = parseJson(text, null)
  if (!isSerializedList(text)) return emptyList()

  var next = emptyList()
  var entries = Array.isArray(raw.accounts) ? raw.accounts : []
  for (var entryIndex = 0; entryIndex < entries.length; entryIndex++) {
    if (!isObject(entries[entryIndex])) continue
    var entry = makeAccount(repairedAddress(entries[entryIndex]))
    // Invariant: Derive identities from validated addresses so persisted ids cannot create aliases for the same account.
    if (entry.id && indexOfId(next.accounts, entry.id) >= 0) continue
    next.accounts.push(entry)
  }

  var wanted = trimmed(raw.activeId).toLowerCase()
  next.activeId = indexOfId(next.accounts, wanted) >= 0 ? wanted : nextActiveId(next.accounts, 0)
  return next
}

// Invariant: Persist saved mailboxes, including damaged but configured rows; discard only explicit drafts and empty legacy placeholders.
function carriesData(entry) {
  var raw = entry || {}
  if (trimmed(raw.id) !== "") return true
  var imap = raw.imap || {}
  var jmap = raw.jmap || {}
  return trimmed(imap.username) !== "" || trimmed(imap.imapHost) !== ""
    || trimmed(jmap.username) !== "" || trimmed(jmap.sessionUrl) !== ""
    || trimmed(jmap.accountId) !== ""
    || trimmed(raw.clientId) !== "" || trimmed(raw.clientSecret) !== ""
}

// Invariant: A write cannot silently omit a persisted mailbox; explicit removal must update the permitted identity set first.
function dropsNamedMailbox(list, payload) {
  var source = Array.isArray((list || {}).accounts) ? list.accounts : []
  var kept = Array.isArray((payload || {}).accounts) ? payload.accounts : []
  for (var sourceIndex = 0; sourceIndex < source.length; sourceIndex++) {
    var id = trimmed((source[sourceIndex] || {}).id)
    if (id !== "" && indexOfId(kept, id) < 0) return true
  }
  return false
}

function draftCount(list) {
  var values = Array.isArray((list || {}).accounts) ? list.accounts : []
  var drafts = 0
  for (var accountIndex = 0; accountIndex < values.length; accountIndex++) {
    if (values[accountIndex] && values[accountIndex].pending === true) drafts++
  }
  return drafts
}

function savedOnly(list) {
  var next = copyList(list)
  var kept = []
  for (var accountIndex = 0; accountIndex < next.accounts.length; accountIndex++) {
    // Invariant: An unrepaired saved mailbox retains its settings; missing identity alone does not authorize deletion.
    var entry = next.accounts[accountIndex]
    if (entry && entry.pending !== true && carriesData(entry)) kept.push(entry)
  }
  next.accounts = kept
  if (indexOfId(kept, next.activeId) < 0) next.activeId = nextActiveId(kept, 0)
  return next
}

// Invariant: Compact JSON keeps the line-oriented persistence frame intact, including escaped newlines in labels.
function serialize(list) {
  return JSON.stringify(copyList(list))
}

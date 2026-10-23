.pragma library

.import "NativeDomain.js" as NativeDomain
.import "Gmail.js" as Gmail

var DEFAULT_ID = "gmail"

function descriptor() {
  var facts = NativeDomain.FACTS.gmail
  return {
    id: "gmail", name: Gmail.NAME, auth: "oauth", mark: Gmail.MARK, logo: Gmail.MARK,
    capabilities: facts.capabilities, addressSearch: true,
    searchSyntax: "gmail", searchOperators: facts.searchOperators,
    inheritedDefault: facts.inheritedDefault,
    mailboxes: Gmail.MAILBOXES.map(function(box) {
      return {key:box.key, label:box.label, icon:box.icon,
        optional:box.optional === true, query:String(facts.queries[box.key] || "")}
    })
  }
}

var GMAIL = descriptor()

function ids() { return ["gmail"] }
function exists(id) { return String(id || "").trim().toLowerCase() === "gmail" }
function get(id) {
  if (id && !exists(id)) throw new Error("Only Gmail accounts are supported")
  return GMAIL
}
function refuses(refusals, capability) {
  return !!refusals && refusals[String(capability)] !== undefined && refusals[String(capability)] !== null
}
function can(id, capability, refusals) {
  return get(id).capabilities[String(capability)] === true && !refuses(refusals, capability)
}
function refusal(id, capability, refusals) {
  return get(id).capabilities[String(capability)] === true && refuses(refusals, capability)
    ? String(refusals[String(capability)]) : ""
}
function mailboxes(id, absent) {
  var missing = Array.isArray(absent) ? absent : []
  return get(id).mailboxes.filter(function(box) { return missing.indexOf(box.key) < 0 })
}
function mailboxIndex(id, key) {
  var list = get(id).mailboxes
  for (var index = 0; index < list.length; index++) if (list[index].key === String(key || "")) return index
  return 0
}
function mailboxFor(id, key) { return get(id).mailboxes[mailboxIndex(id, key)] }
function hasMailbox(id, key) {
  return get(id).mailboxes.some(function(box) { return box.key === String(key || "") })
}
function unreadQuery(id) { return mailboxFor(id, "unread").query }
function badge(id) { return get(id).name }
function mark(id) { return get(id).mark }
function logo(id) { return get(id).logo }
function authKind(id) { return get(id).auth }
function unavailableReason(id) { get(id); return "" }
function webHomeUrl(id) { get(id); return String(NativeDomain.FACTS.gmail.webHomeUrl) }
function calendarAttendanceMethod(id) { get(id); return "calendar.attendance" }
function calendarAttendanceUrl(id, accountId) {
  get(id)
  return "https://calendar.google.com/calendar/u/0/r?authuser=" + encodeURIComponent(String(accountId || ""))
}

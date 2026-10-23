.pragma library
.import "Gmail.js" as Gmail

function query(id, mailboxKey, searchText, defaultQuery) {
  var text = String(searchText || "").trim()
  if (text) return Gmail.searchQuery(text)
  if (mailboxKey === "inbox" && String(defaultQuery || "").trim()) return String(defaultQuery).trim()
  for (var index = 0; index < Gmail.MAILBOXES.length; index++)
    if (Gmail.MAILBOXES[index].key === mailboxKey) return Gmail.MAILBOXES[index].query
  return Gmail.MAILBOXES[0].query
}
function labelQuery(id, name) { return Gmail.labelQuery(name) }
function addressQuery(id, field, value) { return Gmail.addressQuery(field, value) }
function webMessageUrl(id, value) { return Gmail.webMessageUrl(value) }
function webBoxUrl(id, value) { return Gmail.webBoxUrl(value) }

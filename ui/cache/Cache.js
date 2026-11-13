.pragma library

// Invariant: Summary schema changes invalidate cached pages so older flags cannot drive incorrect actions.
var VERSION = 2
var MAX_QUERIES = 12
var MAX_SUMMARIES_PER_QUERY = 100

function emptyStore() {
  return { version: VERSION, account: "", profile: null, labels: [], queries: {} }
}

function isObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function queryKey(query, maxResults) {
  return String(query || "").replace(/^\s+|\s+$/g, "")
    + "|" + Math.max(1, Math.floor(Number(maxResults) || 25))
}

function queryFromKey(key) {
  return String(key || "").replace(/\|\d+$/, "")
}

// Invariant: JSON carries dates as epoch milliseconds; unconverted Date strings cannot be used by row formatting.

function dehydrate(summaries) {
  var list = Array.isArray(summaries) ? summaries : []
  var result = []
  for (var keyIndex = 0; keyIndex < list.length; keyIndex++) {
    var entry = {}
    for (var key in list[keyIndex]) {
      if (key === "date") continue
      entry[key] = list[keyIndex][key]
    }
    var at = list[keyIndex].date ? list[keyIndex].date.getTime() : NaN
    entry.dateMs = isFinite(at) ? at : null
    result.push(entry)
  }
  return result
}

function hydrate(entries) {
  var list = Array.isArray(entries) ? entries : []
  var result = []
  for (var keyIndex = 0; keyIndex < list.length; keyIndex++) {
    var summary = {}
    for (var key in list[keyIndex]) {
      if (key === "dateMs") continue
      summary[key] = list[keyIndex][key]
    }
    var at = Number(list[keyIndex].dateMs)
    summary.date = isFinite(at) && at > 0 ? new Date(at) : null
    result.push(summary)
  }
  return result
}


function copyStore(store) {
  var source = store || emptyStore()
  return {
    version: VERSION,
    account: source.account || "",
    profile: source.profile || null,
    labels: source.labels || [],
    queries: source.queries || {}
  }
}

function putQuery(store, key, page, nowMs) {
  var next = copyStore(store)
  var queries = {}
  for (var existing in next.queries) queries[existing] = next.queries[existing]
  var source = page && Array.isArray(page.summaries) ? page.summaries : []
  var capped = source.slice(0, MAX_SUMMARIES_PER_QUERY)
  queries[String(key)] = {
    summaries: dehydrate(capped),
    estimate: Math.max(0, Math.floor(Number(page && page.estimate) || 0)),
    // Invariant: A continuation after omitted cached rows would skip mail; discard it until a live page restores the boundary.
    nextPageToken: source.length > capped.length ? ""
      : String(page && page.nextPageToken ? page.nextPageToken : ""),
    at: Number(nowMs) || 0
  }
  next.queries = queries
  return next
}

function getQuery(store, key) {
  var source = store || emptyStore()
  var entry = source.queries ? source.queries[String(key)] : null
  return isObject(entry) ? entry : null
}

// Invariant: Local search rejects provider operators it cannot interpret; exact cached queries remain available.

function localSearchTerms(query) {
  var text = String(query === undefined || query === null ? "" : query)
    .replace(/^\s+|\s+$/g, "").toLowerCase()
  if (text === "") return []

  var terms = []
  var current = ""
  var quoted = false
  for (var characterIndex = 0; characterIndex < text.length; characterIndex++) {
    var character = text.charAt(characterIndex)
    if (character === '"') {
      quoted = !quoted
      continue
    }
    if (/\s/.test(character) && !quoted) {
      if (current !== "") terms.push(current)
      current = ""
    } else {
      current += character
    }
  }
  if (current !== "") terms.push(current)

  for (var termIndex = 0; termIndex < terms.length; termIndex++) {
    if (terms[termIndex].charAt(0) === "-" || terms[termIndex].indexOf(":") >= 0) return []
  }
  return terms
}

function addressSearchText(address) {
  if (!address) return ""
  return String(address.display || "") + " " + String(address.name || "")
    + " " + String(address.email || "")
}

function addressListSearchText(addresses) {
  var list = Array.isArray(addresses) ? addresses : []
  var text = ""
  for (var addressIndex = 0; addressIndex < list.length; addressIndex++) text += " " + addressSearchText(list[addressIndex])
  return text
}

function summarySearchText(summary) {
  var row = summary || {}
  return (addressSearchText(row.from)
    + addressListSearchText(row.to)
    + addressListSearchText(row.cc)
    + " " + String(row.subject || "")
    + " " + String(row.snippet || "")).toLowerCase()
}

function matchesLocalSearch(summary, terms) {
  var wanted = Array.isArray(terms) ? terms : []
  if (wanted.length === 0) return false
  var text = summarySearchText(summary)
  for (var termIndex = 0; termIndex < wanted.length; termIndex++) {
    if (text.indexOf(wanted[termIndex]) < 0) return false
  }
  return true
}

// Invariant: The newest cached copy decides identity and scope; older copies may only supplement searchable fields.
function searchSummaries(store, query, includes) {
  var terms = localSearchTerms(query)
  if (terms.length === 0) return []
  var source = store || emptyStore()
  var queries = source.queries || {}
  var keys = []
  for (var key in queries) keys.push(key)
  keys.sort(function(left, right) {
    return (Number(queries[right] && queries[right].at) || 0)
      - (Number(queries[left] && queries[left].at) || 0)
  })

  var positions = {}
  var candidates = []
  var order = 0
  for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) {
    var sourceQuery = queryFromKey(keys[keyIndex])
    var rows = hydrate(queries[keys[keyIndex]] && queries[keys[keyIndex]].summaries)
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      var row = rows[rowIndex]
      var id = String(row && row.id ? row.id : "")
      if (id === "") continue
      if (positions[id] === undefined) {
        positions[id] = candidates.length
        candidates.push({
          row: row,
          order: order++,
          eligible: typeof includes !== "function" || includes(sourceQuery, row),
          matched: false
        })
      }
      if (candidates[positions[id]].eligible && matchesLocalSearch(row, terms))
        candidates[positions[id]].matched = true
    }
  }

  var found = []
  for (var candidate = 0; candidate < candidates.length; candidate++) {
    if (candidates[candidate].matched) found.push(candidates[candidate])
  }
  found.sort(function(left, right) {
    var leftTimeMs = left.row && left.row.date ? Number(left.row.date.getTime()) : 0
    var rightTimeMs = right.row && right.row.date ? Number(right.row.date.getTime()) : 0
    if (leftTimeMs !== rightTimeMs) return rightTimeMs - leftTimeMs
    return left.order - right.order
  })
  var result = []
  for (var resultIndex = 0; resultIndex < found.length; resultIndex++) result.push(found[resultIndex].row)
  return result
}





function putLabels(store, labels, nowMs) {
  var next = copyStore(store)
  next.labels = Array.isArray(labels) ? labels : []
  return next
}

function putProfile(store, profile, nowMs) {
  var next = copyStore(store)
  next.profile = isObject(profile) ? profile : null
  if (next.profile && next.profile.email) next.account = String(next.profile.email)
  return next
}

// Invariant: A cache from another identified account must never be displayed; an unidentified profile may still use its own file.
function forAccount(store, email) {
  var address = String(email || "")
  if (address === "") return copyStore(store)
  var source = copyStore(store)
  if (source.account === "") {
    source.account = address
    return source
  }
  if (source.account.toLowerCase() === address.toLowerCase()) return source
  var fresh = emptyStore()
  fresh.account = address
  return fresh
}

function isStale(at, nowMs, ttlMs) {
  var stamp = Number(at)
  if (!isFinite(stamp) || stamp <= 0) return true
  var now = Number(nowMs) || 0
  var ttl = Math.max(0, Number(ttlMs) || 0)
  // Invariant: A backwards clock reads as temporarily fresh and must not make the entry immortal.
  return now - stamp > ttl
}


function keepNewest(bucket, limit) {
  var keys = []
  for (var key in bucket) keys.push(key)
  if (keys.length <= limit) return bucket
  keys.sort(function(left, right) {
    return (Number(bucket[right].at) || 0) - (Number(bucket[left].at) || 0)
  })
  var kept = {}
  for (var keyIndex = 0; keyIndex < limit; keyIndex++) kept[keys[keyIndex]] = bucket[keys[keyIndex]]
  return kept
}


function prune(store) {
  var next = copyStore(store)
  next.queries = keepNewest(next.queries, MAX_QUERIES)
  var capped = {}
  for (var key in next.queries) {
    var entry = next.queries[key] || {}
    var summaries = Array.isArray(entry.summaries) ? entry.summaries : []
    capped[key] = {
      summaries: summaries.slice(0, MAX_SUMMARIES_PER_QUERY),
      estimate: Math.max(0, Math.floor(Number(entry.estimate) || 0)),
      nextPageToken: summaries.length > MAX_SUMMARIES_PER_QUERY
        ? "" : String(entry.nextPageToken || ""),
      at: Number(entry.at) || 0
    }
  }
  next.queries = capped
  return next
}

import QtQuick

Item {
  id: root
  visible: false
  width: 0
  height: 0
  property var backend: null
  property string accountId: ""
  property int epoch: 0
  property var generation: 0
  property var store: ({ version: 2, account: "", profile: null, labels: [] })
  property bool loaded: false
  signal restored()

  function apply(value) {
    if (!value) return
    if (value.store) { store = value.store; return }
    var next = { version: 2, account: store.account, profile: store.profile,
      labels: store.labels }
    var fields = ["account", "profile", "labels"]
    for (var fieldIndex = 0; fieldIndex < fields.length; fieldIndex++) {
      var field = fields[fieldIndex]
      if (value[field] !== undefined) next[field] = value[field]
    }
    store = next
  }

  function request(method, parameters, callback) {
    if (!loaded || !backend || !backend.ready || !accountId) {
      if (typeof callback === "function") callback(null, "Cache is unavailable")
      return
    }
    var mine = epoch
    parameters.accountId = accountId
    parameters.generation = generation
    backend.call(method, parameters, function(value, error) {
      if (!root || mine !== root.epoch) return
      if (error && error.message === "cache_stale_generation") root.restore()
      if (!error) root.apply(value)
      if (typeof callback === "function") callback(value, error)
    })
  }

  function get(key, callback) {
    request("cache.queryGet", { key: key }, function(value, error) {
      if (typeof callback === "function") callback(value ? value.entry : null, error)
    })
  }

  function getPreview(query, limit, search, provider, ttlMs, callback) {
    request("cache.queryGet", { query: query, limit: limit, search: search,
      ttlMs: ttlMs }, callback)
  }

  // Invariant: Dates cross the process boundary only after serialization.
  function serializablePage(page) {
    var summaries = page && Array.isArray(page.summaries) ? page.summaries : []
    var rows = []
    for (var summaryIndex = 0; summaryIndex < summaries.length; summaryIndex++) {
      var row = {}
      for (var field in summaries[summaryIndex]) {
        if (field !== "date") row[field] = summaries[summaryIndex][field]
      }
      var date = summaries[summaryIndex].date
      if (date && typeof date.getTime === "function") row.dateMs = date.getTime()
      rows.push(row)
    }
    return { summaries: rows, estimate: page && page.estimate,
      nextPageToken: page && page.nextPageToken }
  }

  function putQuery(key, page) {
    request("cache.queryPut", { key: key, page: serializablePage(page) })
  }
  function putPage(query, limit, page) {
    request("cache.queryPut", { query: query, limit: limit, page: serializablePage(page) })
  }
  function putLabels(labels) { request("cache.queryLabels", { labels: labels }) }
  function putProfile(profile) { request("cache.queryProfile", { profile: profile }) }
  function bindAccount(email) { request("cache.queryBind", { email: email }) }
  function clear() { request("cache.queryClear", {}) }
  function invalidate(ids, callback) { request("cache.queryInvalidate", { ids: ids }, callback) }

  function restore() {
    var mine = ++epoch
    loaded = false
    generation = 0
    store = ({ version: 2, account: "", profile: null, labels: [] })
    if (!backend || !backend.ready || !accountId) return
    backend.call("cache.queryRestore", { accountId: accountId }, function(value, error) {
      if (!root || mine !== root.epoch) return
      if (error || !value) return
      root.generation = value.generation
      root.apply(value)
      root.loaded = true
      root.restored()
    })
  }
  Component.onCompleted: restore()
  onAccountIdChanged: restore()
  onBackendChanged: restore()
  Connections {
    target: root.backend
    ignoreUnknownSignals: true
    function onReadyChanged() { root.restore() }
  }
}

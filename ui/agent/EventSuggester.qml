import QtQuick
import "Agent.js" as Agent
import "../account/Unified.js" as Unified

Item {
  id: root

  required property var service
  required property var runner

  // Invariant: dismissed suggestions last only for this session.
  property var dismissed: []
  // Invariant: dismiss only after this suggestion is saved; closing its composer clears the pending link.
  property var pending: null
  // Invariant: cached and live body arrivals must not start the same account/message twice.
  property var waiting: []
  property var started: []
  // Invariant: only one context read prepares a job while the runner serializes starts.
  property bool preparing: false
  property int serial: 0
  // Invariant: an unsupported agent suppresses background checks until the setting or provider changes.
  property bool unavailable: false

  readonly property bool canSuggest: !!service && service.suggestEvents === true
    && service.hasAgent && service.agentAvailable !== false && !unavailable
    && service.backendCanSuggestEvents
  onCanSuggestChanged: {
    if (canSuggest) consider()
    else waiting = []
  }

  readonly property var reading: service ? service.reading : null
  readonly property var suggestions: Agent.eventSuggestions(
    Agent.lookFor(runner ? runner.eventLooks : null,
      reading ? reading.accountId : "", reading ? reading.selectedId : ""), dismissed)

  Connections {
    target: root.reading
    function onSelectedBodyChanged() { root.consider() }
  }
  Connections {
    target: root.service
    function onSuggestEventsChanged() { root.unavailable = false; root.consider() }
    // Invariant: feature availability follows its fixed minimum API revision after future releases.
    function onBackendCanSuggestEventsChanged() { root.consider() }
    function onAgentAvailableChanged() { root.unavailable = false; root.consider() }
  }
  Connections {
    target: root.runner
    ignoreUnknownSignals: true
    function onSelectedAgentChanged() { root.unavailable = false }
    function onSelectedModelChanged() { root.unavailable = false }
    function onStartingChanged() { if (!root.runner.starting) root.drain() }
    function onEventLooksChanged() { root.drain() }
    function onStartRefused(code) {
      if (String(code) === "agent_choose_claude") { root.unavailable = true; root.waiting = [] }
      root.started = []
    }
  }

  function lookedAt(accountId, messageId) {
    return Agent.lookFor(runner ? runner.eventLooks : null, accountId, messageId) !== null
  }

  function consider() {
    var account = reading
    if (!account || !canSuggest) return false
    var id = String(account.selectedId || "")
    var summary = account.selectedMessage
    if (id === "" || !summary || String(summary.id || "") !== id) return false
    // Invariant: the subject can supply the date when the body only says "see you there".
    var text = String(summary.subject || "") + "\n"
      + (account.selectedBody ? String(account.selectedBody.text || "") : "")
    if (!Agent.worthALook(summary, text, !!account.selectedUnsubscribe)) return false
    if (Agent.tooOldForEvents(Unified.messageTime(summary), Date.now())) return false
    var key = String(account.accountId || "") + " " + id
    if (started.indexOf(key) >= 0 || lookedAt(account.accountId, id)) return false
    return tryStart({ key: key, accountId: String(account.accountId || ""), id: id,
      summary: summary, folder: String(account.mailboxKey || "") })
  }

  function tryStart(look) {
    if (!canSuggest || !service.findAccount(look.accountId)) return false
    var free = !preparing && runner && !runner.starting
      && runner.activeEventLooks < Agent.EVENTS_IN_FLIGHT
    if (free && start(look)) {
      started = started.concat([look.key])
      return true
    }
    var kept = waiting.filter(function(waitingLook) { return waitingLook.key !== look.key })
    waiting = kept.concat([look])
    return false
  }

  function start(look) {
    if (!canSuggest || !service.backend || !service.backend.ready) return false
    var owner = service.findAccount(look.accountId)
    if (!owner) return false
    var token = ++serial
    var selected = typeof runner.selection === "function" ? runner.selection() : null
    preparing = true
    service.backend.call("agent.context", { accountId: look.accountId,
      requestId: "events-" + Date.now() + "-" + token, ids: [look.id],
      summaries: [look.summary], folder: look.folder, prompt: Agent.EVENTS_PROMPT },
      function(result, failure) {
        if (token !== root.serial) return
        var payload = result ? result.payload : null
        if (!root.canSuggest || root.service.findAccount(look.accountId) !== owner
            || failure || !payload || String(payload.accountId || "") !== look.accountId) {
          root.started = root.started.filter(function(key) { return key !== look.key })
        } else {
          payload.events = true
          if (!root.runner.start(payload, true, selected))
            root.started = root.started.filter(function(key) { return key !== look.key })
        }
        root.preparing = false
        root.drain()
      })
    return true
  }

  function drain() {
    if (!canSuggest) { waiting = []; return }
    started = started.filter(function(key) {
      var at = key.indexOf(" ")
      return !root.lookedAt(key.slice(0, at), key.slice(at + 1))
    })
    var queue = waiting
    waiting = []
    for (var queueIndex = 0; queueIndex < queue.length; queueIndex++) {
      var look = queue[queueIndex]
      if (!service || !service.findAccount(look.accountId)) continue
      if (started.indexOf(look.key) >= 0 || lookedAt(look.accountId, look.id)) continue
      if (!tryStart(look)) { waiting = waiting.concat(queue.slice(queueIndex + 1)); return }
    }
  }

  function dismiss(key) {
    var value = String(key || "")
    if (value !== "" && dismissed.indexOf(value) < 0) dismissed = dismissed.concat([value])
  }

  function compose(suggestion) {
    var controller = service ? service.calendarController : null
    if (!suggestion || !controller) return false
    var groups = controller.writableSourceGroups || []
    if (groups.length === 0) {
      if (reading) reading.fail("No calendar to add it to: add one in the calendar's settings first")
      return false
    }
    if (controller.composerHeld) {
      if (reading) reading.fail("Finish the event you are editing first")
      return false
    }
    pending = suggestion
    controller.composeRequested(Agent.eventPrefill(suggestion, reading ? reading.accountId : ""))
    return true
  }

  Connections {
    target: root.service ? root.service.calendarController : null
    function onEventCreated(ok, error) {
      if (!ok || !root.pending) return
      root.dismiss(root.pending.key)
      root.pending = null
    }
    function onComposeEnded() { root.pending = null }
  }
}

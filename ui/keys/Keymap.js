.pragma library

// Invariant: this table is the shared authority for shortcut dispatch, help and status hints.

// Invariant: one active context determines bindings; stale hidden focus must not enable shortcuts.
var CONTEXTS = ["list", "reader", "search", "searchSuggestions", "compose", "page", "assistant", "assistantCommands"]

var MAIL = ["list", "reader"]
var ANY = ["*"]

var BINDINGS = [
  // Invariant: popup and help contexts retain only the explicitly allowed global actions.
  { id: "cursorDown", keys: ["j", "Down"], contexts: MAIL,
    survivesOverlay: true,
    group: "Moving", label: "Move down",
    hintKey: "j / k", hint: { list: "move" } },
  { id: "cursorUp", keys: ["k", "Up"], contexts: MAIL,
    survivesOverlay: true,
    group: "Moving", label: "Move up" },
  { id: "scrollDown", keys: ["Shift+J"], contexts: ["reader"],
    survivesOverlay: true,
    group: "Moving", label: "Scroll down",
    hintKey: "Shift+J / Shift+K", hint: { reader: "scroll" } },
  { id: "scrollUp", keys: ["Shift+K"], contexts: ["reader"],
    survivesOverlay: true,
    group: "Moving", label: "Scroll up" },

  { id: "open", keys: ["Return", "Enter", "o"], contexts: MAIL,
    group: "Moving", label: "Open the selected message",
    hintKey: "o" },
  { id: "openReader", keys: ["Right"], contexts: ["list"],
    group: "Moving", label: "Open the selected message" },
  { id: "backToList", keys: ["u", "Left"], contexts: ["reader"],
    group: "Moving", label: "Back to the list" },
  { id: "nextMember", keys: ["n"], contexts: ["reader"],
    group: "Moving", label: "Next message in the conversation" },
  { id: "previousMember", keys: ["p"], contexts: ["reader"],
    group: "Moving", label: "Previous message in the conversation" },

  { id: "archive", keys: ["e"], contexts: MAIL,
    group: "Acting", label: "Archive",
    hint: { list: "archive", reader: "archive" } },
  { id: "trash", keys: ["d"], contexts: MAIL,
    group: "Acting", label: "Move to trash",
    hint: { list: "trash", reader: "trash" } },
  { id: "star", keys: ["s"], contexts: MAIL,
    group: "Acting", label: "Star or unstar" },

  { id: "moveToLabel", keys: ["v"], contexts: MAIL,
    group: "Acting", label: "Move to",
    hint: { list: "move to", reader: "move to" },
    hintNeedsSelection: true, hintUnavailableId: "move" },
  { id: "markRead", keys: ["Shift+I"], contexts: MAIL,
    group: "Acting", label: "Mark read" },
  { id: "markUnread", keys: ["Shift+U"], contexts: MAIL,
    group: "Acting", label: "Mark unread" },

  { id: "toggleCheck", keys: ["x", "Space"], contexts: MAIL,
    group: "Acting", label: "Select or deselect the message",
    hintKey: "Space", hint: { list: "select" } },
  { id: "checkAll", keys: ["Ctrl+A"], contexts: ["list"],
    group: "Acting", label: "Select every message loaded, or none" },

  { id: "reply", keys: ["r"], contexts: MAIL,
    group: "Writing", label: "Reply", hint: { reader: "reply" } },
  { id: "replyAll", keys: ["a"], contexts: MAIL,
    group: "Writing", label: "Reply to all" },
  { id: "forward", keys: ["f"], contexts: MAIL,
    group: "Writing", label: "Forward" },
  { id: "compose", keys: ["c"], contexts: MAIL,
    group: "Writing", label: "Compose or edit a draft", hint: { list: "compose" } },
  { id: "send", keys: ["Ctrl+Return", "Ctrl+Enter"], contexts: ["compose"],
    group: "Writing", label: "Send", hint: { compose: "send" } },
  { id: "undoSend", keys: ["Alt+Z"], contexts: ANY,
    survivesOverlay: true,
    group: "Writing", label: "Undo send" },

  // Invariant: bare search shortcuts must not intercept typing in text fields.
  { id: "search", keys: ["/"], contexts: MAIL,
    group: "Finding", label: "Search" },

  { id: "goMailbox",
    keys: ["Ctrl+1", "Ctrl+2", "Ctrl+3", "Ctrl+4", "Ctrl+5",
      "Ctrl+6", "Ctrl+7", "Ctrl+8", "Ctrl+9"],
    contexts: MAIL, group: "Going", label: "Go to that mailbox",
    display: "Ctrl+1…9" },

  // Invariant: mailbox switching remains available across mailbox contexts.
  { id: "goAccount",
    keys: ["Alt+1", "Alt+2", "Alt+3", "Alt+4", "Alt+5",
      "Alt+6", "Alt+7", "Alt+8", "Alt+9", "Alt+0"],
    contexts: ["list", "reader"], group: "Going",
    label: "Go to that email account", display: "Alt+1…0" },

  // Invariant: modified mailbox switching keys preserve bare keys for message actions.
  { id: "switchAccount", keys: ["Alt+A"], contexts: MAIL,
    group: "Going", label: "Switch account" },

  { id: "askAgent", keys: ["Alt+G"], contexts: ["list", "reader", "compose"],
    group: "Acting", label: "Ask AI about the message or draft" },
  { id: "searchSuggestionNext", keys: ["Down"], contexts: ["searchSuggestions"], group: "Search", label: "Next search suggestion" },
  { id: "searchSuggestionPrevious", keys: ["Up"], contexts: ["searchSuggestions"], group: "Search", label: "Previous search suggestion" },
  { id: "searchSuggestionComplete", keys: ["Tab"], contexts: ["searchSuggestions"], group: "Search", label: "Complete the search suggestion" },
  { id: "searchSuggestionAccept", keys: ["Return", "Enter"], contexts: ["searchSuggestions"], group: "Search", label: "Complete the selected suggestion or search" },

  { id: "assistantSend", keys: ["Return", "Enter", "Ctrl+Return", "Ctrl+Enter"], contexts: ["assistant", "assistantCommands"],
    sequenceContexts: { "Return": ["assistant"], "Enter": ["assistant"] },
    group: "AI", label: "Send the AI message" },
  { id: "assistantCommandNext", keys: ["Down"], contexts: ["assistantCommands"], group: "AI", label: "Next command" },
  { id: "assistantCommandPrevious", keys: ["Up"], contexts: ["assistantCommands"], group: "AI", label: "Previous command" },
  { id: "assistantChooseCommand", keys: ["Return", "Enter"], contexts: ["assistantCommands"],
    group: "AI", label: "Complete or run the selected AI command" },

  { id: "calendar", keys: ["Alt+C"], contexts: ["list", "reader"],
    group: "Going", label: "Open Skylark..." },
  { id: "mailView", keys: ["Ctrl+Shift+M"], contexts: ["list", "reader"],
    group: "Going", label: "Go to mail" },
  { id: "calendarView", keys: ["Ctrl+Shift+C"], contexts: ["list", "reader"],
    group: "Going", label: "Open Skylark..." },
  { id: "toggleSidebar", keys: ["["], contexts: ["list", "reader"],
    group: "Going", label: "Show or hide the sidebar" },

  // Invariant: text sizing applies only where a message body exists.
  { id: "zoomIn", keys: ["Ctrl++", "Ctrl+="], contexts: ["reader"],
    group: "Reading", label: "Zoom the message body in" },
  { id: "zoomOut", keys: ["Ctrl+-"], contexts: ["reader"],
    group: "Reading", label: "Zoom the message body out" },
  { id: "zoomReset", keys: ["Ctrl+0"], contexts: ["reader"],
    group: "Reading", label: "Reset the zoom" },

  { id: "refresh", keys: ["F5", "Ctrl+R"], contexts: ANY,
    group: "Mailbox", label: "Check for mail" },
  { id: "settings", keys: ["Ctrl+,"], contexts: ANY,
    group: "Mailbox", label: "Open settings" },
  // Invariant: the help shortcut belongs to the mailbox context, not active text input.
  { id: "help", keys: ["?"], contexts: MAIL,
    survivesOverlay: true,
    group: "Mailbox", label: "Toggle all keybindings" },
  { id: "back", keys: ["Escape"], contexts: ANY,
    survivesOverlay: true,
    group: "Mailbox", label: "Back, or close the window",
    hint: { reader: "back", page: "back", compose: "close", search: "leave" } }
]

// Invariant: undo-send remains available across navigation while a send is pending.
function contextFor(state) {
  var value = state || ({})
  if (value.assistantEditing) return value.assistantCommands ? "assistantCommands" : "assistant"
  if (value.showPage) return "page"
  if (value.composing) return "compose"
  if (value.searchFocused) return value.searchSuggestions ? "searchSuggestions" : "search"
  if (value.currentView === "reader") return "reader"
  return "list"
}

function byId(id) {
  for (var bindingIndex = 0; bindingIndex < BINDINGS.length; bindingIndex++) {
    if (BINDINGS[bindingIndex].id === id) return BINDINGS[bindingIndex]
  }
  return null
}

function slotFor(id, sequence) {
  var row = byId(id)
  var keys = row ? row.keys || [] : []
  return keys.indexOf(String(sequence || ""))
}

function matchesContext(binding, context) {
  if (!binding) return false
  var contexts = binding.contexts || []
  for (var contextIndex = 0; contextIndex < contexts.length; contextIndex++) {
    if (contexts[contextIndex] === "*" || contexts[contextIndex] === context) return true
  }
  return false
}

function matchesSequenceContext(binding, sequence, context) {
  if (!binding) return false
  var overrides = binding.sequenceContexts || ({})
  var contexts = overrides[String(sequence || "")] || binding.contexts || []
  for (var contextIndex = 0; contextIndex < contexts.length; contextIndex++) {
    if (contexts[contextIndex] === "*" || contexts[contextIndex] === context) return true
  }
  return false
}

// Invariant: binding eligibility comes from active context, never hidden focus state.
function isEnabled(binding, context, overlay) {
  if (!matchesContext(binding, context)) return false
  if (overlay && !binding.survivesOverlay) return false
  return true
}

function isSequenceEnabled(binding, sequence, context, overlay) {
  if (!matchesSequenceContext(binding, sequence, context)) return false
  if (overlay && !binding.survivesOverlay) return false
  return true
}

function bindingsFor(context) {
  var output = []
  for (var bindingIndex = 0; bindingIndex < BINDINGS.length; bindingIndex++) {
    if (matchesContext(BINDINGS[bindingIndex], context)) output.push(BINDINGS[bindingIndex])
  }
  return output
}

function sequencesFor(context) {
  var output = []
  var rows = BINDINGS
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    var keys = rows[rowIndex].keys || []
    for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) {
      if (matchesSequenceContext(rows[rowIndex], keys[keyIndex], context))
        output.push(({ id: rows[rowIndex].id, sequence: keys[keyIndex], binding: rows[rowIndex] }))
    }
  }
  return output
}

function readableSequence(sequence) {
  var text = String(sequence || "")
  if (text.charAt(text.length - 1) === ",") return text
  if (text.indexOf(",") > 0) return text.split(",").join(" then ")
  text = text.replace("Return", "Enter")
  if (text === "Escape") return "Esc"
  return text
}

function displayFor(binding) {
  if (!binding) return ""

  if (binding.display) return binding.display
  var keys = binding.keys || []
  var output = []
  // Invariant: Return and Enter share one displayed keycap name.
  for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) {
    var readable = readableSequence(keys[keyIndex])
    if (output.indexOf(readable) < 0) output.push(readable)
  }
  return output.join(", ")
}

function hintKeyFor(binding) {
  if (!binding) return ""
  if (binding.hintKey) return binding.hintKey
  return displayFor(binding)
}

// Invariant: keycap presentation must preserve Qt's case-sensitive sequence identifiers.
function keycapLabel(text) {
  return String(text || "").toLowerCase()
}

function hintTextFor(binding, context) {
  var hint = binding ? binding.hint : null
  if (!hint) return ""
  if (typeof hint === "string") return hint
  return hint[context] || ""
}

// Invariant: help-group order follows first appearance in the binding table.
function helpGroups(hidden) {
  var groups = []
  var byName = ({})
  var omitted = Array.isArray(hidden) ? hidden : []
  for (var bindingIndex = 0; bindingIndex < BINDINGS.length; bindingIndex++) {
    var binding = BINDINGS[bindingIndex]
    if (omitted.indexOf(binding.id) >= 0) continue
    if (!byName[binding.group]) {
      byName[binding.group] = ({ name: binding.group, rows: [] })
      groups.push(byName[binding.group])
    }
    byName[binding.group].rows.push(({
      keys: displayFor(binding),
      action: binding.label
    }))
  }
  return groups
}

function hintsFor(context, unavailable, hasSelection) {
  var output = []
  var rows = bindingsFor(context)
  var missing = Array.isArray(unavailable) ? unavailable : []
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    if (rows[rowIndex].hintNeedsSelection && hasSelection !== true) continue
    var unavailableId = rows[rowIndex].hintUnavailableId || rows[rowIndex].id
    if (missing.indexOf(unavailableId) >= 0) continue
    var text = hintTextFor(rows[rowIndex], context)
    if (text !== "") output.push(({ key: hintKeyFor(rows[rowIndex]), label: text }))
  }
  return output
}

function helpWeight(group) {
  return (group && Array.isArray(group.rows) ? group.rows.length : 0) + 1
}

// Algorithm: contiguous group partitioning balances help columns while retaining reading order.
function helpColumns(count, hidden) {
  var groups = helpGroups(hidden)
  var columns = Math.max(1, Math.min(groups.length, Math.floor(Number(count)) || 1))
  var output = []
  for (var columnIndex = 0; columnIndex < columns; columnIndex++) output.push([])
  if (columns === 1) {
    output[0] = groups
    return output
  }

  var total = 0
  for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) total += helpWeight(groups[groupIndex])
  var at = 0
  var used = 0
  var placed = 0
  for (var nextGroupIndex = 0; nextGroupIndex < groups.length; nextGroupIndex++) {

    var left = groups.length - nextGroupIndex
    var free = columns - at
    var target = (total - placed) / free
    var nextWeight = helpWeight(groups[nextGroupIndex])

    if (at < columns - 1 && output[at].length > 0
        && (left <= free - 1
          || Math.abs(used - target) <= Math.abs(used + nextWeight - target))) {
      placed += used
      at++
      used = 0
    }
    output[at].push(groups[nextGroupIndex])
    used += helpWeight(groups[nextGroupIndex])
  }
  return output
}

function conflicts() {
  var found = []
  for (var contextIndex = 0; contextIndex < CONTEXTS.length; contextIndex++) {
    var seen = ({})
    var rows = sequencesFor(CONTEXTS[contextIndex])
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      if (seen[rows[rowIndex].sequence]) {
          found.push(({ context: CONTEXTS[contextIndex], keys: rows[rowIndex].sequence,
            ids: [seen[rows[rowIndex].sequence], rows[rowIndex].id] }))
        } else {
          seen[rows[rowIndex].sequence] = rows[rowIndex].id
        }
    }
  }
  return found
}

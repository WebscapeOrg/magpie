.pragma library

function suggestsClear(text) {
  var value = String(text || "")
  return !/[\r\n]/.test(value) && /^\s*\/[a-z]*$/.test(value)
    && "/clear".indexOf(value.trim()) === 0
}

// Invariant: detach only the app-owned quote suffix; quoted-looking user text must survive.
function replyOnly(body, quote) {
  body = String(body || "")
  quote = String(quote || "")
  if (quote === "") return body
  if (body === quote) return ""
  var suffix = "\n\n" + quote
  return body.slice(-suffix.length) === suffix ? body.slice(0, -suffix.length) : body
}

function proposalEnvelope(envelope) {
  var result = JSON.parse(JSON.stringify(envelope))
  var quote = String(result.replyQuote || "")
  if (quote !== "") result.body = replyOnly(result.body, quote) + "\n\n" + quote
  return result
}

// Invariant: each proposed draft owns its attachments, including while another draft is open.
function proposalDraft(envelope, parentId, draftKey) {
  var attachments = JSON.parse(JSON.stringify(envelope.attachments || []))
  for (var attachmentIndex = 0; attachmentIndex < attachments.length; attachmentIndex++) {
    attachments[attachmentIndex].owned = false
    if (attachments[attachmentIndex].data) attachments[attachmentIndex].path = ""
  }
  return {draftKey: draftKey, agentParentJobId: String(parentId || ""),
    replyMessageId: String(envelope.replyMessageId || ""),
    accountId: String(envelope.accountId), fromEmail: String(envelope.from || ""),
    fromWasChosen: true, to: String(envelope.to || ""), cc: String(envelope.cc || ""),
    bcc: String(envelope.bcc || ""), replyTo: String(envelope.replyTo || ""),
    ccVisible: !!envelope.cc, bccVisible: !!envelope.bcc, replyToVisible: !!envelope.replyTo,
    subject: String(envelope.subject || ""), body: String(envelope.body || ""),
    bodyQuote: typeof envelope.replyQuote === "string" ? envelope.replyQuote : "",
    bodyWasEdited: true, userModified: true, placedBody: "",
    mode: envelope.replyMessageId ? "reply" : "new",
    sourceDraftId: String(envelope.draftId || ""), threadId: String(envelope.threadId || ""),
    inReplyTo: String(envelope.inReplyTo || ""), draftAttachments: attachments,
    originalAttachments: [], forwardedAttachments: [], replyRecipients: []}
}

// Invariant: Rust owns execution and durable jobs; these helpers own editable presentation state.

var ACTIVE = ["queued", "running"]

function canUseDraftChat(job, fields) {
  return !!job && String(job.accountId || "") === String(fields.accountId || "")
    && (String(job.draftKey || "") === String(fields.draftKey || "")
      || (String(job.draftKey || "") === "" && !!fields.replyMessageId
        && String(job.messageId || "") === String(fields.replyMessageId)))
}

function conversationWithProposals(conversation, proposals) {
  var rows = []
  for (var conversationIndex = 0; conversationIndex <= conversation.length; conversationIndex++) {
    for (var proposalIndex = 0; proposalIndex < proposals.length; proposalIndex++) {
      var at = typeof proposals[proposalIndex].afterTurn === "number" ? proposals[proposalIndex].afterTurn : conversation.length
      at = Math.max(0, Math.min(conversation.length, at))
      // Invariant: tool proposals may arrive before the closing answer; preserve their conversation order.
      while (at < conversation.length && conversation[at].role !== "user") at++
      if (at === conversationIndex)
        rows.push({role: "proposal", text: String(proposals[proposalIndex].id)})
    }
    if (conversationIndex < conversation.length) rows.push(conversation[conversationIndex])
  }
  return rows
}

function attachmentLabels(attachments) {
  var labels = []
  for (var attachmentIndex = 0; attachmentIndex < attachments.length; attachmentIndex++) {
    var item = attachments[attachmentIndex]
    var details = []
    if (item.mimeType) details.push(String(item.mimeType))
    if (typeof item.size === "number") details.push(item.size + " bytes")
    labels.push(String(item.filename || item.name || "Attachment") + (details.length ? " (" + details.join(", ") + ")" : ""))
  }
  return labels.join("\n")
}

// Invariant: historical command answers retain their body-only insertion rule.
var MAIL_TRANSFORM_FORMAT = "Use exactly this reply layout: Title: <mail title>, then a blank line, then Body: on its own line followed by the mail body. Do not include any other headers or commentary."

function isActive(job) {
  return !!job && ACTIVE.indexOf(String(job.state || "")) >= 0
}

function glyphState(job) {
  if (!job) return ""
  var state = String(job.state || "")
  if (state === "queued" || state === "running") return "running"
  if (state === "done") return String(job.question || "") !== "" ? "question" : "done"
  if (state === "failed") return "failed"
  if (state === "cancelled") return "cancelled"
  return ""
}

function workingText(job, now, preparationStarted) {
  var active = isActive(job)
  var start = active && Number(job.created) > 0 ? Number(job.created) * 1000 : preparationStarted
  var seconds = Math.max(0, Math.floor((now - start) / 1000))
  var duration = Math.floor(seconds / 60) + "m " + (seconds % 60) + "s"
  return "• " + (active ? "Working" : "Preparing") + " (" + duration
    + (active ? " • Esc to interrupt" : "") + ")"
}

function progressText(job) {
  if (!job || !isActive(job)) return ""
  return String(job.progress || "").trim()
}

function stateLabel(job) {
  var glyph = glyphState(job)
  if (job && job.resultReady) return "Ready"
  if (glyph === "running") return String(job.stall || "") === "permission" ? "Stopped to ask" : "Working"
  if (glyph === "question") return "Has a question"
  if (glyph === "done") return "Done"
  if (glyph === "failed") return "Failed"
  if (glyph === "cancelled") return "Cancelled"
  return ""
}

function detailText(job) {
  if (!job) return ""
  if (String(job.question || "") !== "") return String(job.question)
  if (String(job.error || "") !== "") return String(job.error)
  return String(job.summary || "")
}

function finishedNote(job) {
  var glyph = glyphState(job)
  var subject = String(job && job.subject ? job.subject : "").trim()
  var about = subject === "" ? "the message" : "“" + subject + "”"
  // Invariant: background event checks notify only when they found a suggestion.
  if (isEventsJob(job)) {
    var found = glyph === "done" && Array.isArray(job.events) ? job.events.length : 0
    return found > 0 ? "The agent found " + (found === 1 ? "an event" : found + " events") + " in " + about : ""
  }
  if (glyph === "question") return "The agent has a question about " + about
  if (glyph === "done") return "The agent finished with " + about
  if (glyph === "failed") return "The agent failed on " + about
  if (glyph === "cancelled") return "The AI session for " + about + " was closed"
  return ""
}

function pluralizeMessages(count) {
  var messageCount = Math.max(0, Math.floor(Number(count) || 0))
  return messageCount === 1 ? "1 message" : messageCount + " messages"
}

function draftAnswer(job, output, transcript) {
  if (!job || (isActive(job) && !job.resultReady) || glyphState(job) === "failed" || job.question) return ""
  var text = String(output || "")
  var rows = Array.isArray(transcript) ? transcript : []
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    if (rows[rowIndex].role === "user" && rows[rowIndex].text.indexOf(MAIL_TRANSFORM_FORMAT) >= 0) {
      var body = /^Title: [^\r\n]*\r?\n\r?\nBody:\r?\n([\s\S]*)$/.exec(text)
      return body ? body[1] : ""
    }
  }
  return text
}

// Invariant: this fingerprint detects edits; accountId and draftKey still own the draft.
function draftFingerprint(fields) {
  var draft = fields || {}
  var text = JSON.stringify([draft.from || "", draft.to || "", draft.subject || "", draft.body || ""])
  var hash = 2166136261
  for (var characterIndex = 0; characterIndex < text.length; characterIndex++) { hash ^= text.charCodeAt(characterIndex); hash = (hash * 16777619) >>> 0 }
  return String(hash)
}

function chatEntries(value) {
  var rows = Array.isArray(value) ? value : []
  var out = []
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    var entry = rows[rowIndex]
    if (!entry || ["user", "assistant", "status"].indexOf(entry.role) < 0 || typeof entry.text !== "string") continue
    out.push({role: entry.role, text: entry.text})
  }
  return out
}

function createdOrder(job) {
  return Number(job && job.createdOrder || Number(job && job.created || 0) * 1000000000)
}

function historyLabel(job) {
  return new Date(Number(job.created || 0) * 1000).toLocaleString() + " · " + String(job.requestPreview || job.subject || "Conversation")
}

function pendingJob(jobs, currentJob, scopeMatches, conversationId, previousId) {
  var rows = Array.isArray(jobs) ? jobs : []
  if (!rows.length && scopeMatches && currentJob) rows = [currentJob]
  var result = null
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    var job = rows[rowIndex]
    if (conversationId === "") {
      if (!scopeMatches || !currentJob || job.id !== currentJob.id || String(job.id) === previousId) continue
    } else if (String(job.conversationId || job.id) !== conversationId) continue
    if (!result || createdOrder(job) > createdOrder(result)) result = job
  }
  return result
}

function pendingLimit(messages, text) {
  if (messages.length >= 20) return "The queue is full. Wait for a reply or remove a pending message."
  var size = text.length
  for (var messageIndex = 0; messageIndex < messages.length; messageIndex++) size += messages[messageIndex].length
  if (text.length > 65536 || size > 262144) return "This pending message is too long. Shorten it before sending."
  return ""
}

function isEventsJob(job) {
  return !!job && String(job.kind || "") === "events"
}

// Invariant: a month name alone (especially "May") is not evidence of a date.
var MONTH_ANY = "january|february|march|april|may|june|july|august|september|october|november|december"
  + "|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec"
var DAY_ANY = "monday|tuesday|wednesday|thursday|friday|saturday|sunday"
  + "|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun"
var DATE_HINTS = [
  new RegExp("\\b(" + MONTH_ANY + ")\\.?\\s+\\d{1,2}\\b", "i"),
  new RegExp("\\b\\d{1,2}(st|nd|rd|th)?\\s+(" + MONTH_ANY + ")\\b", "i"),
  new RegExp("\\b(on|next|this|every|by|until|till|before)\\s+(" + DAY_ANY + ")\\b", "i"),
  new RegExp("\\b(" + DAY_ANY + ")\\.?,?\\s+(\\d{1,2}\\b|at\\b|morning|afternoon|evening|night)", "i"),
  /\b\d{1,2}[\/.-]\d{1,2}[\/.-]\d{2,4}\b/,
  /\b\d{4}-\d{2}-\d{2}\b/,
  /\b\d{1,2}:\d{2}\b/,
  /\b\d{1,2}\s?(am|pm)\b/i,
  /\b(tomorrow|tonight|next (week|month)|this (week|weekend|evening|afternoon|morning))\b/i
]
function mentionsDate(text) {
  var value = String(text || "")
  if (value === "") return false
  for (var dateHintIndex = 0; dateHintIndex < DATE_HINTS.length; dateHintIndex++) if (DATE_HINTS[dateHintIndex].test(value)) return true
  return false
}

var AUTOMATED_LOCAL = /^(no-?reply|noreply|do-?not-?reply|donotreply|mailer-daemon|postmaster|bounces?|notifications?|alerts?|newsletters?|digests?|updates?|news|info|marketing|support|billing|receipts?|orders?)([@.+_-]|$)/i
var AUTOMATED_WITHIN = /(no-?reply|donotreply|do-not-reply|notifications?@|mailer-daemon|bounce)/i
var CATEGORY_LABELS = ["CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS", "CATEGORY_SOCIAL"]
function automatedMail(summary) {
  var row = summary || {}
  var email = String(row.from && row.from.email ? row.from.email : "").trim().toLowerCase()
  if (AUTOMATED_LOCAL.test(email) || AUTOMATED_WITHIN.test(email)) return true
  var labels = Array.isArray(row.labelIds) ? row.labelIds : []
  for (var labelIndex = 0; labelIndex < labels.length; labelIndex++) if (CATEGORY_LABELS.indexOf(String(labels[labelIndex])) >= 0) return true
  return false
}

function worthALook(summary, text, listMail) {
  if (listMail === true || automatedMail(summary)) return false
  return mentionsDate(text)
}

var EVENTS_MAX_AGE_MS = 60 * 24 * 3600 * 1000
function tooOldForEvents(messageMs, nowMs) {
  var when = Number(messageMs) || 0
  if (when <= 0) return true
  return Number(nowMs) - when > EVENTS_MAX_AGE_MS
}

var EVENTS_IN_FLIGHT = 2

var EVENTS_PROMPT = "Find the calendar events in this message."

function lookFor(looks, accountId, messageId) {
  var account = String(accountId || "")
  var id = String(messageId || "")
  if (account === "" || id === "" || !looks) return null
  var own = looks[account]
  return own && own[id] ? own[id] : null
}

function suggestionKey(jobId, index) {
  return String(jobId || "") + ":" + Math.max(0, Math.floor(Number(index) || 0))
}

function eventSuggestions(look, dismissed) {
  var job = look || null
  var gone = Array.isArray(dismissed) ? dismissed : []
  if (!isEventsJob(job) || String(job.state || "") !== "done") return []
  var events = Array.isArray(job.events) ? job.events : []
  var out = []
  for (var eventIndex = 0; eventIndex < events.length; eventIndex++) {
    var event = events[eventIndex] || {}
    var key = suggestionKey(job.id, eventIndex)
    if (gone.indexOf(key) >= 0) continue
    var startMs = Number(event.startMs) || 0
    if (String(event.title || "").trim() === "" || startMs <= 0) continue
    var endMs = Number(event.endMs) || 0
    out.push({
      key: key, jobId: String(job.id), index: eventIndex,
      title: String(event.title).trim(),
      startMs: startMs,
      endMs: endMs > startMs ? endMs : startMs + 3600000,
      allDay: event.allDay === true,
      location: String(event.location || "").trim(),
      notes: String(event.notes || "").trim()
    })
  }
  return out
}

var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
function suggestionWhen(suggestion, nowMs) {
  var event = suggestion || {}
  var start = new Date(Number(event.startMs) || 0)
  if (!isFinite(start.getTime()) || start.getTime() <= 0) return ""
  var now = new Date(Number(nowMs) || Date.now())
  function two(number) { return number < 10 ? "0" + number : String(number) }
  function day(date) {
    var text = DAY_NAMES[date.getDay()] + " " + date.getDate() + " " + MONTH_NAMES[date.getMonth()]
    return date.getFullYear() !== now.getFullYear() ? text + " " + date.getFullYear() : text
  }
  function clock(date) { return two(date.getHours()) + ":" + two(date.getMinutes()) }
  var end = new Date(Number(event.endMs) || 0)
  if (event.allDay === true) {
    var lastDay = isFinite(end.getTime()) && end.getTime() > start.getTime() ? new Date(end.getTime() - 1) : start
    return day(start) + (day(lastDay) !== day(start) ? " – " + day(lastDay) : "") + " (all day)"
  }
  if (!isFinite(end.getTime()) || end.getTime() <= start.getTime()) return day(start) + ", " + clock(start)
  var sameDay = end.getFullYear() === start.getFullYear() && end.getMonth() === start.getMonth() && end.getDate() === start.getDate()
  if (sameDay) return day(start) + ", " + clock(start) + "–" + clock(end)
  return day(start) + ", " + clock(start) + " – " + day(end) + ", " + clock(end)
}

function eventPrefill(suggestion, accountId) {
  var event = suggestion || {}
  var start = Number(event.startMs) || 0
  var end = Number(event.endMs) || 0
  return { title: String(event.title || ""), startMs: start, endMs: end > start ? end : start + 3600000,
    allDay: event.allDay === true, location: String(event.location || ""),
    description: String(event.notes || ""), accountId: String(accountId || "") }
}

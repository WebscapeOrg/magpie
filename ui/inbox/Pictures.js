.pragma library

// Presentation rules for Settings → Sender pictures. The status comes from inbox.pictureStatus.

function money(cents) {
  var value = Number(cents)
  if (!isFinite(value) || value < 0) value = 0
  return "$" + (value / 100).toFixed(2)
}

function problem(code) {
  switch (String(code || "")) {
  case "pictures_key_format": return "That is not an OpenAI API key. OpenAI keys start with sk-."
  case "pictures_key_invalid": return "OpenAI did not accept this key. Paste a current key."
  case "pictures_key_refused": return "OpenAI does not let this key make images. Check the key's project and permissions."
  case "pictures_billing": return "OpenAI reports no credit on this key's account. Painting starts again within an hour of adding credit."
  case "pictures_rate_limited": return "OpenAI asked Magpie Mail to slow down. Painting starts again in a minute or two."
  case "pictures_model_unavailable": return "OpenAI does not offer gpt-image-2.5 Sunburst to this key. Magpie Mail tries again tomorrow."
  case "pictures_unreachable": return "OpenAI could not be reached. Magpie Mail tries again in a few minutes."
  case "pictures_request_rejected": return "OpenAI rejected Magpie Mail's picture requests several times in a row, so painting has stopped. Magpie Mail tries again tomorrow."
  case "pictures_key_storage": return "The keyring could not be used. Unlock it, then try again."
  case "pictures_storage_full": return "Magpie Mail's record of sender pictures is nearly full, so new pictures may stop. Older senders are forgotten after 90 days."
  case "pictures_storage_unavailable": return "Magpie Mail could not read its record of sender pictures. Senders keep their usual pictures."
  case "": return ""
  default: return "Sender pictures are not available right now."
  }
}

function summary(status) {
  if (!status || typeof status !== "object") return ""
  // present is null when the keyring could not be read, so whether a key is saved is unknown.
  // Settings reads it again when it is next opened.
  if (status.present === null && status.problem === "pictures_key_storage")
    return "The keyring could not be used. Unlock it, then open Settings again."
  if (status.present === null && status.problem) return problem(status.problem)
  if (status.present !== true)
    return "Add an OpenAI API key to paint each Inbox sender's picture in Marmalade's style. "
      + "Contact photos, company logos and company domains are sent to OpenAI; names, email addresses and mail are not."
  if (status.problem) return problem(status.problem)
  var painted = Math.max(0, Number(status.painted) || 0)
  var waiting = Math.max(0, Number(status.waiting) || 0)
  var failed = Math.max(0, Number(status.failed) || 0)
  var spent = Number(status.spentTodayCents) || 0
  var limit = Number(status.dailyLimitCents) || 0
  var text = painted + (painted === 1 ? " sender picture" : " sender pictures") + " painted"
  if (waiting > 0) text += ", " + waiting + " waiting"
  if (failed > 0) text += ", " + failed + " could not be painted"
  text += ". About " + money(spent) + " of the " + money(limit) + " daily limit used today."
  if (waiting > 0 && limit > 0 && spent >= limit - 7) text += " The rest are painted tomorrow."
  return text
}

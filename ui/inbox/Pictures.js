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
  case "pictures_rate_limited": return "OpenAI asked Magpie to slow down. Painting starts again in a minute or two."
  case "pictures_model_unavailable": return "OpenAI does not offer gpt-image-2 to this key. Magpie tries again tomorrow."
  case "pictures_unreachable": return "OpenAI could not be reached. Magpie tries again in a few minutes."
  case "pictures_key_storage": return "The keyring could not be used. Unlock it, then try again."
  case "": return ""
  default: return "Sender pictures are not available right now."
  }
}

function summary(status) {
  if (!status || typeof status !== "object") return ""
  if (status.present !== true)
    return "Add an OpenAI API key to paint each Inbox sender's picture in Marmalade's style. "
      + "Contact photos, company logos and company domains are sent to OpenAI; names, email addresses and mail are not."
  if (status.problem) return problem(status.problem)
  var painted = Math.max(0, Number(status.painted) || 0)
  var waiting = Math.max(0, Number(status.waiting) || 0)
  var spent = Number(status.spentTodayCents) || 0
  var limit = Number(status.dailyLimitCents) || 0
  var text = painted + (painted === 1 ? " sender picture" : " sender pictures") + " painted"
  if (waiting > 0) text += ", " + waiting + " waiting"
  text += ". " + money(spent) + " spent today of the " + money(limit) + " daily limit."
  if (waiting > 0 && limit > 0 && spent >= limit - 7) text += " The rest are painted tomorrow."
  return text
}

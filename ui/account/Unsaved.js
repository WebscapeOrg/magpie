.pragma library

// Presentation rules for mail that can never be saved in full. The counts come from local.status.

var LARGE = ["local_content_too_large", "gmail_response_too_large"]

function whole(value) {
  var number = Math.floor(Number(value))
  return isFinite(number) && number > 0 ? number : 0
}

function messages(count) {
  return count + (count === 1 ? " message" : " messages")
}

function summary(status) {
  if (!status || typeof status !== "object") return ""
  var total = whole(status.unsaved)
  if (total === 0) return ""
  var reasons = status.unsavedReasons && typeof status.unsavedReasons === "object" ? status.unsavedReasons : {}
  var damaged = 0
  var large = 0
  var known = true
  for (var reason in reasons) {
    if (reason === "local_text_unreadable") damaged += whole(reasons[reason])
    else if (LARGE.indexOf(reason) >= 0) large += whole(reasons[reason])
    else known = false
  }
  if (!known || damaged + large !== total) return messages(total) + " could not be saved in full."
  if (large === 0)
    return messages(total) + " could not be saved in full because Gmail's copy of "
      + (total === 1 ? "its" : "their") + " text is damaged."
  if (damaged === 0)
    return messages(total) + " could not be saved in full because " + (total === 1 ? "it is" : "they are")
      + " too large to download."
  return messages(total) + " could not be saved in full: " + damaged + " with damaged text in Gmail and "
    + large + " too large to download."
}

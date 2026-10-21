.pragma library

.import "../message/Html.js" as Html
function icon(label) {
  var name = String(label || "").toLowerCase()
  if (name === "personal") return "home"
  if (name === "webscape") return "tree"
  return "mail"
}

function initial(sender) {
  var value = String(sender && (sender.display || sender.name || sender.email) || "?").trim()
  return (Array.from(value)[0] || "?").toUpperCase()
}
function image(value) {
  var text = String(value || "")
  return Html.isRasterDataImage(text) ? text : ""
}

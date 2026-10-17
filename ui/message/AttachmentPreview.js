.pragma library
.import "Html.js" as Html

function supported(attachment) {
  var file = attachment || ({})
  var mime = String(file.mimeType || "").toLowerCase()
  return String(file.attachmentId || "") !== ""
    && Number(file.size || 0) <= 8 * 1024 * 1024
    && ["application/pdf", "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp"].indexOf(mime) >= 0
}

function fileLabel(attachment) {
  var file = attachment || ({})
  var mime = String(file.mimeType || "").toLowerCase()
  if (mime === "application/pdf") return "PDF"
  if (mime.indexOf("image/") === 0) return "Image"
  if (mime.indexOf("audio/") === 0) return "Audio"
  if (mime.indexOf("video/") === 0) return "Video"
  var suffix = String(file.filename || "").split(".").pop()
  return /^[a-z0-9]{1,8}$/i.test(suffix) ? suffix.toUpperCase() : "File"
}

function rasterSource(value) {
  var data = String(value || "")
  return data.length <= 700000 && data.indexOf("data:image/png;base64,") === 0
    && Html.isRasterDataImage(data) ? data : ""
}

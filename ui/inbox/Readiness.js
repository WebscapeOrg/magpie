.pragma library
function ready(value, at) {
  if (!value || value.version !== 2 || value.state !== "ready" || typeof value.text !== "string") return false
  if (value.text.trim() === "" || Array.from(value.text).length > 140 || /[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff<>]/.test(value.text)) return false
  return typeof value.expiresAt === "number" && isFinite(value.expiresAt) && Math.floor(value.expiresAt) === value.expiresAt && value.expiresAt <= 9007199254740991 && (value.expiresAt === 0 || value.expiresAt > at)
}

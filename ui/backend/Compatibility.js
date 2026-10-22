.pragma library

// Invariant: The exact binary pin may speak the released API or its single declared development step, never an arbitrary later API.
function accepts(info, expectedVersion, expectedApiVersion, latestApiVersion) {
  var step = typeof latestApiVersion === "number" && latestApiVersion === expectedApiVersion + 1
    ? latestApiVersion : expectedApiVersion
  return !!info && info.protocol === 1
    && typeof expectedVersion === "string" && expectedVersion.length > 0
    && typeof info.version === "string" && info.version === expectedVersion
    && typeof expectedApiVersion === "number" && expectedApiVersion > 0
    && expectedApiVersion <= 2147483647
    && Math.floor(expectedApiVersion) === expectedApiVersion
    && (info.apiVersion === expectedApiVersion || info.apiVersion === step
      || (info.apiVersion === undefined && info.version === "0.9.0" && expectedApiVersion === 1))
}

// Invariant: Historical 0.9.0 omitted apiVersion and is the sole implicit API1 compatibility case.
function connectedApiVersion(info) {
  if (!info) return 0
  if (info.apiVersion === undefined) return info.version === "0.9.0" ? 1 : 0
  return typeof info.apiVersion === "number" ? info.apiVersion : 0
}

function usableApiVersion(info, released, latest, contractHash) {
  var connected = connectedApiVersion(info)
  if (connected <= released) return connected
  if (connected !== latest || latest !== released + 1) return 0
  if (typeof contractHash !== "string" || !/^[a-f0-9]{64}$/.test(contractHash)
      || info.contractHash !== contractHash) return released
  return connected
}

function methodRefusal(info, method) {
  if (!info || !Array.isArray(info.methods)) return null
  if (info.methods.indexOf(String(method || "")) >= 0) return null
  return { code: -32012, message: NEEDS_UPDATE }
}

function needsUpdate(info, latestApiVersion) {
  var connected = connectedApiVersion(info)
  return connected > 0 && typeof latestApiVersion === "number" && latestApiVersion > connected
}

// Invariant: Local feature refusals use the backend error shape without sending unsupported requests.
var NEEDS_UPDATE = "backend_needs_update"
function unreleasedRefusal(method, unreleasedMethods, needsUpdate) {
  if (!needsUpdate) return null
  var list = Array.isArray(unreleasedMethods) ? unreleasedMethods : []
  if (list.indexOf(String(method || "")) < 0) return null
  return { code: -32012, message: NEEDS_UPDATE }
}

function dispatchError(connected, ready, stopping, method, internal) {
  if (!connected) return "Backend unavailable"
  if (stopping && internal === true && method === "system.quit") return null
  if (stopping)
    return "Backend is shutting down"
  if (ready || (internal === true && method === "system.info")) return null
  return "Backend is not ready"
}

function shouldRequestQuit(stopping, pendingCount, quitRequested) {
  return stopping && pendingCount === 0 && !quitRequested
}

function isCleanShutdown(stopping, quitRequested, pendingCount, failed, exitCode) {
  return stopping && quitRequested && pendingCount === 0 && !failed && exitCode === 0
}

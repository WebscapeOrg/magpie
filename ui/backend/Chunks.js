.pragma library

// Invariant: UTF-8 scalar boundaries can make a valid 64 MiB response require 1025 chunks; bound retention before appending.
function accept(state, line) {
  function invalid() { return { error: true, state: null, line: null } }
  if (typeof line !== "string" || line.length >= 1048576) return invalid()
  var value
  try { value = JSON.parse(line) } catch (error) { return invalid() }
  if (!value || value.method !== "transport.chunk")
    return state ? invalid() : { state: null, line: line, value: value }
  var parameters = value.params
  if (value.jsonrpc !== "2.0" || Object.prototype.hasOwnProperty.call(value, "id")
      || !parameters || typeof parameters.transfer !== "string" || !/^[0-9]{1,20}$/.test(parameters.transfer)
      || !Number.isInteger(parameters.index) || !Number.isInteger(parameters.total)
      || parameters.total < 2 || parameters.total > 1025 || parameters.index < 0 || parameters.index >= parameters.total
      || !Number.isInteger(parameters.size) || parameters.size < 1 || parameters.size > 67108864
      || typeof parameters.data !== "string" || parameters.data.length < 1 || parameters.data.length > 65536)
    return invalid()
  if (!state) {
    if (parameters.index !== 0) return invalid()
    state = { transfer: parameters.transfer, total: parameters.total, size: parameters.size,
              next: 0, length: 0, parts: [], started: Date.now() }
  }
  if (state.transfer !== parameters.transfer || state.total !== parameters.total || state.size !== parameters.size
      || state.next !== parameters.index || state.length + parameters.data.length > state.size)
    return invalid()
  state.parts.push(parameters.data)
  state.length += parameters.data.length
  state.next++
  if (state.next < state.total) return { state: state, line: null }
  if (state.length !== state.size) return invalid()
  return { state: null, line: state.parts.join("") }
}

// Performance: Keep the decoded ordinary frame; decode again only after a complete chunked document is assembled.
function decode(state, line) {
  var accepted = accept(state, line)
  if (accepted.error || accepted.line === null) return accepted
  if (!Object.prototype.hasOwnProperty.call(accepted, "value")) {
    try { accepted.value = JSON.parse(accepted.line) }
    catch (error) { return { error: true, state: null, line: null } }
  }
  return accepted
}

.pragma library

// Invariant: Rust validates and persists recovery records; QML owns only their presentation state.
function empty() {
  return { active: false, returnView: "", draft: null, parked: [] }
}

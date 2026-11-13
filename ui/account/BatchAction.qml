import QtQuick

// Invariant: Rust expands and rolls back the entire account selection as one transaction.
QtObject {
  required property var account
  required property var intents

  // A completion normally means one mail per id with no note. options.wholeConversations keeps what
  // the same action does on one row, and options.silent drops the note where a toast says it instead.
  // options.hideFailure only matters in the unified view, where a failed batch otherwise still notes.
  function run(ids, action, completion, options) {
    var whole = !!options && options.wholeConversations === true
    return account.runNativeAction(Array.isArray(ids) ? ids : [], action,
      typeof completion === "function" && !whole, false, false, completion, !!options && options.silent === true)
  }
}

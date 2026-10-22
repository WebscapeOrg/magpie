import QtQuick

// Invariant: Rust expands and rolls back the entire account selection as one transaction.
QtObject {
  required property var account
  required property var intents

  function run(ids, action, completion) {
    return account.runNativeAction(Array.isArray(ids) ? ids : [], action,
      typeof completion === "function", false, false, completion)
  }
}

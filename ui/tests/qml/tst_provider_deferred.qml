import QtQuick
import QtTest
import "../../providers" as Providers

Item {
  id: root
  Component { id: factory; Providers.Deferred {} }
  Loader { id: owner; active: false; sourceComponent: factory }
  TestCase {
    name: "ProviderDeferred"
    function cleanup() { owner.active = false }
    function test_callbacks_are_async_and_coalesced_by_identity() {
      var queue = createTemporaryObject(factory, root)
      var calls = []
      function first() { calls.push("first") }
      queue.call(first)
      queue.call(first)
      queue.call(function() { calls.push("second") })
      compare(calls.length, 0)
      tryVerify(function() { return calls.length === 2 })
      compare(calls.join(","), "first,second")
    }
    function test_owner_removal_cancels_callbacks() {
      failOnWarning(/.?/)
      owner.active = true
      var calls = 0
      owner.item.call(function() { calls++ })
      owner.active = false
      wait(10)
      compare(calls, 0)
    }
    function test_reentrant_callbacks_run_in_the_next_batch() {
      var queue = createTemporaryObject(factory, root)
      var calls = []
      queue.call(function() {
        calls.push("first")
        queue.call(function() { calls.push("reentrant") })
        compare(calls.join(","), "first")
      })
      queue.call(function() { calls.push("second") })
      tryVerify(function() { return calls.length === 3 })
      compare(calls.join(","), "first,second,reentrant")
    }
    function test_callback_failure_does_not_strand_the_batch() {
      var queue = createTemporaryObject(factory, root)
      var calls = 0
      ignoreWarning("Deferred provider callback failed")
      queue.call(function() { throw new Error("synthetic private detail") })
      queue.call(function() { calls++ })
      tryCompare(queue, "callbacks", [])
      tryVerify(function() { return calls === 1 })
    }
  }
}

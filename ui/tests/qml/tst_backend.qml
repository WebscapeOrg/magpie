import QtQuick
import QtTest
import "../../backend" as BackendModule

Item {
  Component {
    id: backendFactory
    BackendModule.Backend {
      executable: "/tmp/omamail-synthetic-backend"
      expectedVersion: "0.8.2"
      expectedApiVersion: 1
    }
  }

  TestCase {
    name: "BackendLifecycle"
    SignalSpy { id: errors; signalName: "requestFailed" }

    function test_failed_request_reports_operation_without_payload() {
      var backend = makeBackend()
      var process = makeReady(backend)
      errors.target = backend
      errors.clear()
      var received = null
      backend.call("agent.jobStart", {payload: "SECRET-MAIL"}, function(result, error) { received = error })
      var all = requests(process)
      var request = all[all.length - 1]
      backend.receive(JSON.stringify({jsonrpc:"2.0",id:request.id,error:{code:-32000,message:"agent_invalid_state"}}))
      compare(received.message, "agent_invalid_state")
      compare(errors.count, 1)
      compare(errors.signalArguments[0][0], "agent.jobStart")
      compare(errors.signalArguments[0].length, 2)
      verify(JSON.stringify(errors.signalArguments).indexOf("SECRET-MAIL") < 0)
      errors.target = null
    }

    function test_agent_context_deadline_includes_uploaded_operation() {
      var backend = makeBackend()
      makeReady(backend)
      var before = Date.now()
      backend.call("agent.context", {}, function() {})
      backend.call("request.upload", {method:"agent.context",upload:"synthetic"}, function() {})
      backend.call("message.prepare", {}, function() {})
      var pending = Object.keys(backend.pending).map(function(id) { return backend.pending[id] })
      compare(pending.length, 3)
      verify(pending[0].deadline >= before + 65000)
      verify(pending[1].deadline >= before + 65000)
      verify(pending[2].deadline >= before + 30000 && pending[2].deadline < before + 31000)
    }

    function test_cancelled_upload_discards_staged_data_without_domain_dispatch() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var callbacks = 0
      var handle = backend.call("agent.context", {prompt:"x".repeat(210000)}, function() { callbacks++ })
      var all = requests(process)
      compare(all[all.length - 1].method, "upload.begin")
      reply(process, all[all.length - 1], {upload:"synthetic",chunkSize:65536})
      all = requests(process)
      var append = all[all.length - 1]
      compare(append.method,"upload.append")
      handle.cancel()
      reply(process,append,{offset:65536})
      all=requests(process)
      compare(all[all.length - 1].method,"upload.discard")
      for (var requestIndex=0;requestIndex<all.length;requestIndex++) verify(all[requestIndex].method!=="request.upload")
      compare(callbacks,0)
    }

    function test_refresh_burst_waits_for_free_rpc_slots() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var completed = 0
      var failed = 0
      for (var requestIndex = 0; requestIndex < 225; requestIndex++) {
        backend.call("gmail.read", { accountId: "account-" + Math.floor(requestIndex / 25), id: requestIndex }, function(result, error) {
          if (error) failed++
          else completed++
        })
      }
      compare(failed, 0)
      compare(requests(process).length, 65, "64 physical requests after the handshake")
      for (var replyIndex = 0; replyIndex < 225; replyIndex++) {
        verify(Object.keys(backend.pending).length <= 64)
        var request = requests(process)[replyIndex + 1]
        compare(request.params.id, replyIndex, "queued reads remain FIFO")
        reply(process, request, { ok: true })
      }
      compare(completed, 225)
      compare(Object.keys(backend.pending).length, 0)
    }

    function test_shutdown_drains_accepted_queue_before_quit() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var completed = 0
      for (var requestIndex = 0; requestIndex < 80; requestIndex++)
        backend.call("gmail.read", { id: requestIndex }, function(result, error) { if (!error) completed++ })
      backend.shutdown(function() {})
      for (var replyIndex = 0; replyIndex < 80; replyIndex++) {
        var request = requests(process)[replyIndex + 1]
        compare(request.method, "gmail.read")
        reply(process, request, { ok: true })
      }
      compare(completed, 80)
      compare(requests(process)[81].method, "system.quit")
      reply(process, requests(process)[81], { quitReady: true })
      process.exited(0)
      compare(backend.shutdownError, null)
    }

    function completeRestartShutdown(backend, process) {
      var quit = requests(process).slice(-1)[0]
      compare(quit.method, "system.quit")
      reply(process, quit, { quitReady: true })
      verify(backend.restarting)
      verify(!backend.ready)
      process.exited(0)
      wait(0)
      verify(process.running)
      verify(backend.restarting)
      verify(!backend.ready)
      process.started()
      var handshake = requests(process).slice(-1)[0]
      compare(handshake.method, "system.info")
      return handshake
    }

    function restartedInfo() {
      return { name: "omamail", apiVersion: 1, protocol: 1, version: "0.8.2",
        methods: ["system.info", "system.quit", "gmail.read", "upload.begin"] }
    }

    function test_restart_drains_queue_and_waits_for_handshake_each_time() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var completed = 0
      for (var requestIndex = 0; requestIndex < 80; requestIndex++)
        backend.call("gmail.read", { id: requestIndex }, function(result, error) { if (!error) completed++ })
      var restarts = 0
      backend.restart(function(error) { compare(error, null); restarts++ })
      verify(backend.restarting)
      for (var replyIndex = 0; replyIndex < 80; replyIndex++) {
        var request = requests(process)[replyIndex + 1]
        compare(request.method, "gmail.read")
        reply(process, request, { ok: true })
      }
      compare(completed, 80)
      compare(restarts, 0)
      var handshake = completeRestartShutdown(backend, process)
      compare(restarts, 0, "a launched process is not ready until its handshake succeeds")
      var before = process.written
      var refused = null
      backend.call("gmail.read", {}, function(result, error) { refused = error })
      verify(refused !== null)
      compare(process.written, before)
      reply(process, handshake, restartedInfo())
      compare(restarts, 1)
      verify(backend.ready)
      verify(!backend.restarting)
      verify(!backend.stopping)
      backend.restart(function(error) { compare(error, null); restarts++ })
      handshake = completeRestartShutdown(backend, process)
      reply(process, handshake, restartedInfo())
      compare(restarts, 2)
      verify(backend.ready)
      compare(process.command[0], backend.executable)
    }

    function test_restart_duplicate_is_refused_without_extra_quit() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var completed = 0
      backend.restart(function(error) { compare(error, null); completed++ })
      var before = process.written
      var refused = null
      backend.restart(function(error) { refused = error })
      compare(refused.message, "Backend restart is already in progress")
      compare(process.written, before)
      var handshake = completeRestartShutdown(backend, process)
      reply(process, handshake, restartedInfo())
      compare(completed, 1)
    }

    function test_restart_after_separate_shutdown_and_runtime_validation() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var stopped = false
      backend.shutdown(function(error) { compare(error, null); stopped = true })
      reply(process, requests(process).slice(-1)[0], { quitReady: true })
      process.exited(0)
      verify(stopped)
      backend.launchEnabled = false
      wait(0)
      backend.launchEnabled = true
      wait(0)
      verify(!process.running, "runtime validation alone must not restart a shut-down backend")
      var before = requests(process).length
      var completed = false
      backend.restart(function(error) { compare(error, null); completed = true })
      verify(process.running)
      process.started()
      compare(requests(process).length, before + 1, "no second quit is sent")
      reply(process, requests(process).slice(-1)[0], restartedInfo())
      verify(completed)
      verify(backend.ready)
    }

    function test_restart_incompatible_handshake_stops_without_dispatch() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var failures = []
      backend.restart(function(error) { failures.push(error) })
      var handshake = completeRestartShutdown(backend, process)
      var info = restartedInfo()
      info.version = "0.8.1"
      reply(process, handshake, info)
      compare(failures.length, 1)
      compare(failures[0].message, "Incompatible backend")
      verify(!backend.ready)
      verify(!process.running)
      var before = process.written
      backend.call("gmail.read", {}, function() {})
      compare(process.written, before)
      process.exited(1)
      compare(failures.length, 1)
    }

    function test_restart_startup_deadline_data() {
      return [{ tag: "no process start", handshake: false }, { tag: "no handshake", handshake: true }]
    }

    function test_restart_startup_deadline(data) {
      var backend = makeBackend()
      var process = makeReady(backend)
      var failures = []
      backend.restart(function(error) { failures.push(error) })
      reply(process, requests(process).slice(-1)[0], { quitReady: true })
      process.exited(0)
      wait(0)
      verify(process.running)
      if (data.handshake) process.started()
      restartDeadlineOf(backend).triggered()
      compare(failures.length, 1)
      compare(failures[0].message, "Backend restart timed out")
      verify(!process.running)
      verify(!backend.ready)
      process.exited(1)
      compare(failures.length, 1)
    }

    function test_restart_never_relaunches_without_confirmed_stop() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var failures = []
      backend.restart(function(error) { failures.push(error) })
      deadlineOf(backend).triggered()
      stopConfirmationOf(backend).triggered()
      compare(failures.length, 1)
      compare(failures[0].message, "Backend stop was not confirmed")
      verify(!process.running)
      var before = process.written
      backend.restart(function(error) { failures.push(error) })
      compare(failures.length, 2)
      compare(failures[1].message, "Backend stop was not confirmed")
      verify(!process.running)
      compare(process.written, before)
      process.exited(1)
      var completed = false
      backend.restart(function(error) { compare(error, null); completed = true })
      verify(process.running)
      process.started()
      reply(process, requests(process).slice(-1)[0], restartedInfo())
      verify(completed)
      verify(backend.ready)
    }

    function test_restart_failed_quit_requires_explicit_retry_after_exit() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var failures = []
      backend.restart(function(error) { failures.push(error) })
      reply(process, requests(process).slice(-1)[0], null, { code: -32000, message: "quit failed" })
      compare(failures.length, 0)
      process.exited(1)
      wait(0)
      compare(failures.length, 1)
      compare(failures[0].message, "Backend shutdown failed")
      verify(!process.running)
      backend.restart(function(error) { compare(error, null) })
      verify(process.running)
      process.started()
      reply(process, requests(process).slice(-1)[0], restartedInfo())
      verify(backend.ready)
    }

    function test_shutdown_cancels_pending_restart_without_relaunch() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var restartError = null
      backend.restart(function(error) { restartError = error })
      var stopped = false
      backend.shutdown(function(error) { compare(error, null); stopped = true })
      compare(restartError.message, "Backend restart was cancelled")
      reply(process, requests(process).slice(-1)[0], { quitReady: true })
      process.exited(0)
      wait(0)
      verify(stopped)
      verify(!process.running)
      verify(!backend.restarting)
    }

    function test_restart_refuses_changed_executable_after_shutdown() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var failure = null
      backend.restart(function(error) { failure = error })
      backend.executable = "/tmp/changed-synthetic-backend"
      reply(process, requests(process).slice(-1)[0], { quitReady: true })
      process.exited(0)
      wait(0)
      compare(failure.message, "Backend changed during restart")
      verify(!process.running)
    }

    function test_internal_upload_burst_shares_one_reservation_queue() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var completed = 0
      var failed = 0
      var uploads = ({})
      var nextUpload = 0
      for (var uploadIndex = 0; uploadIndex < 24; uploadIndex++) {
        var callback = function(result, error) { if (error) failed++; else completed++ }
        if (uploadIndex % 3 === 0) backend.parseMessage("Subject: Test\r\n\r\nbody", callback)
        else if (uploadIndex % 3 === 1) backend.putBodyCache("test@example.org", "id-" + uploadIndex, { text: "body" }, callback)
        else backend.call("message.prepare", {text: "x".repeat(210000)}, callback)
      }
      compare(requests(process).length, 9, "only eight upload reservations may start")
      var cursor = 1
      while (cursor < requests(process).length) {
        var request = requests(process)[cursor++]
        var parameters = request.params
        if (request.method === "upload.begin") {
          verify(Object.keys(uploads).length < 8)
          var id = "upload-" + (++nextUpload)
          uploads[id] = true
          reply(process, request, { upload: id, chunkSize: 65536 })
        } else if (request.method === "upload.append") {
          verify(uploads[parameters.upload])
          reply(process, request, { offset: parameters.offset + Math.floor(parameters.data.length * 3 / 4) })
        } else {
          verify(uploads[parameters.upload])
          delete uploads[parameters.upload]
          reply(process, request, { ok: true })
        }
      }
      compare(completed, 24)
      compare(failed, 0)
      compare(Object.keys(uploads).length, 0)
    }

    function test_cancel_withdraws_an_uploaded_operation_waiting_for_rpc_capacity() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var callbacks = 0
      var handle = backend.call("cache.resourcePut", {text:"x".repeat(210000)}, function() { callbacks++ })
      reply(process, requests(process)[1], {upload:"cancel-commit",chunkSize:65536})
      for (var chunkIndex = 1; chunkIndex <= 3; chunkIndex++)
        reply(process, requests(process)[chunkIndex + 1], {offset:chunkIndex * 65536})
      var lastAppend = requests(process)[5]
      compare(lastAppend.method, "upload.append")
      for (var requestIndex = 0; requestIndex < 80; requestIndex++) backend.call("gmail.read", {id:requestIndex}, function() {})
      reply(process, lastAppend, {offset:210011})
      handle.cancel()
      var discarded = false
      for (var cursor = 6; cursor < requests(process).length; cursor++) {
        var request = requests(process)[cursor]
        verify(request.method !== "request.upload", "cancelled queued write must never execute")
        if (request.method === "upload.discard") discarded = true
        reply(process, request, {ok:true})
      }
      verify(discarded)
      compare(callbacks, 0)
      compare(backend.uploadQueue.bytes, 0)
    }

    function test_disconnect_fails_both_queues_once_and_ignores_late_upload_ids() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var callbacks = 0
      function done(result, error) { verify(error !== null); callbacks++ }
      for (var requestIndex = 0; requestIndex < 80; requestIndex++) backend.call("gmail.read", {id:requestIndex}, done)
      for (var uploadIndex = 0; uploadIndex < 12; uploadIndex++) backend.parseMessage("body", done)
      var before = requests(process)
      backend.stopForFailure("Backend stopped")
      compare(callbacks, 92)
      compare(backend.queued.length, 0)
      compare(backend.uploadQueue.bytes, 0)
      compare(backend.uploadQueue.waiting.length + backend.uploadQueue.active.length, 0)
      for (var cursor = 1; cursor < before.length; cursor++)
        reply(process, before[cursor], {upload:"stale",chunkSize:65536})
      compare(callbacks, 92)
      compare(requests(process).length, before.length)
    }

    function test_queued_request_keeps_its_original_payload() {
      var backend = makeBackend()
      var process = makeReady(backend)
      for (var requestIndex = 0; requestIndex < 64; requestIndex++) backend.call("providers.list", {}, function() {})
      var parameters = {accountId:"first@example.org", resource:{subject:"original"}}
      backend.call("cache.resourcePut", parameters, function() {})
      parameters.accountId = "second@example.org"
      parameters.resource.subject = "changed"
      reply(process, requests(process)[1], {})
      var written = requests(process)[65].params
      compare(written.accountId, "first@example.org")
      compare(written.resource.subject, "original")
    }

    function test_shutdown_finishes_fanout_when_an_upload_receiver_throws() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var callbacks = 0
      function done() { callbacks++ }
      for (var uploadIndex = 0; uploadIndex < 8; uploadIndex++) backend.parseMessage("body", done)
      backend.parseMessage("body", function() { callbacks++; throw new Error("receiver gone") })
      backend.parseMessage("body", done)
      ignoreWarning("Backend upload callback failed")
      backend.shutdown(function() {})
      compare(callbacks, 10)
      verify(deadlineOf(backend).running)
      for (var cursor = 1; cursor <= 8; cursor++)
        reply(process, requests(process)[cursor], {upload:"late",chunkSize:65536})
      compare(requests(process)[9].method, "system.quit")
    }

    function makeBackend() {
      var backend = createTemporaryObject(backendFactory, parent)
      verify(backend !== null)
      return backend
    }

    function processOf(backend) {
      for (var childIndex = 0; childIndex < backend.children.length; childIndex++) {
        var child = backend.children[childIndex]
        if (child.command && child.command.length === 2
            && child.command[1] === "serve") return child
      }
      fail("No backend process")
      return null
    }

    function deadlineOf(backend) {
      for (var childIndex = 0; childIndex < backend.data.length; childIndex++) {
        var child = backend.data[childIndex]
        if (child.interval === 5000 && child.repeat === false) return child
      }
      fail("No backend shutdown deadline")
      return null
    }

    function stopConfirmationOf(backend) {
      for (var childIndex = 0; childIndex < backend.data.length; childIndex++) {
        var child = backend.data[childIndex]
        if (child.interval === 1000 && child.repeat === false) return child
      }
      fail("No backend stop confirmation deadline")
      return null
    }

    function restartDeadlineOf(backend) {
      for (var childIndex = 0; childIndex < backend.data.length; childIndex++) {
        var child = backend.data[childIndex]
        if (child.interval === 10000 && child.repeat === false) return child
      }
      fail("No backend restart deadline")
      return null
    }

    function requests(process) {
      var lines = process.written.split("\n")
      var result = []
      for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
        if (lines[lineIndex] !== "") result.push(JSON.parse(lines[lineIndex]))
      }
      return result
    }

    function start(backend) {
      var process = processOf(backend)
      process.started()
      compare(requests(process).length, 1)
      compare(requests(process)[0].method, "system.info")
      return process
    }

    function reply(process, request, result, error) {
      var value = { jsonrpc: "2.0", id: request.id }
      if (error) value.error = error
      else value.result = result
      process.stdout.read(JSON.stringify(value))
    }

    function makeReady(backend) {
      var process = start(backend)
      reply(process, requests(process)[0], {
        name: "omamail",
        apiVersion: 1, protocol: 1,
        version: "0.8.2",
        methods: ["system.info", "system.quit", "agent.context", "agent.jobStart", "cache.resourcePut",
          "gmail.read", "gmail.sendAs", "message.prepare", "providers.list", "request.upload",
          "upload.begin", "upload.append", "upload.discard", "message.parseUpload", "cache.bodyPutUpload"]
      }, null)
      compare(backend.ready, true)
      return process
    }

    function test_partial_unreleased_backend_refuses_local_mutation_before_dispatch() {
      var hash = "a".repeat(64)
      var backend = createTemporaryObject(backendFactory, parent, {
        expectedApiVersion: 7, latestApiVersion: 8, expectedContractHash: hash,
        unreleasedMethods: ["local.edit"] })
      var process = start(backend)
      reply(process, requests(process)[0], {
        protocol:1, version:"0.8.2", apiVersion:8,
        methods:["system.info", "system.quit", "gmail.trash"] }, null)
      verify(backend.ready)
      compare(backend.apiVersion, 7)
      verify(backend.needsUpdate)
      var failure
      backend.call("local.edit", {accountId:"synthetic@example.test", ids:["message"]},
        function(result,error) {failure=error})
      compare(failure.message,"backend_needs_update")
      compare(requests(process).length,1,"the unsupported mutation must not be written")
      backend.call("gmail.trash", {accountId:"synthetic@example.test", id:"message"}, function(){})
      compare(requests(process).length,2)
      compare(requests(process)[1].method,"gmail.trash")
    }

    function test_business_call_is_not_written_before_handshake() {
      var backend = makeBackend()
      var process = processOf(backend)
      var error = null
      backend.call("gmail.sendAs", {}, function(_result, failure) { error = failure })
      verify(error !== null)
      compare(error.message, "Backend unavailable")
      compare(process.written, "")

      process.started()
      var before = process.written
      error = null
      backend.call("gmail.sendAs", {}, function(_result, failure) { error = failure })
      verify(error !== null)
      compare(error.message, "Backend is not ready")
      compare(process.written, before)
      compare(requests(process).length, 1, "only the private system.info request was written")
    }

    function test_recheck_restarts_after_a_failed_handshake() {
      var backend = makeBackend()
      var process = start(backend)
      reply(process, requests(process)[0], { apiVersion: 1, protocol: 1, version: "0.8.1" }, null)
      process.exited(1)
      backend.executable = ""
      wait(0)
      backend.executable = "/tmp/omamail-synthetic-backend"
      wait(0)
      compare(process.running, true)
      compare(backend.ready, false)
    }

    function test_api_mismatch_stops_without_business_dispatch_data() {
      return [{ tag: "missing", info: { protocol: 1, version: "0.8.2" } },
        { tag: "wrong", info: { protocol: 1, version: "0.8.2", apiVersion: 2 } }]
    }
    function test_api_mismatch_stops_without_business_dispatch(data) {
      var backend = makeBackend()
      var process = start(backend)
      reply(process, requests(process)[0], data.info, null)
      compare(backend.ready, false)
      verify(!process.running)
      var before = process.written
      var error = null
      backend.call("gmail.sendAs", {}, function(_result, failure) { error = failure })
      verify(error !== null)
      compare(process.written, before)
    }

    function test_unvalidated_runtime_never_starts_or_dispatches() {
      var backend = createTemporaryObject(backendFactory, parent, { launchEnabled: false })
      var process = processOf(backend)
      wait(0)
      compare(process.running, false)
      verify(backend.executable !== "", "provider migration stays selected")
      var error = null
      backend.call("gmail.sendAs", {}, function(_result, failure) { error = failure })
      verify(error !== null)
      compare(process.written, "")
      backend.launchEnabled = true
      wait(0)
      compare(process.running, true)
      compare(backend.ready, false)
    }

    function test_version_mismatch_stops_without_business_dispatch() {
      var backend = makeBackend()
      var process = start(backend)
      reply(process, requests(process)[0], {
        name: "omamail",
        apiVersion: 1, protocol: 1,
        version: "0.8.1",
        methods: ["system.info", "system.quit", "agent.context", "agent.jobStart", "cache.resourcePut",
          "gmail.read", "gmail.sendAs", "message.prepare", "providers.list", "request.upload",
          "upload.begin", "upload.append", "upload.discard", "message.parseUpload", "cache.bodyPutUpload"]
      }, null)
      compare(backend.ready, false)
      compare(backend.failure, "Incompatible backend")
      compare(process.running, false)
      compare(requests(process).length, 1)
    }

    function test_shutdown_during_mismatched_handshake_keeps_failure_until_exit() {
      var backend = makeBackend()
      var process = start(backend)
      var calls = 0
      var stoppedWith = null
      backend.shutdown(function(error) { calls++; stoppedWith = error })

      reply(process, requests(process)[0], {
        name: "omamail",
        apiVersion: 1, protocol: 1,
        version: "0.8.1",
        methods: ["system.info", "system.quit", "agent.context", "agent.jobStart", "cache.resourcePut",
          "gmail.read", "gmail.sendAs", "message.prepare", "providers.list", "request.upload",
          "upload.begin", "upload.append", "upload.discard", "message.parseUpload", "cache.bodyPutUpload"]
      }, null)
      compare(backend.shutdownFinished, false,
        "a disconnected failure still waits for process exit acknowledgement")
      compare(calls, 0)
      compare(process.running, false)

      process.exited(0)
      compare(calls, 1)
      verify(stoppedWith !== null)
      compare(stoppedWith.message, "Incompatible backend")
    }

    function test_shutdown_drains_then_completes_after_clean_exit() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var businessResult = null
      backend.call("gmail.sendAs", {}, function(result, _error) { businessResult = result })
      compare(requests(process).length, 2)

      var shutdownCalls = 0
      var shutdownError = "not called"
      backend.shutdown(function(error) {
        shutdownCalls++
        shutdownError = error
      })
      compare(backend.ready, false)
      compare(requests(process).length, 2, "quit waits for the accepted business response")

      var refused = null
      backend.call("gmail.sendAs", {}, function(_result, error) { refused = error })
      verify(refused !== null)
      compare(refused.message, "Backend is shutting down")
      compare(requests(process).length, 2)

      reply(process, requests(process)[1], { accepted: true }, null)
      compare(businessResult.accepted, true)
      compare(requests(process).length, 3)
      compare(requests(process)[2].method, "system.quit")
      reply(process, requests(process)[2], { quitReady: true }, null)
      compare(shutdownCalls, 0, "the quit reply alone does not prove the process stopped")
      process.exited(0)
      compare(shutdownCalls, 1)
      compare(shutdownError, null)
    }

    function test_failed_quit_response_cannot_be_reported_clean() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var calls = 0
      var stoppedWith = null
      backend.shutdown(function(error) { calls++; stoppedWith = error })
      compare(requests(process)[1].method, "system.quit")
      reply(process, requests(process)[1], null,
        { code: -32601, message: "Unknown method" })
      compare(calls, 0, "failure still waits for process exit acknowledgement")
      process.exited(0)
      compare(calls, 1)
      verify(stoppedWith !== null)
      compare(stoppedWith.message, "Backend shutdown failed")
    }

    function test_nonzero_exit_after_quit_is_an_error() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var stoppedWith = null
      backend.shutdown(function(error) { stoppedWith = error })
      reply(process, requests(process)[1], { quitReady: true }, null)
      process.exited(1)
      verify(stoppedWith !== null)
      compare(stoppedWith.message, "Backend stopped")
    }

    function test_shutdown_timeout_forces_stop_but_waits_for_exit_signal() {
      var backend = makeBackend()
      var process = makeReady(backend)
      var businessError = null
      backend.call("gmail.sendAs", {}, function(_result, error) { businessError = error })
      var calls = 0
      var stoppedWith = null
      backend.shutdown(function(error) { calls++; stoppedWith = error })

      deadlineOf(backend).triggered()
      verify(businessError !== null)
      compare(businessError.message, "Backend shutdown timed out")
      compare(process.running, false)
      compare(calls, 0)
      process.exited(0)
      compare(calls, 1)
      verify(stoppedWith !== null)
      compare(stoppedWith.message, "Backend shutdown timed out")
    }

    function test_forced_stop_without_exit_signal_is_reported_unconfirmed() {
      var backend = makeBackend()
      var process = makeReady(backend)
      backend.call("gmail.sendAs", {}, function() {})
      var calls = 0
      var stoppedWith = null
      backend.shutdown(function(error) { calls++; stoppedWith = error })

      deadlineOf(backend).triggered()
      compare(process.running, false)
      compare(calls, 0)
      stopConfirmationOf(backend).triggered()
      compare(calls, 1)
      verify(stoppedWith !== null)
      compare(stoppedWith.message, "Backend stop was not confirmed")
    }
  }
}

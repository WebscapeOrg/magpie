import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail
import "../../account/Unified.js" as Unified
import "BackendFixture.js" as BackendFixture

Item {
  id: root
  width: 400
  height: 300

  QtObject {
    id: shellStore

    property string updatedId: ""
    property var updatedEntry: null
    property bool rejectUpdates: false

    function updateEntryInline(id, entry) {
      updatedId = String(id)
      updatedEntry = entry
      return !rejectUpdates
    }
  }

  Omamail.Service {
    id: mailService
    shell: shellStore
    manifest: ({ id: "omamail", __sourceDir: "/tmp/omamail-test" })
  }

  Omamail.Service {
    id: scopedMailService
    shell: shellStore
    manifest: ({ id: "omamail" })
  }

  QtObject {
    id: inactiveAgentHost
    property var capabilities: ({agent:false,tray:false,mailto:false,notifications:false})
  }

  Component {
    id: inactiveServiceFactory
    Omamail.Service {
      manifest: ({id:"omamail"})
      platform: inactiveAgentHost
    }
  }

  Component {
    id: configWriterFactory
    QtObject {
      property var capabilities: ({agent:false,tray:false,mailto:false,notifications:false})
      property var callbacks: []
      property bool accepts: true
      function writeConfig(name, text, callback) {
        callbacks = callbacks.concat([callback])
        return accepts
      }
    }
  }

  TestCase {
    name: "ServiceSettings"

    function init() {
      shellStore.rejectUpdates = false
    }

    function test_restart_waits_for_all_config_writes_and_observes_failure() {
      var service = inactiveService()
      var writer = createTemporaryObject(configWriterFactory, root)
      service.platform = writer
      service.writeConfig("window.json", "{}", function() {})
      service.writeConfig("calendars.json", "{}", function() {})
      compare(service.configWrites, 2)
      verify(service.persistencePending)
      writer.callbacks[0](true, "")
      compare(service.configWrites, 1)
      verify(service.persistencePending)
      var revision = service.persistenceFailureRevision
      writer.callbacks[1](false, "Synthetic refused write")
      compare(service.configWrites, 0)
      compare(service.persistenceFailureRevision, revision + 1)
      writer.callbacks[1](false, "Repeated completion")
      compare(service.configWrites, 0)
      compare(service.persistenceFailureRevision, revision + 1)
    }

    function test_refused_config_write_finishes_once_without_stranding_restart() {
      var service = inactiveService()
      var writer = createTemporaryObject(configWriterFactory, root)
      service.platform = writer
      writer.accepts = false
      var completed = 0
      var revision = service.persistenceFailureRevision
      compare(service.writeConfig("window.json", "{}", function(ok) {
        compare(ok, false)
        completed++
      }), false)
      compare(service.configWrites, 0)
      compare(service.persistenceFailureRevision, revision + 1)
      compare(completed, 1)
      writer.callbacks[0](false, "Delayed failure")
      compare(completed, 1)
    }

    function test_config_helper_start_failure_releases_restart_save_gate() {
      var service = inactiveService()
      var completed = 0
      service.writeConfig("window.json", "{}", function(ok) {
        compare(ok, false)
        completed++
      })
      compare(service.configWrites, 1)
      var writer = findChild(service, "configuration-writer")
      verify(writer)
      var deadline = findChild(writer, "config-write-start-deadline")
      verify(deadline)
      deadline.triggered()
      compare(writer.running, false)
      compare(service.configWrites, 0)
      compare(completed, 1)
      writer.exited(1)
      compare(completed, 1)
    }

    function test_rejected_setting_save_preserves_preferences_and_reports_failure() {
      var service = inactiveService()
      service.shell = shellStore
      service.applyAccounts(JSON.stringify({version: 1, activeId: "one@example.test", accounts: [
        {id: "one@example.test", email: "one@example.test", provider: "gmail", clientId: ""}
      ]}))
      tryVerify(function() { return service.current !== null })
      var original = JSON.stringify(service.settings)
      shellStore.rejectUpdates = true
      service.setNotifyNewMail(false)
      compare(JSON.stringify(service.settings), original)
      verify(service.lastError.indexOf("Could not save settings") >= 0)
      compare(service.notifyNewMail, true)
    }

    function inactiveService() {
      var service = createTemporaryObject(inactiveServiceFactory, root)
      verify(service)
      compare(service.hasAgent, false)
      compare(findChild(service, "agent-runner"), null)
      return service
    }

    function verifyNoAgentRequests(fixture) {
      wait(10)
      compare(fixture.requests.filter(function(request) {
        return request.method.indexOf("agent.") === 0
      }), [], "Disabled agent actions must not dispatch native agent work")
    }

    function test_disabled_agent_has_no_history_or_loading_state() {
      var service = inactiveService()
      compare(service.agentAvailable, false)
      compare(service.agentHasEarlier, false)
      compare(service.agentHasOlderChats, false)
      compare(service.agentHasNewerChats, false)
      compare(service.agentLoadingEarlier, false)
      compare(service.agentSelectionRevision, 0)
      compare(service.agentAllJobs, [])
      compare(service.agentShownTranscript, [])
    }

    function test_curated_inbox_depends_on_platform_capability_not_provider_availability() {
      var service = inactiveService()
      compare(service.mailboxKey, "inbox")
      compare(service.curatedInbox, false)
      compare(mailService.mailboxKey, "inbox")
      compare(mailService.hasAgent, true)
      compare(mailService.agentAvailable, false)
      compare(mailService.curatedInbox, true)
    }

    function test_disabled_agent_has_no_proposals() {
      compare(inactiveService().agentShownProposals, [])
    }

    function test_disabled_agent_refuses_earlier_messages_without_dispatch() {
      var service = inactiveService()
      var fixture = BackendFixture.markReady(service, 7)
      compare(service.loadEarlierAgentMessages(), false)
      verifyNoAgentRequests(fixture)
    }

    function test_disabled_agent_refuses_continuation_without_dispatch() {
      var service = inactiveService()
      var fixture = BackendFixture.markReady(service, 7)
      compare(service.canContinueAgentJob({id:"old-chat",canContinue:true}), false)
      verifyNoAgentRequests(fixture)
    }

    function test_disabled_agent_ignores_paging_without_dispatch() {
      var service = inactiveService()
      var fixture = BackendFixture.markReady(service, 7)
      service.pageAgentChats(true)
      service.pageAgentChats(false)
      verifyNoAgentRequests(fixture)
      compare(service.agentHasOlderChats, false)
      compare(service.agentHasNewerChats, false)
    }

    function test_scoped_manifest_resolves_bundled_helpers_without_private_metadata() {
      verify(scopedMailService.pluginDir !== "")
      verify(scopedMailService.pluginDir.indexOf("%") < 0,
        "the filesystem path must be decoded before it is used as a process command")
      var pluginRoot = decodeURIComponent(String(Qt.resolvedUrl("../../.."))
        .replace(/^file:\/\//, "")).replace(/\/$/, "")
      compare(scopedMailService.pluginDir, pluginRoot,
        "the helper directory comes from Service.qml itself")
    }

    function test_the_bar_icon_is_shown_unless_it_was_turned_off() {
      mailService.applySettings({})
      compare(mailService.showBarIcon, true)

      mailService.applySettings({ showBarIcon: false })
      compare(mailService.showBarIcon, false)

      mailService.applySettings({ showBarIcon: true })
      compare(mailService.showBarIcon, true)

      mailService.applySettings({ showBarIcon: "no" })
      compare(mailService.showBarIcon, true,
        "only a stored false hides the icon")
    }

    function test_hiding_the_bar_icon_persists() {
      mailService.applySettings({})
      mailService.setShowBarIcon(false)
      compare(mailService.showBarIcon, false)
      compare(shellStore.updatedId, "omamail")
      verify(shellStore.updatedEntry !== null)
      compare(shellStore.updatedEntry.showBarIcon, false)
    }


    function test_ai_settings_reach_the_native_runner_and_preserve_other_preferences() {
      mailService.applySettings({showBarIcon:false})
      compare(mailService.aiAgent, "System default")
      compare(mailService.aiModel, "")
      mailService.setAiAgent("OpenCode")
      mailService.setAiModel(" fixture/model#variant ")
      compare(shellStore.updatedEntry.aiAgent, "OpenCode")
      compare(shellStore.updatedEntry.aiModel, "fixture/model#variant")
      compare(shellStore.updatedEntry.showBarIcon, false)
      tryCompare(mailService.agentRunner, "selectedAgent", "OpenCode")
      compare(mailService.agentRunner.selectedModel, "fixture/model#variant")
      mailService.applySettings({})
      compare(mailService.agentRunner.selectedAgent, "System default")
      compare(mailService.agentRunner.selectedModel, "")
    }

    function test_unified_mailboxes_setting_defaults_off_and_persists_changes() {
      mailService.applySettings({})
      compare(mailService.unifiedMailboxes, false)

      mailService.setUnifiedMailboxes(true)
      compare(mailService.unifiedMailboxes, true)
      compare(shellStore.updatedId, "omamail")
      verify(shellStore.updatedEntry !== null)
      compare(shellStore.updatedEntry.unifiedMailboxes, true)
    }

    function test_one_mailbox_is_never_combined_whatever_the_setting_says() {
      mailService.applySettings({ unifiedMailboxes: true })
      compare(mailService.unifiedMailboxes, true)
      var previousAccounts = mailService.accountList
      try {
        mailService.accountList = {version: 1, activeId: "one@example.test", accounts: [
          {id: "one@example.test", provider: "gmail", email: "one@example.test", clientId: ""}
        ]}
        compare(mailService.accountCount, 1)
        compare(mailService.unified, false)
      } finally {
        mailService.accountList = previousAccounts
      }
    }

    function test_the_combined_answers_hold_up_with_no_mailboxes() {
      mailService.applySettings({ unifiedMailboxes: true })
      compare(mailService.messages.length, 0)
      compare(mailService.inboxUnread, 0)
      compare(mailService.lastError, "")
      compare(mailService.selectedId, "")
      compare(mailService.mailboxKey, "inbox")
      verify(mailService.mailboxes.length > 0,
        "the rail still has rows to draw before a mailbox is added")
    }

    // Invariant: This fixture has no real accounts; provider id split correctness is proved separately by test_unified.js.
    function test_an_action_for_a_mailbox_that_is_not_here_reaches_nothing() {
      mailService.applySettings({ unifiedMailboxes: true })
      var absent = Unified.unifiedId("gone@example.org", "42")
      compare(mailService.act(absent, "archive"), false)
      compare(mailService.hostForId(absent), null)
    }

    function test_legacy_preview_preferences_are_tolerated_without_controls() {
      mailService.applySettings({previewOnCursor: true, markReadDelaySec: 30})
      compare(mailService.settings.previewOnCursor, true)
      compare(mailService.settings.markReadDelaySec, 30)
      mailService.setShowBarIcon(false)
      compare(mailService.showBarIcon, false)
      compare(shellStore.updatedEntry.previewOnCursor, true)
      compare(shellStore.updatedEntry.markReadDelaySec, 30)
    }
  }
}

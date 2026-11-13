import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail
import "../../account/Unified.js" as Unified
import "BackendFixture.js" as BackendFixture
import Quickshell.Io

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
    id: serviceForWidget
    property var service: null
    property var shell: QtObject {
      function serviceFor(_id) { return serviceForWidget.service }
      function summon(_id, _payload) {}
    }
    property bool vertical: false
    property color barForeground: Qt.rgba(1, 1, 1, 1)
  }

  Component {
    id: barWidgetFactory
    Omamail.BarWidget {}
  }

  Component {
    id: settingsFileFactory
    Omamail.Service {
      shell: shellStore
      manifest: ({ id: "omamail" })
    }
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

    function readySettingsService() {
      var service = createTemporaryObject(settingsFileFactory, root)
      var own = findChild(service, "settings-file")
      own.contents = "{}"
      own.loaded()
      verify(service.settingsFileReady)
      return service
    }

    function nextWriter(service, previous) {
      tryVerify(function() {
        var writer = findChild(service, "configuration-writer")
        return writer && writer !== previous
      })
      return findChild(service, "configuration-writer")
    }

    function test_saved_settings_come_from_magpies_own_file() {
      var service = createTemporaryObject(settingsFileFactory, root)
      compare(service.settings.notifyNewMail, "On")
      var own = findChild(service, "settings-file")
      compare(own.path, service.configPath("settings.json"))
      own.contents = JSON.stringify({notifyNewMail:"Off",unifiedMailboxes:true,aiAgent:"Claude",aiChatResetAt:1793640598935})
      own.loaded()
      compare(service.settings.notifyNewMail, "Off")
      compare(service.settings.unifiedMailboxes, true)
      compare(service.settings.aiAgent, "Claude")
      compare(service.settings.aiChatResetAt, 1793640598935)
    }

    function test_the_bar_icons_copy_cannot_change_saved_settings() {
      var service = readySettingsService()
      service.applySettings({notifyNewMail:"Off",unifiedMailboxes:true})
      compare(service.settings.notifyNewMail, "On")
      compare(service.settings.unifiedMailboxes, false)
      service.applySettings({notifyNewMail:"Off",unifiedMailboxes:true})
      compare(service.settings.notifyNewMail, "On", "the same stale values handed over again change nothing")
      compare(service.configWrites, 0)
    }

    function test_an_empty_hand_over_is_no_starting_point() {
      var service = readySettingsService()
      service.applySettings({})
      service.applySettings({notifyNewMail:"Off",suggestEvents:true})
      compare(service.settings.notifyNewMail, "On")
      compare(service.settings.suggestEvents, false)
      compare(service.configWrites, 0)
    }

    function test_the_envelope_cannot_restore_older_shell_settings() {
      var service = createTemporaryObject(settingsFileFactory, root)
      var own = findChild(service, "settings-file")
      own.contents = JSON.stringify({undoSendSeconds:30,suggestEvents:false,notifyNewMail:"On"})
      own.loaded()
      serviceForWidget.service = service
      var widget = createTemporaryObject(barWidgetFactory, root)
      verify(widget)
      // The shell's injectProps order: bar first, settings last.
      widget.bar = serviceForWidget
      compare(widget.gmail, undefined)
      widget.settings = ({undoSendSeconds:10,suggestEvents:true,notifyNewMail:"Off"})
      compare(service.settings.undoSendSeconds, 30)
      compare(service.settings.suggestEvents, false)
      compare(service.settings.notifyNewMail, "On")
      compare(service.configWrites, 0)
      serviceForWidget.service = null
    }

    function test_a_change_made_in_the_shell_is_saved() {
      var service = readySettingsService()
      service.applySettings({refreshIntervalSec:120,notifyNewMail:"On"})
      compare(service.configWrites, 0, "the first hand-over is only a starting point")
      service.applySettings({refreshIntervalSec:300,notifyNewMail:"On"})
      compare(service.settings.refreshIntervalSec, 300)
      var writer = nextWriter(service, null)
      compare(writer.command[1], "settings.json")
      writer.started()
      compare(JSON.parse(writer.written).refreshIntervalSec, 300)
      writer.exited(0)
    }

    function test_a_change_in_magpie_survives_the_shells_older_values_returning() {
      var service = readySettingsService()
      service.applySettings({suggestEvents:true,undoSendSeconds:10})
      service.setUndoSendSeconds(30)
      var writer = nextWriter(service, null)
      writer.started()
      writer.exited(0)
      service.applySettings({suggestEvents:true,undoSendSeconds:10})
      compare(service.settings.undoSendSeconds, 30)
      compare(service.settings.suggestEvents, false)
    }

    function test_a_first_run_fills_the_file_from_the_shells_entry() {
      var service = createTemporaryObject(settingsFileFactory, root)
      var shellFile = findChild(service, "shell-settings-file")
      compare(shellFile.path, "", "the shell's file is read only when Magpie has none of its own")
      findChild(service, "settings-file").loadFailed(FileViewError.FileNotFound)
      compare(shellFile.path, service.shellSettingsPath())
      verify(/\/\.config\/omarchy\/shell\.json$/.test(shellFile.path), shellFile.path)
      shellFile.contents = JSON.stringify({bar:{layout:{left:[],center:[],right:[{id:"atlas.arrange"}]}},plugins:[{id:"omamail",
        notifyNewMail:"Off",unifiedMailboxes:true,aiAgent:"Claude",aiChatResetAt:1793640598935}]})
      shellFile.loaded()
      compare(service.settings.notifyNewMail, "Off")
      compare(service.settings.id, undefined)
      var writer = nextWriter(service, null)
      compare(writer.command[1], "settings.json")
      writer.started()
      var saved = JSON.parse(writer.written)
      compare(saved.notifyNewMail, "Off")
      compare(saved.unifiedMailboxes, true)
      compare(saved.aiChatResetAt, 1793640598935)
      compare(saved.id, undefined)
      writer.exited(0)
      compare(service.configWrites, 0)
    }

    function test_a_change_is_saved_to_magpies_file_and_not_to_the_shell() {
      var service = readySettingsService()
      shellStore.updatedEntry = null
      service.setNotifyNewMail(false)
      compare(service.settings.notifyNewMail, "Off")
      compare(shellStore.updatedEntry, null)
      var writer = nextWriter(service, null)
      compare(writer.command[1], "settings.json")
      writer.started()
      compare(JSON.parse(writer.written).notifyNewMail, "Off")
      writer.exited(0)
      compare(service.configWrites, 0)
    }

    function test_quick_changes_are_all_saved() {
      var service = readySettingsService()
      service.setNotifyNewMail(false)
      service.setUndoSendSeconds(30)
      compare(service.configWrites, 1, "saves run one at a time")
      var first = nextWriter(service, null)
      first.started()
      compare(JSON.parse(first.written).undoSendSeconds, 10)
      first.exited(0)
      var second = nextWriter(service, first)
      second.started()
      var saved = JSON.parse(second.written)
      compare(saved.notifyNewMail, "Off")
      compare(saved.undoSendSeconds, 30)
      second.exited(0)
      compare(service.configWrites, 0)
    }

    function test_a_failed_save_restores_the_setting_and_says_so() {
      var service = inactiveService()
      service.applyAccounts(JSON.stringify({version: 1, activeId: "one@example.test", accounts: [
        {id: "one@example.test", email: "one@example.test", provider: "gmail", clientId: ""}
      ]}))
      tryVerify(function() { return service.current !== null })
      service.adoptSettingsFile("{}")
      service.setNotifyNewMail(false)
      compare(service.settings.notifyNewMail, "Off")
      ignoreWarning(new RegExp("settings.json could not be saved"))
      var writer = nextWriter(service, null)
      writer.started()
      writer.exited(1)
      compare(service.settings.notifyNewMail, "On")
      verify(service.lastError.indexOf("Could not save settings") >= 0)
    }

    function test_a_failed_save_goes_back_to_the_last_saved_values() {
      var service = createTemporaryObject(settingsFileFactory, root)
      var own = findChild(service, "settings-file")
      own.contents = JSON.stringify({notifyNewMail:"Off"})
      own.loaded()
      service.setUndoSendSeconds(30)
      var good = nextWriter(service, null)
      good.started()
      good.exited(0)
      service.setUnifiedMailboxes(true)
      var bad = nextWriter(service, good)
      bad.started()
      ignoreWarning(new RegExp("settings.json could not be saved"))
      bad.exited(1)
      compare(service.settings.unifiedMailboxes, false)
      compare(service.settings.undoSendSeconds, 30, "the save that worked stays")
      compare(service.settings.notifyNewMail, "Off", "the file's values stay")
    }

    function test_a_failed_first_change_keeps_the_files_values() {
      var service = createTemporaryObject(settingsFileFactory, root)
      var own = findChild(service, "settings-file")
      own.contents = JSON.stringify({notifyNewMail:"Off"})
      own.loaded()
      service.setUndoSendSeconds(30)
      var writer = nextWriter(service, null)
      writer.started()
      ignoreWarning(new RegExp("settings.json could not be saved"))
      writer.exited(1)
      compare(service.settings.undoSendSeconds, 10)
      compare(service.settings.notifyNewMail, "Off")
    }

    function test_a_failed_first_save_keeps_the_seeded_values() {
      var service = createTemporaryObject(settingsFileFactory, root)
      findChild(service, "settings-file").loadFailed(FileViewError.FileNotFound)
      var shellFile = findChild(service, "shell-settings-file")
      shellFile.contents = JSON.stringify({plugins:[{id:"omamail",notifyNewMail:"Off"}]})
      shellFile.loaded()
      var writer = nextWriter(service, null)
      writer.started()
      ignoreWarning(new RegExp("settings.json could not be saved"))
      writer.exited(1)
      compare(service.settings.notifyNewMail, "Off")
    }

    function test_a_damaged_settings_file_is_left_alone_data() {
      return [{tag:"not json", text:"{not json"},{tag:"a list", text:"[]"},{tag:"a number", text:"7"}]
    }

    function test_a_damaged_settings_file_is_left_alone(data) {
      var service = createTemporaryObject(settingsFileFactory, root)
      var own = findChild(service, "settings-file")
      own.contents = data.text
      ignoreWarning(new RegExp("settings.json could not be read"))
      own.loaded()
      verify(!service.settingsFileReady)
      compare(findChild(service, "shell-settings-file").path, "", "the shell's copy must not replace it")
    }

    function test_only_a_missing_file_counts_as_a_first_run_data() {
      return [{tag:"permission", error:FileViewError.PermissionDenied},{tag:"not a file", error:FileViewError.NotAFile},{tag:"unknown", error:FileViewError.Unknown}]
    }

    function test_only_a_missing_file_counts_as_a_first_run(data) {
      var service = createTemporaryObject(settingsFileFactory, root)
      ignoreWarning(new RegExp("settings.json could not be read, error"))
      findChild(service, "settings-file").loadFailed(data.error)
      verify(!service.settingsFileSeeding)
      verify(!service.settingsFileReady)
      compare(findChild(service, "shell-settings-file").path, "")
    }

    function test_a_shell_file_that_cannot_be_read_still_finishes_the_first_run() {
      var service = createTemporaryObject(settingsFileFactory, root)
      findChild(service, "settings-file").loadFailed(FileViewError.FileNotFound)
      ignoreWarning(new RegExp("the shell's settings could not be read"))
      findChild(service, "shell-settings-file").loadFailed(FileViewError.FileNotFound)
      verify(service.settingsFileReady)
    }

    function test_unreadable_shell_settings_leave_a_trace_and_keep_the_defaults() {
      var service = createTemporaryObject(settingsFileFactory, root)
      ignoreWarning(new RegExp("the shell's settings could not be read"))
      service.seedSettingsFile("{not json")
      verify(service.settingsFileReady)
      compare(service.settings.notifyNewMail, "On")
      compare(findChild(service, "configuration-writer"), null, "nothing is written from nothing")
    }

    function test_the_standalone_app_keeps_its_own_settings_route() {
      var standalone = createTemporaryObject(inactiveServiceFactory, root)
      compare(findChild(standalone, "settings-file").path, "")
      compare(standalone.shellSettingsPath(), "")
      findChild(standalone, "settings-file").loadFailed(FileViewError.FileNotFound)
      verify(!standalone.settingsFileSeeding, "a host's reader can report failure for an empty path")
      verify(!standalone.settingsFileReady)
      var reader = findChild(standalone, "settings-file")
      reader.contents = JSON.stringify({notifyNewMail:"Off"})
      reader.loaded()
      verify(!standalone.settingsFileReady, "nor a load")
    }

    function test_the_shells_file_is_ignored_until_magpies_own_file_is_missing() {
      var service = createTemporaryObject(settingsFileFactory, root)
      var shellFile = findChild(service, "shell-settings-file")
      shellFile.loadFailed(FileViewError.FileNotFound)
      verify(!service.settingsFileReady, "an empty path can report failure before Magpie's file is read")
      shellFile.contents = JSON.stringify({plugins:[{id:"omamail",notifyNewMail:"Off"}]})
      shellFile.loaded()
      verify(!service.settingsFileReady)
      compare(service.settings.notifyNewMail, "On")
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

import QtQuick
import QtTest
import Quickshell
import "../.." as Omamail

Item {
  Component { id: factory; Omamail.Service {} }
  TestCase {
    name: "MessageLinkArguments"
    function init() { Quickshell.detachedCommands = [] }

    function test_a_message_link_goes_to_the_link_window_with_its_mailbox() {
      var service = createTemporaryObject(factory, parent)
      verify(service)
      service.accountList = ({ activeId: "gmail:reader@example.com",
        accounts: [({ id: "gmail:reader@example.com", provider: "gmail", email: "reader@example.com" })] })
      verify(service.openMessageLink("https://example.com/jobs/7?ref=mail", "gmail:reader@example.com"))
      compare(Quickshell.detachedCommands, [["python3", "-I", service.pluginDir + "/scripts/open-link-window.py",
        "https://example.com/jobs/7?ref=mail", "reader@example.com"]])
    }

    function test_an_unknown_mailbox_sends_no_address() {
      var service = createTemporaryObject(factory, parent)
      verify(service)
      verify(service.openMessageLink("https://example.com/", "gmail:someone-else@example.com"))
      compare(Quickshell.detachedCommands[0].slice(3), ["https://example.com/", ""])
    }

    function test_an_empty_link_starts_nothing() {
      var service = createTemporaryObject(factory, parent)
      verify(service)
      verify(!service.openMessageLink("", "gmail:reader@example.com"))
      compare(Quickshell.detachedCommands, [])
    }

    function test_the_standalone_app_keeps_its_own_opener() {
      var service = createTemporaryObject(factory, parent)
      verify(service)
      var opened = []
      service.platform = { openExternal: function(target) { opened.push(target); return true } }
      verify(service.openMessageLink("https://example.com/", "gmail:reader@example.com"))
      compare(opened, ["https://example.com/"])
      compare(Quickshell.detachedCommands, [])
    }

    function test_other_destinations_still_use_the_default_opener() {
      var service = createTemporaryObject(factory, parent)
      verify(service)
      verify(service.openExternal("https://example.com/help"))
      compare(Quickshell.detachedCommands, [["xdg-open", "https://example.com/help"]])
    }
  }
}

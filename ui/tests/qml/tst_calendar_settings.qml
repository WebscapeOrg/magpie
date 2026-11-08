import QtQuick
import QtTest
import "../../components" as Mail

Item {
  width: 640
  height: 640
  Component {
    id: backendFactory
    QtObject {
      property bool ready: true
      property int apiVersion: 8
      property var calls: []
      function call(method, params, done) { calls = calls.concat([{method: method, params: params, done: done}]) }
    }
  }
  Component {
    id: authFactory
    QtObject {
      property bool loginBusy: false
      property bool opens: true
      signal loginSucceeded()
      signal sessionUnavailable(string reason)
      function beginLogin() { if (opens) loginBusy = true }
    }
  }
  Component {
    id: hostFactory
    QtObject {
      property string accountId: ""
      property var auth: null
      property int signIns: 0
      function signIn() { signIns++; if (auth) auth.beginLogin() }
    }
  }
  Component {
    id: serviceFactory
    QtObject {
      property var backend: null
      property var hosts: []
      function findAccount(id) {
        for (var index = 0; index < hosts.length; index++) if (hosts[index].accountId === id) return hosts[index]
        return null
      }
    }
  }
  Component {
    id: panelFactory
    Mail.CalendarSettings {
      width: 480
      textColor: palette.windowText
      dimColor: palette.placeholderText
      accentColor: palette.highlight
      panelFontFamily: "sans-serif"
      SystemPalette { id: palette }
    }
  }
  TestCase {
    name: "CalendarSettings"
    when: windowShown
    property var backend
    property var service
    property var auth
    property var host
    property var panel
    function init() {
      backend = createTemporaryObject(backendFactory, parent)
      auth = createTemporaryObject(authFactory, parent)
      host = createTemporaryObject(hostFactory, parent, {accountId: "sam@example.com", auth: auth})
      service = createTemporaryObject(serviceFactory, parent, {backend: backend, hosts: [host]})
      panel = createTemporaryObject(panelFactory, parent, {service: service})
      verify(panel)
    }
    function last() {
      var rows = backend.calls.filter(function(row) { return row.method === "inbox.calendarAccess" })
      return rows[rows.length - 1]
    }
    function row(account) { return findChild(panel, "settings-calendar-" + account) }
    function statusOf(account) { return findChild(row(account), "settings-calendar-status").text }
    function allowOf(account) { return findChild(row(account), "settings-calendar-allow") }
    function test_an_engine_without_the_calendar_hides_the_section() {
      verify(!panel.visible)
      last().done(null, {code: -32601, message: "method_not_found"})
      verify(!panel.visible)
    }
    function test_each_account_says_in_plain_words_whether_the_calendar_is_read() {
      compare(last().params, {})
      last().done({accounts: {"sam@example.com": "permission_required", "work@example.com": "ready", "old@example.com": "unavailable"}}, null)
      verify(panel.visible)
      compare(statusOf("sam@example.com"), "Not allowed yet.")
      compare(statusOf("work@example.com"), "Read for The Point.")
      compare(statusOf("old@example.com"), "Could not be read just now. Magpie Mail tries again in a few minutes.")
      verify(allowOf("sam@example.com").visible)
      verify(!allowOf("work@example.com").visible, "an allowed calendar offers nothing to do")
      verify(!allowOf("old@example.com").visible)
      verify(findChild(panel, "settings-calendar-caption").text.indexOf("Magpie Mail never changes it") > 0)
    }
    function test_allowing_signs_in_again_and_reads_the_calendar_at_once() {
      last().done({accounts: {"sam@example.com": "permission_required"}}, null)
      allowOf("sam@example.com").clicked()
      compare(host.signIns, 1)
      compare(statusOf("sam@example.com"), "Finish allowing it in your browser.")
      verify(!allowOf("sam@example.com").visible)
      auth.loginBusy = false
      auth.loginSucceeded()
      compare(last().params, {accountId: "sam@example.com"})
      compare(statusOf("sam@example.com"), "Checking")
      last().done({accounts: {"sam@example.com": "ready"}}, null)
      compare(statusOf("sam@example.com"), "Read for The Point.")
      verify(!allowOf("sam@example.com").visible)
      wait(0)
      compare(statusOf("sam@example.com"), "Read for The Point.", "the closed sign-in is not read as a failure")
    }
    function test_a_calendar_left_unticked_asks_again_in_plain_words() {
      last().done({accounts: {"sam@example.com": "permission_required"}}, null)
      allowOf("sam@example.com").clicked()
      auth.loginBusy = false
      auth.loginSucceeded()
      last().done({accounts: {"sam@example.com": "permission_required"}}, null)
      compare(statusOf("sam@example.com"), "Google did not give Magpie Mail the calendar. Allow it again and leave the calendar ticked.")
      verify(allowOf("sam@example.com").visible)
    }
    function test_a_sign_in_that_ends_without_an_answer_can_be_tried_again() {
      last().done({accounts: {"sam@example.com": "permission_required"}}, null)
      allowOf("sam@example.com").clicked()
      auth.loginBusy = false
      wait(0)
      compare(statusOf("sam@example.com"), "Magpie Mail did not get the permission. Try again.")
      verify(allowOf("sam@example.com").visible)
      allowOf("sam@example.com").clicked()
      compare(host.signIns, 2)
      auth.loginBusy = false
      auth.sessionUnavailable("Google sign-in failed. Please try again")
      compare(statusOf("sam@example.com"), "Magpie Mail did not get the permission. Try again.")
      auth.opens = false
      allowOf("sam@example.com").clicked()
      compare(statusOf("sam@example.com"), "Magpie Mail could not open Google sign-in. Try again.")
      var rechecks = backend.calls.filter(function(row) { return row.params.accountId !== undefined })
      compare(rechecks.length, 0, "only a sign-in that succeeded reads the calendar again")
    }
    function test_an_account_with_no_host_is_not_signed_in_from_here() {
      last().done({accounts: {"gone@example.com": "permission_required"}}, null)
      allowOf("gone@example.com").clicked()
      compare(statusOf("gone@example.com"), "Sign in to this account first.")
      compare(host.signIns, 0)
    }
    function test_narrow_rows_keep_clear_space() {
      panel.width = 280
      last().done({accounts: {"a-very-long-address-for-a-narrow-window@example.com": "permission_required", "old@example.com": "unavailable"}}, null)
      var first = row("a-very-long-address-for-a-narrow-window@example.com")
      var second = row("old@example.com")
      var status = findChild(first, "settings-calendar-status")
      var allow = allowOf("a-very-long-address-for-a-narrow-window@example.com")
      waitForItemPolished(first)
      waitForItemPolished(panel)
      verify(allow.y >= status.y + status.height + 2, "the button sits below the status with space between")
      verify(allow.x + allow.width <= first.width)
      verify(second.y >= first.y + first.height + 4, "the rows do not touch")
      var long = findChild(second, "settings-calendar-status")
      verify(long.lineCount > 1 && long.width <= second.width, "a long status wraps inside the row")
    }
  }
}

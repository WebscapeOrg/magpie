import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail
import "BackendFixture.js" as BackendFixture

Item {
  width: 900
  height: 600

  QtObject {
    id: fakeShell
    function hide(_id) {}
  }

  Omamail.Service {
    id: mailService
    shell: fakeShell
    manifest: ({ id: "omamail", __sourceDir: "/tmp/omamail-test" })
  }

  Omamail.App {
    id: app
    service: mailService
    shell: fakeShell
  }

  TestCase {
    name: "AppEditConnect"
    when: windowShown

    readonly property string firstId: "shawn@example.test"
    readonly property string secondId: "admin@example.test"
    property var fixture: null

    function named(item, objectName) {
      if (!item) return null
      if (item.objectName === objectName) return item
      var values = item.children || []
      for (var childIndex = 0; childIndex < values.length; childIndex++) {
        var found = named(values[childIndex], objectName)
        if (found) return found
      }
      return null
    }

    function init() {
      fixture = BackendFixture.markReady(mailService, 7)
      fixture.answers = {
        "credentials.get": {found: false},
        "credentials.put": {stored: true},
        "credentials.delete": {deleted: true}
      }
      app.opened = true
      mailService.accountList = ({version: 1, accounts: [], activeId: ""})
      wait(0)
    }

    function cleanup() {
      mailService.eachHost(function(host) { if (host.auth) host.auth.cancelLogin() })
      mailService.accountList = ({version: 1, accounts: [], activeId: ""})
      wait(0)
    }

    function twoRows() {
      mailService.accountsLoaded = true
      mailService.accountList = ({version: 1, accounts: [
        {id: firstId, email: firstId, provider: "gmail"},
        {id: secondId, email: secondId, provider: "gmail"}
      ], activeId: firstId})
      tryCompare(mailService, "accountCount", 2)
      var first = mailService.findAccount(firstId)
      var second = mailService.findAccount(secondId)
      verify(first && second)
      tryVerify(function() { return first.auth && first.api && second.auth && second.api })
      first.auth.credentials = {clientId: "123-example.apps.googleusercontent.com", clientSecret: "synthetic-first"}
      second.auth.credentials = {clientId: "456-example.apps.googleusercontent.com", clientSecret: "synthetic-second"}
      wait(0)
      first.auth.cancelLogin()
      second.auth.cancelLogin()
      first.profile = {email: firstId}
      second.profile = {email: secondId}
      first.auth.loggedIn = true
      tryCompare(app, "anyReady", true)
      app.resetNavigation()
      waitForRendering(app)
      compare(app.page, "list")
      return {first: first, second: second}
    }

    function test_edit_signs_in_the_selected_gmail_account_only() {
      var hosts = twoRows()
      app.openSettings()
      verify(app.editAccount(1))
      compare(app.page, "setup")
      compare(mailService.current, hosts.second)
      waitForRendering(app)

      var page = named(app, "setup-page").item
      verify(page && typeof page.signInNamed === "function")
      compare(page.auth, hosts.second.auth)
      var before = fixture.requests.length
      page.signInNamed()
      wait(0)
      var logins = fixture.requests.slice(before).filter(function(request) { return request.method === "auth.begin" })
      compare(logins.length, 1)
      compare(logins[0].params.clientId, "456-example.apps.googleusercontent.com")
      compare(logins[0].params.loginHint, secondId)
      compare(hosts.first.auth.loginBusy, false)
      compare(hosts.first.auth.loggedIn, true)
      compare(mailService.current, hosts.second)
      compare(app.page, "setup")
      compare(mailService.accountList.accounts[1].id, secondId)
    }

    function test_selection_change_does_not_redirect_a_started_sign_in() {
      var hosts = twoRows()
      app.openSettings()
      verify(app.editAccount(1))
      waitForRendering(app)
      var before = fixture.requests.length
      named(app, "setup-page").item.signInNamed()
      mailService.switchTo(firstId)
      wait(0)
      var logins = fixture.requests.slice(before).filter(function(request) { return request.method === "auth.begin" })
      compare(logins.length, 1)
      compare(logins[0].params.clientId, "456-example.apps.googleusercontent.com")
      compare(logins[0].params.loginHint, secondId)
      compare(hosts.first.auth.loginBusy, false)
      compare(hosts.first.auth.loggedIn, true)
      compare(hosts.second.auth.loginBusy, true)
    }
  }
}

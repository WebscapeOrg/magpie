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
    name: "AppClientSetupWrongAccount"
    when: windowShown

    function initTestCase() {
      var fixture = BackendFixture.markReady(mailService, 4)
      fixture.answers = {
        "credentials.get": {found:false},
        "credentials.put": {stored:true},
        "credentials.delete": {deleted:true}
      }
    }

    readonly property string firstId: "shawn@example.test"
    readonly property string gmailId: "ada@example.test"

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
      BackendFixture.markReady(mailService, 4)
      app.opened = true
      mailService.accountList = ({ version: 1, accounts: [], activeId: "" })
      wait(0)
    }

    function cleanup() {
      mailService.eachHost(function(host) {
        if (host.auth && typeof host.auth.cancelLogin === "function") host.auth.cancelLogin()
      })
      mailService.accountList = ({ version: 1, accounts: [], activeId: "" })
      wait(0)
    }

    function test_calendar_signin_click_keeps_its_account_when_selection_changes() {
      var fixture = BackendFixture.markReady(mailService, 7)
      mailService.accountsLoaded = true
      mailService.accountList = {version: 1, activeId: gmailId, accounts: [
        {id: gmailId, email: gmailId, provider: "gmail", clientId: ""},
        {id: "other@example.test", email: "other@example.test", provider: "gmail", clientId: ""}
      ]}
      tryCompare(mailService, "accountCount", 2)
      var first = mailService.findAccount(gmailId)
      var second = mailService.findAccount("other@example.test")
      tryVerify(function() { return first.auth && second.auth })
      first.auth.credentials = {clientId: "123-example.apps.googleusercontent.com", clientSecret: "synthetic-secret"}
      second.auth.credentials = {clientId: "456-example.apps.googleusercontent.com", clientSecret: "synthetic-secret"}
      first.auth.cancelLogin()
      second.auth.cancelLogin()
      app.openSettings()
      waitForRendering(app)
      var button = named(app, "calendar-discover-google")
      verify(button)
      compare(button.text, "Sign in...")
      var viewport = button.parent
      while (viewport && viewport.contentY === undefined) viewport = viewport.parent
      verify(viewport)
      viewport.contentY = Math.max(0, button.mapToItem(viewport.contentItem, 0, 0).y - 40)
      waitForRendering(button)
      var switchSelection = function() { mailService.switchTo("other@example.test") }
      button.clicked.connect(switchSelection)
      var before = fixture.requests.length
      mouseClick(button, button.width / 2, button.height / 2)
      button.clicked.disconnect(switchSelection)
      wait(0)
      var logins = fixture.requests.slice(before).filter(function(request) { return request.method === "auth.begin" })
      compare(logins.length, 1)
      compare(logins[0].params.clientId, "123-example.apps.googleusercontent.com")
      compare(second.auth.loginBusy, false)
      first.auth.cancelLogin()
      second.auth.cancelLogin()
    }

    function test_client_setup_reuses_a_saved_gmail_account_from_another_selection() {
      mailService.accountsLoaded = true
      mailService.accountList = ({version: 1, accounts: [
        {id: gmailId, email: gmailId, provider: "gmail"},
        {id: firstId, email: firstId, provider: "gmail"}
      ], activeId: firstId})
      tryCompare(mailService, "accountCount", 2)
      var gmail = mailService.findAccount(gmailId)
      var other = mailService.findAccount(firstId)
      verify(gmail && other)
      tryVerify(function() { return gmail.auth && other.auth })
      tryCompare(mailService, "current", other)
      app.resetNavigation()
      app.openSettings()
      app.openClientSetup()
      waitForRendering(app)

      compare(app.page, "setup")
      compare(mailService.current, gmail)
      compare(mailService.accountCount, 2, "shared client setup reuses a saved account")
      compare(typeof mailService.auth.saveCredentials, "function")
      compare(named(app, "setup-page").item.auth, gmail.auth)
      compare(other.auth.loginBusy, false)
      compare(mailService.accountList.accounts[0].id, gmailId)
      compare(mailService.accountList.accounts[1].id, firstId)
    }
  }
}

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

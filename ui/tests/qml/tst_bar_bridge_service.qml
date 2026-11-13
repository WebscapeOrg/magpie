import QtQuick 2.15
import QtTest 1.3
import "../.." as Omamail

Item {
  id: root
  width: 400
  height: 60

  QtObject {
    id: nativeHost
    property bool standalone: true
    property var capabilities: ({ agent: false, tray: false, mailto: false, notifications: false })
    property var snapshots: []
    property var configWrites: []

    function updateBarStatus(value) {
      snapshots = snapshots.concat([JSON.parse(JSON.stringify(value))])
      return true
    }
    function writeConfig(name, text, callback) {
      configWrites = configWrites.concat([{ name: name, text: text }])
      if (callback) callback(true, "")
      return true
    }
    function configPath(name) { return "/private-test/config/" + name }
    function cachePath(name) { return "/private-test/cache/" + name }
  }

  Component {
    id: serviceFactory
    Omamail.Service {
      platform: nativeHost
      manifest: ({ id: "magpie-mail", name: "Magpie Mail", version: "1.0.0" })
    }
  }

  TestCase {
    name: "BarStatusService"

    function init() {
      nativeHost.snapshots = []
      nativeHost.configWrites = []
    }

    function test_native_service_publishes_only_the_envelope_snapshot() {
      var service = createTemporaryObject(serviceFactory, root)
      verify(service !== null)
      nativeHost.snapshots = []
      service.unreadTotal = 9
      service.windowOpen = true
      service.replaceSettings({ showBarIcon: false })
      verify(nativeHost.snapshots.length >= 3)

      var published = nativeHost.snapshots[nativeHost.snapshots.length - 1]
      compare(published.ready, false)
      compare(published.windowOpen, true)
      compare(published.showBarIcon, false)
      compare(published.unreadTotal, 9)
      compare(JSON.stringify(Object.keys(published).sort()),
        '["ready","showBarIcon","unreadTotal","windowOpen"]')
      compare(published.accountEmail, undefined)
      compare(published.barMessages, undefined)
      compare(published.auth, undefined)
      compare(published.shell, undefined)
      compare(published.updated, undefined, "the native host owns the publication timestamp")

      nativeHost.snapshots = []
      compare(service.publishBarStatus(false), true)
      compare(nativeHost.snapshots.length, 1)
      compare(nativeHost.snapshots[0].ready, false)
      compare(nativeHost.snapshots[0].unreadTotal, 9)
      compare(nativeHost.snapshots[0].windowOpen, true)
    }
  }
}

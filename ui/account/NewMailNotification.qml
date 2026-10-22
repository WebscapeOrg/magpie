import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root
  visible: false

  required property string notificationForeground
  required property string notificationAccent
  required property string pluginDir
  required property string accountId
  property bool nativeNotifications: false
  property bool pluginNotifications: true
  signal activated(string targetAccountId, string messageId)

  // Invariant: Each notification retains its own message target; a later poll must not redirect an earlier notification click.
  Component {
    id: notificationProcessComponent
    Process {
      id: notificationProcess
      property string targetAccountId: ""
      property string messageId: ""
      stdout: StdioCollector {
        onStreamFinished: {
          if (text.trim() === "default")
            root.activated(notificationProcess.targetAccountId,
              notificationProcess.messageId)
        }
      }
      onExited: destroy()
    }
  }

  function notify(arrivals) {
    var list = Array.isArray(arrivals) ? arrivals : []
    if (list.length === 0) return
    var title = Model.notificationTitle(list[0])
    var body = Model.notificationBody(list[0])
    if (list.length > 1) {
      var names = []
      for (var messageIndex = 0; messageIndex < list.length && messageIndex < 3; messageIndex++) names.push(Model.notificationTitle(list[messageIndex]))
      title = Model.pluralize(list.length, "new message")
      body = names.join(", ")
    }
    if (nativeNotifications && typeof Quickshell.showNotification === "function") {
      Quickshell.showNotification(root.accountId + ":" + String(list[0].id || ""),
        title, body, root.accountId, String(list[0].id || ""))
      return
    }
    if (!pluginNotifications) return
    // Invariant: Sender-controlled text stays behind the -- option separator and never enters shell code.
    var request = notificationProcessComponent.createObject(root, {
      targetAccountId: root.accountId,
      messageId: String(list[0].id || ""),
      command: ["python3", root.pluginDir + "/scripts/notify-mail.py",
        root.notificationForeground, root.notificationAccent, "--", title, body]
    })
    if (request) request.running = true
  }

}

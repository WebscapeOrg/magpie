import QtQuick

QtObject {
  property var manifest: ({
    id: "omamail", name: "Magpie Mail", version: "0.10.1",
    barWidget: {defaults:{refreshIntervalSec:333,maxMessages:17,notifyNewMail:"On"}}
  })
  property var capabilities: ({agent:false,tray:false,mailto:false,defaultMailClient:false,notifications:true})
  property var settings: ({refreshIntervalSec:333,maxMessages:17,notifyNewMail:"Off"})
  property string backendPath: "/fixture/bin/omamail"
  property string resourceRoot: "/fixture"
  property var backendContract: ({apiVersion:8, releasedApiVersion:7, contractHash:"", unreleasedMethods:[]})
  property string notificationError: ""
  property bool hidden: false
  property bool quitCalled: false
  property var pendingNotificationActivation: ({})
  property string initialActivation: "{}"
  property bool startInBackground: false
  property var barStatuses: []
  property var environmentValues: ({
    HOME: "/fixture/home",
    XDG_CONFIG_HOME: "/fixture/config",
    XDG_CACHE_HOME: "/fixture/cache",
    OMAMAIL_BIN: "/fixture/bin/omamail"
  })
  property var opened: []
  property var messageLinks: []
  property var copied: []
  property var notifications: []
  property var files: ({})
  property var watched: ({})
  property bool rejectWrites: false
  signal notificationActivated(string accountId, string messageId)
  signal activationRequested(string payload)
  signal reopenRequested()
  signal closeRequested()
  signal changed(string path)
  signal failed(string path, string error)

  function reset() {
    capabilities = ({agent:false,tray:false,mailto:false,defaultMailClient:false,notifications:true})
    resourceRoot = "/fixture"
    environmentValues = ({
      HOME: "/fixture/home",
      XDG_CONFIG_HOME: "/fixture/config",
      XDG_CACHE_HOME: "/fixture/cache",
      XDG_DATA_HOME: "/fixture/data",
      OMAMAIL_BIN: "/fixture/bin/omamail"
    })
    settings = ({refreshIntervalSec:333,maxMessages:17,notifyNewMail:"Off"})
    opened = []
    messageLinks = []
    copied = []
    notifications = []
    notificationError = ""
    pendingNotificationActivation = ({})
    initialActivation = "{}"
    startInBackground = false
    barStatuses = []
    files = ({ "/fixture/existing": "saved" })
    watched = ({})
    rejectWrites = false
    hidden = false
    quitCalled = false
  }

  function environment(name) { return String(environmentValues[name] || "") }
  function openExternal(target) { opened = opened.concat([String(target)]); return true }
  function openMessageLink(target, accountEmail) {
    messageLinks = messageLinks.concat([[String(target), String(accountEmail)]])
    return true
  }
  function setClipboard(text) { copied = copied.concat([String(text)]); return true }
  function showNotification(id, title, body, accountId, messageId) {
    notifications = notifications.concat([{
      id: String(id), title: String(title), body: String(body),
      accountId: String(accountId), messageId: String(messageId)
    }])
    return true
  }
  function configPath(name) { return "/fixture/config/omamail/" + String(name) }
  function cachePath(name) { return "/fixture/cache/omamail/" + String(name) }
  function localFilePath(url) { return String(url).replace(/^file:\/\//, "") }
  function updateSettings(value) { settings = value; return true }
  function updateBarStatus(value) {
    barStatuses = barStatuses.concat([value])
    return true
  }
  function hide() { hidden = true }
  function quit() { quitCalled = true }
  function takePendingNotificationActivation() {
    var pending = pendingNotificationActivation
    pendingNotificationActivation = ({})
    return pending
  }
  function activateNotification(accountId, messageId) {
    pendingNotificationActivation = ({accountId:String(accountId),messageId:String(messageId)})
    notificationActivated(String(accountId), String(messageId))
  }
  function read(path) {
    var key = String(path)
    if (!Object.prototype.hasOwnProperty.call(files, key)) {
      // Invariant: The native store announces a failed read as well as returning it.
      failed(key, "missing")
      return ({ ok: false, text: "", error: "missing" })
    }
    return ({ ok: true, text: String(files[key]), error: "" })
  }
  function exists(path) {
    var prefix = String(path || "") + "/"
    for (var key in files) if (key === path || key.indexOf(prefix) === 0) return true
    return false
  }
  function write(path, text, atomic) {
    if (rejectWrites) {
      failed(String(path), "write refused")
      return ({ ok: false, error: "write refused" })
    }
    var next = ({})
    var keys = Object.keys(files)
    for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) next[keys[keyIndex]] = files[keys[keyIndex]]
    next[String(path)] = String(text)
    files = next
    return ({ ok: true, error: "", atomic: !!atomic })
  }
  function watch(path, enabled) {
    var next = ({})
    var keys = Object.keys(watched)
    for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) next[keys[keyIndex]] = watched[keys[keyIndex]]
    next[String(path)] = !!enabled
    watched = next
  }
}

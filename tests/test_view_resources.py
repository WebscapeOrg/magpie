"""Render hostile settings labels and avatar bytes without Qt resource requests."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        requests.append(self.path)
        self.send_response(404)
        self.end_headers()


QML = r'''
import QtQuick
import QtTest
import @COMPONENTS@ as Views
Item {
  id: root
  width: 800; height: 900
  property string endpoint: @ENDPOINT@
  function payload(name) { return '<img src="' + endpoint + '/' + name + '">' }
  QtObject {
    id: runtime
    property string state: "ready"
    property string installedVersion: root.payload("backend-version")
    property string requiredVersion: "0.9.0"
    property string error: root.payload("backend-error")
    property string developmentExecutable: root.payload("backend-path")
    property bool development: true
    property bool busy: false
    property bool canInstall: false
    property bool cliInstalled: false
    function refresh() {}
  }
  QtObject {
    id: auth
    property bool loggedIn: false
    property bool loginBusy: false
    property bool toolsChecked: true
    property bool credentialsPresent: true
    property bool credentialsWriteBusy: false
    property var missingTools: []
    property string lastError: root.payload("gmail-error")
    property string clientId: "client"
    property string clientDescription: root.payload("oauth-client")
    property string credentialsPath: root.payload("oauth-path")
    property var credentials: null
  }
  QtObject {
    id: service
    property var auth: auth
    property string accountAddress: ""
    property string accountEmail: ""
    property string accountName: ""
    property string signInProgress: root.payload("oauth-progress")
    property string providerId: "gmail"
    property string mailboxKey: "inbox"
    property string searchQuery: root.payload("search-query")
    property bool listLoaded: true
    property bool listLoading: false
    property var messages: []
    property string pluginName: root.payload("manifest-name")
    property string version: root.payload("manifest-version")
  }
  Views.BackendSetup {
    width: 700; runtime: runtime
    textColor: "white"; dimColor: "gray"; accentColor: "orange"; panelFontFamily: "monospace"
  }
  Views.SetupPage {
    id: gmail
    width: 700; service: service
    textColor: "white"; dimColor: "gray"; dangerColor: "red"; accentColor: "orange"; panelFontFamily: "monospace"
  }
  Views.ReaderBlankSlate {
    width: 700; height: 900; service: service
    textColor: "white"; dimColor: "gray"; dimmerColor: "gray"; accentColor: "orange"; panelFontFamily: "monospace"
  }
  Views.SenderAvatar {
    id: avatar
    width: 64; height: 64
    foreground: "white"; accent: "orange"; fontFamily: "monospace"
    sender: ({display: "Synthetic sender"})
    imageData: "data:image/png;base64," + Qt.btoa('<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><image href="' + root.endpoint + '/avatar"/></svg>')
  }
  Text { text: root.payload("control") }
  TestCase {
    name: "ViewResources"
    when: windowShown
    function test_sender_bytes_never_reach_the_image_decoder() {
      compare(avatar.safeImage, "")
      compare(String(avatar.children[1].source), "")
      verify(avatar.children[0].visible)
    }
    function test_labels_make_no_requests() {
      auth.lastError = ""
      auth.lastError = root.payload("gmail-error")
      gmail.detailVisible = true
      wait(500)
    }
  }
}
'''



def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="omamail-view-resources-") as directory:
            fixture = Path(directory) / "tst_plain_labels.qml"
            endpoint = f"http://127.0.0.1:{server.server_port}"
            fixture.write_text(QML.replace("@ENDPOINT@", json.dumps(endpoint))
                               .replace("@COMPONENTS@", json.dumps((ROOT / "ui/components").as_uri())))
            environment = dict(os.environ, QT_QPA_PLATFORM="offscreen",
                               QT_QUICK_CONTROLS_STYLE="Basic",
                               QT_QUICK_CONTROLS_FALLBACK_STYLE="Basic",
                               QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="",
                               NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
            result = subprocess.run([
                sys.argv[1], "-import", str(ROOT / "ui/tests/qml/imports"), "-input", str(fixture)
            ], env=environment, timeout=30)
        assert requests == ["/control"], f"Unexpected label requests: {requests}"
        result.check_returncode()
        print("Observed native image control; settings labels and rejected avatar bytes made no requests")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()

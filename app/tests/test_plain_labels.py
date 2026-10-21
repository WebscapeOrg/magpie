"""Render hostile labels through real standalone controls and observe HTTP traffic."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
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
import QtQuick.Controls as Controls
import QtTest
import qs.Ui
Item {
  id: root
  width: 600; height: 600
  property string endpoint: @ENDPOINT@
  property string payload: '<img src="' + endpoint + '/label">'
  Column {
    Button { text: root.payload }
    Dropdown { label: root.payload }
    NumberField { label: root.payload }
    PanelActionButton { iconText: root.payload }
    PanelSectionHeader { text: root.payload }
    Controls.ToolTip { visible: true; text: root.payload }
  }
  Text { text: '<img src="' + root.endpoint + '/control">' }
  TestCase {
    name: "StandalonePlainLabels"
    when: windowShown
    function test_render() { wait(500) }
  }
}
'''


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="omamail-labels-") as directory:
            fixture = Path(directory) / "tst_plain_labels.qml"
            endpoint = f"http://127.0.0.1:{server.server_port}"
            fixture.write_text(QML.replace("@ENDPOINT@", json.dumps(endpoint)))
            environment = dict(os.environ, QT_QPA_PLATFORM="offscreen",
                               QT_QUICK_CONTROLS_STYLE="Omamail",
                               QT_QUICK_CONTROLS_FALLBACK_STYLE="Basic",
                               QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="",
                               NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
            result = subprocess.run([
                sys.argv[1], "-import", str(ROOT / "app/qml/imports"),
                "-import", str(ROOT / "app/qml/styles"), "-input", str(fixture)
            ], env=environment, timeout=30)
        result.check_returncode()
        assert requests == ["/control"], f"Unexpected label requests: {requests}"
        print("Observed native image control; standalone labels made no requests")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()

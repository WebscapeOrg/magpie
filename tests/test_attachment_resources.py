"""Real Qt image loading observes a control request and no attachment requests."""
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
import @COMPONENTS@ as Mail
Item {
  id: host
  width: 400; height: 300
  property string endpoint: @ENDPOINT@
  Component { id: positive; Image { width:20; height:20 } }
  Component {
    id: cardFactory
    Mail.AttachmentCard {
      width:280; height:180
      textColor:"white";dimColor:"gray";dimmerColor:"gray";panelFontFamily:"monospace"
    }
  }
  TestCase {
    name:"AttachmentResources";when:windowShown
    function named(item,name) {
      if(item.objectName===name)return item
      var children=item.children||[]
      for(var i=0;i<children.length;i++){var found=named(children[i],name);if(found)return found}
      return null
    }
    function test_1_positive_control() {
      verify(createTemporaryObject(positive,host,{source:endpoint+"/positive"}))
      wait(250)
    }
    function test_2_untrusted_sources_and_names_data() {
      var values=[endpoint+"/remote", "file:///etc/passwd",
        "data:image/svg+xml,<svg><image href='"+endpoint+"/svg'/></svg>",
        "data:image/png;base64,PHN2Zz48aW1hZ2UgaHJlZj0neCcvPjwvc3ZnPg==",
        '<img src="'+endpoint+'/markup">', '<img\nsrc="'+endpoint+'/lf">',
        '<img\rsrc="'+endpoint+'/cr">', '<img\r\nsrc="'+endpoint+'/crlf">',
        '<img src="'+endpoint+'/trailing">\n', '<img src="'+endpoint+'/nul">\u0000',
        'Unicode 中文 مرحبا / "quotes" / \\backslash']
      return values.map(function(value,index){return {tag:String(index),value:value}})
    }
    function test_2_untrusted_sources_and_names(data) {
      var card=createTemporaryObject(cardFactory,host,{previewSource:data.value,
        attachment:{filename:data.value,mimeType:"application/pdf",attachmentId:"part",size:1024}})
      verify(card)
      compare(String(named(card,"attachment-thumbnail").source),"")
      compare(named(card,"attachment-filename").textFormat,Text.PlainText)
      compare(card.filename,data.value)
      wait(40)
    }
    function test_3_drain_requests(){wait(250)}
  }
}
'''


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="magpie-attachment-resources-") as directory:
            path = Path(directory)
            source = QML.replace("@COMPONENTS@", json.dumps((ROOT / "ui/components").as_uri()))
            source = source.replace("@ENDPOINT@", json.dumps(f"http://127.0.0.1:{server.server_port}"))
            fixture = path / "tst_attachment_resources.qml"
            fixture.write_text(source)
            env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=str(path / "config"),
                       XDG_CACHE_HOME=str(path / "cache"), QT_QPA_PLATFORM="offscreen",
                       QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="",
                       NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
            result = subprocess.run([sys.argv[1], "-import", str(ROOT / "ui/tests/qml/imports"),
                                     "-input", str(fixture)], env=env, timeout=30)
        result.check_returncode()
        assert requests == ["/positive"], f"Attachment initiated unexpected requests: {requests}"
        print("Attachment resources: positive control observed; no thumbnail or filename initiated a request")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()

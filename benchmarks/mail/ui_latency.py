#!/usr/bin/env python3
"""Measure production component updates through Qt's completed render frame."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def absolute_imports(source):
    return source.replace('"../../', '"' + (ROOT / "ui").as_uri() + "/")


def run(runner, source, directory, name):
    path = directory / ("tst_" + name + ".qml")
    path.write_text(source)
    result = subprocess.run(
        [runner, "-input", str(path), "-import", str(ROOT / "ui/tests/qml/imports")],
        env=dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
                 QT_QPA_PLATFORMTHEME="", QT_SCALE_FACTOR="1"),
        text=True, capture_output=True, timeout=120)
    (directory / (name + ".log")).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    match = re.search(r"PAINT_RESULT (\{[^\n]+\})", result.stdout)
    if not match:
        raise RuntimeError("No completed-frame measurement: " + result.stdout)
    return json.loads(match[1])


def measurements(item, operation, setup=""):
    return """
  TestCase {
    name: "PaintLatency"
    when: windowShown
    function test_completed_frames() {
      SETUP
      verify(waitForRendering(ITEM,2000))
      var samples=[]
      for (var n=-5;n<31;n++) {
        var began=Date.now()
        OPERATION
        verify(waitForRendering(ITEM,2000),"a completed render frame is required")
        if (n>=0) samples.push(Date.now()-began)
      }
      var sorted=samples.slice().sort(function(a,b){return a-b})
      console.log("PAINT_RESULT "+JSON.stringify({medianMs:sorted[15],p95Ms:sorted[29],samplesMs:samples}))
    }
  }
}
""".replace("SETUP", setup).replace("ITEM", item).replace("OPERATION", operation)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=ROOT / "target/debug/omamail")
    parser.add_argument("--runner", default="/usr/lib/qt6/bin/qmltestrunner")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="magpie-paint-") as temp:
        directory = Path(temp)
        source = (ROOT / "ui/tests/qml/tst_load_more.qml").read_text().split("  TestCase {")[0]
        setup = """fakeService.hasMore=false
      var rows=[]
      for (var i=0;i<10000;i++) rows.push({id:"synthetic-"+i,from:{display:"Synthetic sender",email:"sender@example.test"},
        subject:"Synthetic message "+i,snippet:"Mailbox performance fixture",labelIds:["INBOX"],unread:false})
      fakeService.messages=rows"""
        listing = run(args.runner, absolute_imports(source) + measurements(
            "list", 'list.reveal(n%2===0 ? "synthetic-9999" : "synthetic-0")', setup),
            directory, "list")
        html = "<html><body>" + "".join(
            "<p><b>Section %d.</b> Synthetic newsletter text with no remote resources.</p>" % n
            for n in range(700)) + "</body></html>"
        inputs = [{"jsonrpc": "2.0", "id": n, "method": "message.render",
                   "params": {"html": html.replace("Section", "Part" if n else "Section"),
                              "options": {"withReader": True, "withPlainText": True}}}
                  for n in range(2)]
        backend = subprocess.run([str(args.binary.resolve()), "serve"],
                                 input="\n".join(json.dumps(v) for v in inputs) + "\n",
                                 capture_output=True, text=True, timeout=30)
        resources = [json.loads(line)["result"] for line in backend.stdout.splitlines()
                     if json.loads(line).get("id") in (0, 1)]
        if len(resources) != 2:
            raise RuntimeError("Native fixture preparation failed: " + backend.stdout[:1000])
        source = (ROOT / "ui/tests/qml/tst_reader_mode.qml").read_text().split("  TestCase {")[0]
        source = source.replace('readonly property var rendered: Html.sanitize(senderHtml, ({ withReader: true }))',
                                "property var fixtures: " + json.dumps(resources) +
                                "\n  property var rendered: fixtures[0]")
        source = source.replace('bodyMode: "reader"', 'bodyMode: "original"')
        reader = run(args.runner, absolute_imports(source) + measurements(
            "reader", "rendered=fixtures[Math.abs(n)%2]"), directory, "reader")
        report = {
            "measuredAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "conditions": "Qt software renderer, offscreen 1x. Five warmups, 31 completed frames. Synthetic data. "
                          "List navigation starts with 10,000 summaries in memory. The large HTML starts with native prepared data. "
                          "This includes QML layout/rendering; it excludes RPC, disk, network and compositor presentation.",
            "list": listing, "largeHtml": reader, "htmlBytes": len(html.encode()),
            "backendSha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

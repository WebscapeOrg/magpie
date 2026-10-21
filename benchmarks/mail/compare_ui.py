#!/usr/bin/env python3
"""Compare committed and working-tree QML with identical synthetic fixtures."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "aeac13160f70a86f6419eaf2ceb1695fad078c7c"

QML = r'''
import QtQuick
import QtTest
import __COMPONENTS__ as Mail
import __MODEL__ as Model
import __RECIPIENTS__ as Recipients
Item {
  width: 720; height: 600
  QtObject {
    id: service
    property var messages: []
    property bool hasMore: false
    property bool listLoading: false
    property bool listLoaded: true
    property string searchQuery: ""
    property string selectedId: ""
    property bool canArchive: true
    property string contentDirection: "auto"
    property var agentJobs: ({})
    property var agentAttentionByMessage: ({})
    property var inboxTools: null
    property var backend: null
    function loadMore() { throw new Error("benchmark must not fetch") }
  }
  __LIST__
  TestCase {
    name: "BeforeAfter"
    when: windowShown
    function sample(operation, reset) {
      var times=[]
      for (var n=-3;n<31;n++) {
        if (reset) reset()
        var began=Date.now()
        operation(n)
        verify(waitForRendering(viewport,5000),"a completed frame is required")
        if (n>=0) times.push(Date.now()-began)
      }
      var sorted=times.slice().sort(function(a,b){return a-b})
      return {medianMs:sorted[15],p95Ms:sorted[29],samplesMs:times}
    }
    function delegates(item) {
      var count=typeof item.summary!=="undefined" && typeof item.hasCursor!=="undefined" ? 1 : 0
      for (var i=0;i<item.children.length;i++) count+=delegates(item.children[i])
      return count
    }
    function navigate(n) {
      var id="synthetic-"+(n%2===0 ? __COUNT__-1 : 0)
      list.cursorId=id
      service.selectedId=id
      __REVEAL__
    }
    function test_list() {
      var rows=[]
      for (var i=0;i<__COUNT__;i++) rows.push({id:"synthetic-"+i,threadId:"",
        from:{display:"Synthetic sender",email:"sender@example.test"},
        subject:"Synthetic message "+i,snippet:"Mailbox performance fixture",
        time:"12:00",date:"",labelIds:["INBOX"],unread:false,starred:false,inInbox:true})
      service.messages=rows
      verify(waitForRendering(viewport,5000))
      var populated=sample(function(){service.messages=rows},function(){
        service.messages=[];wait(20)
      })
      var count=delegates(list)
      var navigation=sample(navigate)
      verify(service.selectedId==="synthetic-"+(__COUNT__-1))
      var bounds=list.boundsFor(service.selectedId)
      verify(bounds!==null,"the selected row must exist after painting")
      verify(bounds.y+bounds.height>=viewport.contentY && bounds.y<=viewport.contentY+viewport.height,
        "the selected row must be visible")
      var updated=sample(function(n){
        var replacement=rows.slice()
        replacement[__COUNT__-1]=Object.assign({},rows[__COUNT__-1],{unread:n%2===0})
        service.messages=replacement
      })
      console.log("COMPARISON "+JSON.stringify({
        populate:populated,navigate:navigation,update:updated,liveRows:count,count:rows.length
      }))
    }
  }
}
'''
FIELDS = '''
      id: list
      service: service
      textColor: "#eeeeee"; accentColor: "#88aadd"
      dimColor: "#aaaaaa"; urgentColor: "#ff5555"
      panelFontFamily: "monospace"
'''


def source(root, count):
    virtual = (root / "ui/components/MessageList.qml").read_text().split("ListView {", 1)
    if len(virtual) == 2:
        listing = "Mail.MessageList { anchors.fill: parent;" + FIELDS + " }\n property var viewport: list"
        reveal = "list.reveal(id)"
    else:
        listing = ("Flickable { id: viewport; anchors.fill: parent; clip: true;"
                   "contentWidth: width; contentHeight: list.implicitHeight+16;"
                   "Mail.MessageList { width: viewport.width; scroller: viewport;" + FIELDS + "}}")
        reveal = ("var bounds=list.boundsFor(id);verify(bounds!==null);"
                  "viewport.contentY=Model.contentYToReveal(viewport.contentY,viewport.height,"
                  "list.y+bounds.y,bounds.height,viewport.contentHeight,8)")
    return (QML.replace("__COMPONENTS__", json.dumps((root / "ui/components").as_uri()))
            .replace("__MODEL__", json.dumps((root / "ui/account/Model.js").as_uri()))
            .replace("__RECIPIENTS__", json.dumps((root / "ui/compose/Recipients.js").as_uri()))
            .replace("__LIST__", listing).replace("__REVEAL__", reveal)
            .replace("__COUNT__", str(count)))


def tree_hash(root):
    digest = hashlib.sha256()
    for path in sorted((root / "ui").rglob("*")):
        if path.is_file() and path.suffix in (".qml", ".js"):
            digest.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--counts", nargs="+", type=int, default=[100, 1000])
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--runner", default=shutil.which("qmltestrunner6") or (
        "/usr/lib/qt6/bin/qmltestrunner" if Path("/usr/lib/qt6/bin/qmltestrunner").exists()
        else shutil.which("qmltestrunner")))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.repetitions <= 10 or any(n < 2 or n > 10000 for n in args.counts):
        parser.error("use 1–10 repetitions and 2–10000 rows")
    revision = subprocess.check_output(
        ["git", "rev-parse", "--verify", args.baseline + "^{commit}"], cwd=ROOT, text=True).strip()
    archive = subprocess.check_output(["git", "archive", revision, "ui"], cwd=ROOT)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    logs = args.output.parent / (args.output.stem + "-logs")
    logs.mkdir(exist_ok=True)
    results = []
    qt_versions = set()
    started = os.getloadavg()
    with tempfile.TemporaryDirectory(prefix="magpie-compare-") as temp:
        baseline = Path(temp) / "before"
        baseline.mkdir()
        with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
            tree.extractall(baseline, filter="data")
        hashes = {"before": tree_hash(baseline), "after": tree_hash(ROOT)}
        for count in args.counts:
            for repetition in range(args.repetitions):
                order = [("before", baseline), ("after", ROOT)]
                if repetition % 2:
                    order.reverse()
                for label, root in order:
                    name = f"{count}-{repetition}-{label}"
                    qml = Path(temp) / ("tst_" + name + ".qml")
                    qml.write_text(source(root, count))
                    result = subprocess.run(
                        [args.runner, "-input", str(qml), "-import", str(root / "ui/tests/qml/imports")],
                        text=True, capture_output=True, timeout=300,
                        env=dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
                                 QT_QPA_PLATFORMTHEME="", QT_SCALE_FACTOR="1"))
                    (logs / (name + ".log")).write_text(result.stdout + result.stderr)
                    match = re.search(r"COMPARISON (\{[^\n]+\})", result.stdout)
                    if result.returncode or not match:
                        raise RuntimeError("Qt comparison failed; see " + str(logs / (name + ".log")))
                    measurement = json.loads(match[1])
                    qt_versions.update(line for line in result.stdout.splitlines() if line.startswith("Config:"))
                    results.append(dict(label=label, repetition=repetition, **measurement))
                    print(name, json.dumps({k: v["p95Ms"] if isinstance(v, dict) else v
                                           for k, v in measurement.items()}), flush=True)
    comparisons = []
    for count in args.counts:
        for metric in ("populate", "navigate", "update"):
            medians = {label: statistics.median(
                row[metric]["p95Ms"] for row in results if row["label"] == label and row["count"] == count)
                for label in ("before", "after")}
            comparisons.append(dict(rows=count, metric=metric, **medians,
                                    speedup=medians["before"] / medians["after"] if medians["after"] else None,
                                    reductionPercent=(1 - medians["after"] / medians["before"]) * 100
                                    if medians["before"] else None))
    report = dict(
        measuredAt=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), baselineCommit=revision,
        sourceHashes=hashes, harnessSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        platform=platform.platform(), cpu=platform.processor(), logicalCpus=os.cpu_count(),
        loadBefore=started, loadAfter=os.getloadavg(), qt=sorted(qt_versions),
        conditions="720×600, monospace, fixed synthetic colours, Qt offscreen software renderer at 1x. "
        "Three warmups and 31 completed frames per operation per run. Alternating version order. "
        "Tables use median of each run's p95; raw samples retained. Population starts with an empty, "
        "already-running component and in-memory summaries; navigation selects/reveals opposite ends; "
        "update replaces the array and toggles unread on the visible last row. Real production components "
        "and each revision's shell test imports. Excludes provider, disk, RPC, startup and compositor. "
        "No claim about whole-app speed or fresh OS caches. Shared machine, no CPU isolation.",
        comparisons=comparisons, runs=results)
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()

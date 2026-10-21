#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
MAIL = ROOT / "benchmarks/mail"
sys.path.insert(0, str(MAIL))


def load(name):
    specification = importlib.util.spec_from_file_location(name, MAIL / (name + ".py"))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class Child:
    def __init__(self, output="", timeout=False):
        self.pid = 12345
        self.returncode = None
        self.stdout = io.StringIO(output)
        self.output = output
        self.timeout = timeout
        self.waited = False

    def communicate(self, timeout=None):
        if self.timeout:
            self.timeout = False
            raise subprocess.TimeoutExpired("synthetic", timeout)
        self.returncode = 0
        return self.output, None

    def poll(self):
        return self.returncode

    def terminate(self):
        self.returncode = -15

    def kill(self):
        self.returncode = -9

    def wait(self, timeout=None):
        self.waited = True
        self.returncode = self.returncode or 0
        return self.returncode


class BenchmarkProcesses(unittest.TestCase):
    def roundtrip(self, child):
        module = load("roundtrip")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            benchmark = root / "benchmarks/mail"
            baseline = benchmark / "baseline/ui"
            baseline.mkdir(parents=True)
            (baseline.parent / "manifest.json").write_text(json.dumps({"sha256": {}}))
            for name in ("roundtrip.py", "corpus.py", "run.py"):
                (benchmark / name).write_text("")
            for folder in ("ui/backend", "ui/message", "src", "target/release"):
                (root / folder).mkdir(parents=True)
            (root / "Cargo.toml").write_text('[package]\nversion="0.11.0"\n')
            (root / "backend-api.json").write_text('{"apiVersion":8}')
            (root / "target/release/omamail").write_bytes(b"synthetic executable")
            with patch.object(module, "HERE", benchmark), patch.object(module, "ROOT", root), \
                    patch.object(module, "corpus", return_value=[]), \
                    patch.object(module, "__file__", str(benchmark / "roundtrip.py")), \
                    patch.object(sys, "argv", ["roundtrip.py", "--samples", "3"]), \
                    patch.object(subprocess, "run"), \
                    patch.object(subprocess, "check_output", return_value="synthetic version"), \
                    patch.object(subprocess, "Popen", return_value=child), \
                    patch.object(os, "killpg") as kill_group, \
                    patch("builtins.print"):
                try:
                    module.main()
                except subprocess.TimeoutExpired:
                    pass
                return kill_group.call_args_list

    def test_completed_roundtrip_does_not_signal_reaped_process_group(self):
        child = Child("ROUNDTRIP_DONE\n")
        self.assertEqual(self.roundtrip(child), [])
        self.assertEqual(child.returncode, 0)

    def test_timed_out_roundtrip_terminates_owned_group(self):
        child = Child(timeout=True)
        calls = self.roundtrip(child)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].args[0], child.pid)
        self.assertIsNotNone(child.returncode)

    def test_desktop_setup_failure_reaps_private_bus(self):
        with patch.dict(sys.modules, {"PIL": SimpleNamespace(Image=None, ImageGrab=None)}):
            module = load("desktop_acceptance")
        bus = Child("unix:path=/synthetic-private-bus\n")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "synthetic"
            executable.write_bytes(b"synthetic executable")
            arguments = ["desktop_acceptance.py", "--output", str(root / "output"),
                         "--binary", str(executable), "--driver", str(executable),
                         "--display-mode", "xvfb"]
            with patch.object(sys, "argv", arguments), \
                    patch.object(module, "source_hash", return_value="synthetic source"), \
                    patch.object(module, "seed", return_value={}), \
                    patch.object(subprocess, "Popen", side_effect=[bus, OSError("display startup refused")]), \
                    patch.dict(os.environ, {}, clear=False):
                with self.assertRaisesRegex(OSError, "display startup refused"):
                    module.main()
            self.assertTrue(bus.waited, "Setup failure must reap the private DBus process")

    def test_ipc_timeout_cleans_descendant_after_leader_exit(self):
        specification = importlib.util.spec_from_file_location("ipc_benchmark", ROOT / "benchmarks/ipc/run.py")
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        spawn = subprocess.Popen
        children = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for folder in ("src/backend", "ui/backend", "ui/message", "target/ipc-bench/release"):
                (root / folder).mkdir(parents=True)
            (root / "src/backend/protocol.rs").write_text(
                "pub const MAX_FRAME = 1; const MAX_IN_FLIGHT = 1; fn reply() {} #[cfg(test)]")
            (root / "Cargo.toml").write_text('[package]\nversion="0.11.0"\n')
            (root / "Cargo.lock").write_text('[[package]]\nname="serde_json"\nversion="1.0.0"\n')
            marker = root / "survivor"
            descendant = root / "descendant"
            program = ("import os, pathlib, time; child=os.fork(); "
                       "os._exit(0) if child else None; pathlib.Path(" + repr(str(descendant)) +
                       ").write_text(str(os.getpid())); time.sleep(.4); pathlib.Path(" + repr(str(marker)) +
                       ").write_text('survived'); time.sleep(60)")
            class ShortDeadline:
                def __init__(self, child):
                    self.child = child
                    self.first = True
                def __getattr__(self, name):
                    return getattr(self.child, name)
                def communicate(self, timeout=None):
                    deadline = .15 if self.first else timeout
                    self.first = False
                    return self.child.communicate(timeout=deadline)
            def fixture(*args, **kwargs):
                child = spawn([sys.executable, "-u", "-c", program], start_new_session=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                children.append(child)
                return ShortDeadline(child)
            try:
                with patch.object(module, "ROOT", root), patch.object(subprocess, "run"), \
                        patch.object(subprocess, "check_output", return_value="synthetic version"), \
                        patch.object(subprocess, "Popen", side_effect=fixture):
                    with self.assertRaises(subprocess.TimeoutExpired):
                        module.main()
                time.sleep(.5)
                self.assertFalse(marker.exists(), "Timed-out IPC descendants must not write after cleanup")
            finally:
                if descendant.exists():
                    try:
                        os.kill(int(descendant.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                for child in children:
                    child.wait()
                    child.stdout.close()

    def test_desktop_measurements_include_the_named_actions(self):
        source = (MAIL / "tst_desktop.qml").read_text()
        markers = {"offlineEdit": "var editedId =", "compose": 'Probe.checkpoint("offline-star-',
                   "composeFocus": "var send ="}
        snippets = {}
        for kind, marker in markers.items():
            start = source.index(marker)
            capture = source.index('capture("' + kind + '"', start)
            end = source.index("\n", capture)
            snippets[kind] = source[start:end]
        program = r'''const assert = require("node:assert/strict");
const vm = require("node:vm");
const snippets = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
for (const [kind, source] of Object.entries(snippets)) {
  let clock = 0, actionAt = null, observed = false;
  const action = () => { actionAt = ++clock; };
  const context = {
    Date: {now: () => ++clock},
    desktop: {service: {messages: Array.from({length: 26}, (_, id) => ({id})), toggleStar: action},
              app: {startCompose: action}},
    row: () => ({starred: true}), tryVerify: () => {}, tryCompare: () => {}, verify: () => {},
    find: () => ({forceActiveFocus: action}), Probe: {checkpoint: () => {}},
    capture: (name, began) => {
      observed = true;
      assert.equal(name, kind);
      assert.ok(began < actionAt, `${kind} must begin before its action (${began} vs ${actionAt})`);
    }
  };
  vm.runInNewContext(source, context);
  assert.ok(observed, kind + " must produce a measurement");
}
'''
        result = subprocess.run(["node", "-e", program], input=json.dumps(snippets),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_desktop_capture_acknowledges_only_the_presented_frame(self):
        with patch.dict(sys.modules, {"PIL": SimpleNamespace(Image=None, ImageGrab=None)}):
            module = load("desktop_acceptance")
        display = module.DisplayCapture({"DISPLAY": ":synthetic"}, 12345, "xvfb", 1.5)
        cyan = SimpleNamespace(getpixel=lambda point: (0, 255, 255))
        magenta = SimpleNamespace(getpixel=lambda point: (255, 0, 255))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            event = {"kind": "compose", "serial": 1, "started": 1750}
            with patch.object(display, "marker", side_effect=[cyan, magenta]) as marker, \
                    patch.object(display, "save") as save, \
                    patch.object(module.time, "time", return_value=2):
                frame = display.capture(event, 1500, output)
                self.assertEqual(marker.call_count, 2, "A previous frame must not complete the capture")
                self.assertEqual(frame.result["presentedMs"], 250)
                self.assertFalse((output / "capture-1").exists())
                display.acknowledge(frame, output)
                save.assert_called_once_with({"at": [0, 0], "size": [1536, 1152]}, output / "compose.png")
                self.assertTrue((output / "capture-1").exists())

    def stalled_desktop_bus(self, prefix):
        with patch.dict(sys.modules, {"PIL": SimpleNamespace(Image=None, ImageGrab=None)}):
            module = load("desktop_acceptance")
        spawn = subprocess.Popen
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "synthetic"
            executable.write_bytes(b"synthetic executable")
            forbidden = root / "late-write"
            program = ("import pathlib, sys, time; sys.stdout.write(" + repr(prefix) + "); "
                       "sys.stdout.flush(); time.sleep(1); pathlib.Path(" + repr(str(forbidden)) +
                       ").write_text('must not survive readiness timeout'); time.sleep(60)")
            children = []
            def bus(*args, **kwargs):
                child = spawn([sys.executable, "-u", "-c", program], stdout=subprocess.PIPE, text=True)
                children.append(child)
                return child
            def expired(*args):
                raise AssertionError("Readiness exceeded the outer test watchdog")
            previous = signal.signal(signal.SIGALRM, expired)
            signal.setitimer(signal.ITIMER_REAL, 2)
            try:
                with patch.object(sys, "argv", ["desktop_acceptance.py", "--output", str(root / "output"),
                        "--binary", str(executable), "--driver", str(executable), "--display-mode", "xvfb"]), \
                        patch.object(module, "source_hash", return_value="synthetic source"), \
                        patch.object(module, "seed", return_value={}), \
                        patch.object(module, "STARTUP_TIMEOUT", .05, create=True), \
                        patch.object(subprocess, "Popen", side_effect=bus):
                    with self.assertRaisesRegex(RuntimeError, "DBus readiness timed out"):
                        module.main()
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, previous)
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait()
                    child.stdout.close()
            self.assertEqual(len(children), 1, "Display setup must not start without a ready bus")
            self.assertFalse(forbidden.exists(), "Stalled setup must not leave its child running")

    def test_desktop_readiness_timeout_reaps_silent_bus(self):
        self.stalled_desktop_bus("")

    def test_desktop_readiness_timeout_reaps_partial_line_bus(self):
        self.stalled_desktop_bus("unix:path=/unfinished")


if __name__ == "__main__":
    unittest.main()

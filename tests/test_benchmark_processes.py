#!/usr/bin/env python3
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main()

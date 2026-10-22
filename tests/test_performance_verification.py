#!/usr/bin/env python3
"""The verification runner preserves failures and confines test state/processes."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verification", ROOT / "scripts/verify-performance.py")
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


class VerificationTests(unittest.TestCase):
    def test_child_environment_has_no_account_state_or_tokens(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            with patch.dict(os.environ, {"GH_TOKEN": "secret", "DBUS_SESSION_BUS_ADDRESS": "real-bus",
                                         "OMAMAIL_BIN": "/installed/binary", "WAYLAND_DISPLAY": "real-display"}):
                env = verification.test_environment(directory)
            for key in ("GH_TOKEN", "DBUS_SESSION_BUS_ADDRESS", "OMAMAIL_BIN", "WAYLAND_DISPLAY"):
                self.assertNotIn(key, env)
            for key in ("HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
                self.assertTrue(Path(env[key]).is_relative_to(directory))
                self.assertEqual(Path(env[key]).stat().st_mode & 0o777, 0o700)

    def test_failure_keeps_exit_status_and_log(self):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "failed.log"
            result = verification.execute([sys.executable, "-c", "print('failure evidence');exit(7)"],
                                          os.environ.copy(), log, 5)
            self.assertEqual(result["status"], "fail")
            self.assertEqual(result["exitCode"], 7)
            self.assertIn("failure evidence", log.read_text())

    def test_low_space_capability_does_not_depend_on_pdf_tools(self):
        requirements = {name: needs for name, _, needs in verification.stages("ci", Path("/tmp/report"), "HEAD")}
        self.assertNotIn("pdf-sandbox", requirements["low-space"])
        self.assertIn("low-space-sandbox", requirements["low-space"])
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(verification, "thumbnail_sandbox", side_effect=RuntimeError("no PDF renderer")), \
                patch.object(verification.subprocess, "run") as run:
            run.return_value.returncode = 0
            capabilities = verification.capabilities(Path(temporary))
        self.assertEqual(capabilities["pdf-sandbox"]["status"], "blocked")
        self.assertEqual(capabilities["low-space-sandbox"]["status"], "pass")
        self.assertTrue(any("--size" in call.args[0] and "67108864" in call.args[0]
                            for call in run.call_args_list))

    def test_timeout_kills_descendants_before_their_write(self):
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / "forbidden-write"
            child = f"import time;from pathlib import Path;time.sleep(1);Path({str(marker)!r}).touch()"
            parent = f"import subprocess,sys,time;subprocess.Popen([sys.executable,'-c',{child!r}]);time.sleep(5)"
            result = verification.execute([sys.executable, "-c", parent], os.environ.copy(),
                                          Path(temp) / "timeout.log", .2)
            self.assertEqual(result["status"], "fail")
            self.assertEqual(result["reason"], "deadline exceeded")
            time.sleep(1.1)
            self.assertFalse(marker.exists(), "the timed-out process tree must not continue work")

    def test_report_retains_blocked_and_failed_results(self):
        with tempfile.TemporaryDirectory() as temp:
            report = {"profile": "ci", "status": "fail", "gates": [
                {"name": "one", "status": "pass"},
                {"name": "two", "status": "blocked", "reason": "no socket"},
                {"name": "three", "status": "fail", "exitCode": 7}]}
            verification.save(Path(temp), report)
            self.assertEqual(json.loads((Path(temp) / "results.json").read_text()), report)
            self.assertIn("| two | blocked | no socket |", (Path(temp) / "summary.md").read_text())

    def test_ci_includes_native_qml_security_and_actual_api(self):
        gates = {name: command for name, command, _ in verification.stages("ci", Path("/tmp/report"), "HEAD")}
        self.assertIn("test-qml", gates["qml"])
        self.assertIn("tests/test_backend_api.py", gates["api-contract"])
        self.assertIn("--no-tests=error", gates["native-host"])
        self.assertIn("test-rust", gates["rust"])
        self.assertIn("local_mail::recovery_tests", gates["offline-recovery"])
        self.assertIn("process::", gates["subprocess"])
        requirements = {name: needs for name, _, needs in verification.stages("ci", Path("/tmp/report"), "HEAD")}
        self.assertNotIn("tcp", requirements["offline-recovery"])
        self.assertNotIn("dbus", requirements["subprocess"])
        for name in ("standalone-qml", "native-host", "qml-lint", "qml-components", "shell-independent"):
            self.assertNotIn("dbus", requirements[name])
            self.assertNotIn("tcp", requirements[name])
            self.assertNotIn("dbus-run-session", gates[name])
        self.assertIn("test-shell-independent", gates["shell-independent"])
        self.assertIn("test-shell-portable", gates["shell"])
        self.assertIn("tcp", requirements["shell"])
        self.assertIn("pdf-sandbox", requirements["rust"])
        self.assertIn("tests/run_qml_components.py", gates["qml-components"])
        self.assertIn("QMLLINT=" + (verification.qt_tool("qmllint") or "qmllint"), gates["qml-lint"])
        self.assertEqual(verification.prerequisites("api-contract"), ["build"])
        self.assertEqual(verification.prerequisites("database-background"), ["build-benchmarks"])
        self.assertEqual(verification.prerequisites("javascript"), [])
        desktop = {name for name, _, _ in verification.stages("desktop", Path("/tmp/report"), "HEAD")}
        self.assertTrue({"validate", "quickshell-bridge"} <= desktop)


if __name__ == "__main__":
    unittest.main()

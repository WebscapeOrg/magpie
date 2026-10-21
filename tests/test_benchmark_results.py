#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CompilerProfileResults(unittest.TestCase):
    def compare(self, transform):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            program = '''import json, sys
payload = json.load(sys.stdin)
cases = [dict(name=case["name"], phase=phase, coldUs=1,
              samplesUs=[1] * payload["samples"],
              result={"document": {"type": "root", "children": []}})
         for case in payload["cases"] for phase in payload["phases"]]
TRANSFORM
print(json.dumps({"cases": cases}))
'''
            for name, change in (("size", ""), ("speed", transform)):
                executable = root / name
                executable.write_text("#!" + sys.executable + "\n" + program.replace("TRANSFORM", change))
                executable.chmod(0o700)
            output = root / "results.json"
            result = subprocess.run(
                [sys.executable, "-O", str(ROOT / "benchmarks/mail/compiler_profiles.py"),
                 "--size", str(root / "size"), "--speed", str(root / "speed"),
                 "--output", str(output)], capture_output=True, text=True, timeout=30,
                env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
            report = json.loads(output.read_text()) if output.exists() else None
            return result, report

    def test_valid_comparison_is_recorded(self):
        result, report = self.compare("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(report["results"]), 10)

    def assert_refused(self, transform):
        result, report = self.compare(transform)
        self.assertNotEqual(result.returncode, 0, "Unequal work must not pass in optimized Python")
        self.assertIsNone(report, "Invalid measurement must not publish a comparison")

    def test_wrong_identity_is_refused_with_python_optimization(self):
        self.assert_refused('cases[0]["name"] = "wrong-case"')

    def test_unequal_output_is_refused_with_python_optimization(self):
        self.assert_refused('cases[0]["result"]["filename"] = "different.txt"')

    def test_missing_samples_are_refused(self):
        self.assert_refused('cases[0]["samplesUs"] = [1]')

    def test_missing_case_is_refused(self):
        self.assert_refused('cases.pop()')


if __name__ == "__main__":
    unittest.main()

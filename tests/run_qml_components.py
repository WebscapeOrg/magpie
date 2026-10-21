#!/usr/bin/env python3
"""Run independent QML components; retain native-bridge exclusions explicitly."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verification", ROOT / "scripts/verify-performance.py")
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    report = {"status": "running", "nativeBridgeRequired": [], "tests": []}
    with tempfile.TemporaryDirectory(prefix="magpie-qml-components-") as temporary:
        environment = verification.test_environment(Path(temporary))
        for path in sorted((ROOT / "ui/tests/qml").glob("tst_*.qml")):
            name = str(path.relative_to(ROOT))
            if re.search(r'^\s*import\s+"NativeIntentFixture\.js"', path.read_text(), re.MULTILINE):
                report["nativeBridgeRequired"].append(name)
                continue
            command = [args.runner, "-input", str(path), "-import", str(ROOT / "ui/tests/qml/imports")]
            result = verification.execute(command, environment, output / (path.stem + ".log"), 90)
            report["tests"].append(dict(file=name, **result))
            print(path.name + ": " + result["status"], flush=True)
            (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    report["status"] = "pass" if report["tests"] and all(
        test["status"] == "pass" for test in report["tests"]) else "fail"
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Components: {len(report['tests'])}; native bridge still required: "
          f"{len(report['nativeBridgeRequired'])}; result: {report['status']}")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())

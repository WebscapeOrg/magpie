#!/usr/bin/env python3
"""Exercise real free-space refusal in a private 64 MiB filesystem."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TEST = "local_mail::provider_tests::low_space_refuses_body_download_and_preserves_saved_mail"


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        shutil.copytree("/tmp/fixture-seed", "/tmp/mail-check/store")
        os.execv(sys.argv[2], [sys.argv[2], "--exact", TEST, "--ignored", "--nocapture"])
    options = subprocess.run(["/usr/bin/bwrap", "--help"], capture_output=True, text=True, check=True)
    if "--size BYTES" not in options.stdout:
        raise SystemExit("Low-space verification requires Bubblewrap 0.7 or newer with bounded tmpfs support")
    build = subprocess.run(
        ["cargo", "test", "--locked", "--lib", "--no-run", "--message-format=json"],
        cwd=ROOT, stdout=subprocess.PIPE, text=True, check=True)
    executables = [row["executable"] for line in build.stdout.splitlines()
                   if (row := json.loads(line)).get("reason") == "compiler-artifact"
                   and row.get("executable") and row["profile"]["test"]
                   and row["target"]["kind"] == ["lib"]]
    if len(executables) != 1:
        raise SystemExit("expected exactly one library test executable")
    with tempfile.TemporaryDirectory(prefix="magpie-low-space-seed-") as seed:
        subprocess.run([executables[0], "--exact", TEST, "--ignored", "--nocapture"],
                       env=dict(os.environ, MAGPIE_LOW_SPACE_SEED=seed), check=True)
        command = ["/usr/bin/bwrap", "--unshare-all", "--die-with-parent", "--new-session",
               "--cap-drop", "ALL", "--ro-bind", "/", "/", "--proc", "/proc",
               "--dev", "/dev", "--size", str(64 * 1024 * 1024), "--tmpfs", "/tmp",
               "--ro-bind", seed, "/tmp/fixture-seed",
               "--ro-bind", str(Path(__file__).resolve()), "/tmp/fixture-worker.py",
               "--ro-bind", executables[0], "/tmp/fixture-test",
               "--perms", "0700", "--dir", "/tmp/mail-check",
               "--chdir", "/tmp/mail-check",
               "--setenv", "TMPDIR", "/tmp/mail-check",
               "--unsetenv", "MAGPIE_LOW_SPACE_SEED",
               "--setenv", "OMAMAIL_ACTION_TEST_CHILD", TEST,
               str(Path(sys.executable).resolve()), "/tmp/fixture-worker.py", "--worker", "/tmp/fixture-test"]
        result = subprocess.run(command, cwd=ROOT, env=os.environ.copy(), timeout=30)
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Exercise real free-space refusal in a private 64 MiB filesystem."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TEST = "local_mail::provider_tests::low_space_refuses_body_download_and_preserves_saved_mail"


def main():
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
               "--perms", "0700", "--dir", "/tmp/mail-check",
               "--setenv", "TMPDIR", "/tmp/mail-check",
               "--setenv", "OMAMAIL_ACTION_TEST_CHILD", TEST,
               executables[0], "--exact", TEST, "--ignored", "--nocapture"]
        result = subprocess.run(command, cwd=ROOT, env=os.environ.copy(), timeout=30)
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()

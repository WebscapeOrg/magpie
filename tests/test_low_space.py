#!/usr/bin/env python3
"""Run the low-space harness from a checkout and test binary beneath /tmp."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BWRAP = Path("/usr/bin/bwrap")


class LowSpaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BWRAP.is_file():
            raise unittest.SkipTest("Bubblewrap is unavailable")
        probe = subprocess.run(
            [str(BWRAP), "--unshare-all", "--die-with-parent", "--ro-bind", "/", "/",
             "--proc", "/proc", "--dev", "/dev", "/usr/bin/true"],
            capture_output=True, text=True, timeout=10)
        if probe.returncode:
            raise unittest.SkipTest("Bubblewrap user namespaces are unavailable: " + probe.stderr.strip())
        help_result = subprocess.run([str(BWRAP), "--help"], capture_output=True, text=True, check=True)
        if "--size BYTES" not in help_result.stdout:
            raise unittest.SkipTest("Bubblewrap lacks bounded tmpfs support")

    def test_tmp_checkout_and_binary_survive_private_tmpfs(self):
        with tempfile.TemporaryDirectory(prefix="low-space-harness-", dir="/tmp") as temporary:
            root = Path(temporary)
            scripts = root / "checkout/scripts"
            scripts.mkdir(parents=True)
            harness = scripts / "test-low-space.py"
            shutil.copyfile(ROOT / "scripts/test-low-space.py", harness)
            binary = root / "library-test"
            binary.write_text("#!" + str(Path(sys.executable).resolve()) + "\n" + r'''
import errno
import os
from pathlib import Path
import sys

assert sys.argv[1:] == ["--exact", "local_mail::provider_tests::low_space_refuses_body_download_and_preserves_saved_mail", "--ignored", "--nocapture"]
seed = os.environ.get("MAGPIE_LOW_SPACE_SEED")
if seed:
    Path(seed, "saved-mail").write_bytes(b"saved synthetic mail")
    raise SystemExit(0)
store = Path("/tmp/mail-check/store")
assert Path.cwd() == store.parent
assert store.joinpath("saved-mail").read_bytes() == b"saved synthetic mail"
space = os.statvfs(store)
assert 0 < space.f_blocks * space.f_frsize <= 64 * 1024 * 1024
assert not Path(os.environ["ORIGINAL_TEST_PATH"]).exists()
try:
    Path("/tmp/fixture-seed/saved-mail").write_bytes(b"forbidden mutation")
except OSError as error:
    assert error.errno == errno.EROFS
else:
    raise AssertionError("the host seed must remain read-only")
store.joinpath("saved-mail").write_bytes(b"private mutation")
assert Path("/tmp/fixture-seed/saved-mail").read_bytes() == b"saved synthetic mail"
print("LOW_SPACE_TMPFS_FIXTURE_PASS")
''')
            binary.chmod(0o700)
            tools = root / "tools"
            tools.mkdir()
            cargo = tools / "cargo"
            artifact = {"reason": "compiler-artifact", "executable": str(binary),
                        "profile": {"test": True}, "target": {"kind": ["lib"]}}
            cargo.write_text("#!" + str(Path(sys.executable).resolve()) + "\nprint(" + repr(json.dumps(artifact)) + ")\n")
            cargo.chmod(0o700)
            env = {"PATH": str(tools) + os.pathsep + "/usr/bin:/bin",
                   "ORIGINAL_TEST_PATH": str(binary)}
            result = subprocess.run([sys.executable, str(harness)], env=env,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("LOW_SPACE_TMPFS_FIXTURE_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()

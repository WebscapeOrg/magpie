#!/usr/bin/env python3
"""Invariant: standalone targets use the portable backend and explicit development paths."""
from pathlib import Path
import os
import shlex
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def make(*args):
    environment = {key: value for key, value in os.environ.items()
                   if key not in {"MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES",
                                  "APP_BACKEND", "APP_TARGET_DIR", "APP_BUILD_DIR"}}
    return subprocess.run(
        ["make", *args], cwd=ROOT, env=environment, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, check=True).stdout


help_text = make("help")
assert "make app-build" in help_text
assert "make app-run" in help_text

build = make("-n", "app-build")
assert "cargo build --locked --no-default-features --features standalone" in build
assert '-DOMAMAIL_BACKEND="' in build
assert "/target/standalone/debug/omamail" in build
assert "cmake --build" in build

run = make("-n", "app-run")
launches = [
    line for line in run.splitlines()
    if "OMAMAIL_DEVELOPMENT_RESOURCES=1" in line
]
assert len(launches) == 1, run
launch = launches[0]
assert "OMAMAIL_DEVELOPMENT_RESOURCES=1" in launch
assert 'OMAMAIL_BIN="' in launch and "/target/standalone/debug/omamail" in launch
assert '"app/build/omamail-app"' in launch
assert "backend-runtime.py" not in run
assert "install" not in run
assert "PATH=" not in launch

for build_dir in ("/tmp/magpie-app-build", "app/custom build"):
    custom_run = make("-n", "app-run", "APP_BUILD_DIR=" + build_dir)
    custom_launch = next(line for line in custom_run.splitlines()
                        if "OMAMAIL_DEVELOPMENT_RESOURCES=1" in line)
    executable = (ROOT / build_dir / "omamail-app").resolve()
    assert (ROOT / shlex.split(custom_launch)[-1]).resolve() == executable, custom_launch

cmake = (ROOT / "app/CMakeLists.txt").read_text()
assert 'ui/assets/*' in cmake

makefile = (ROOT / "Makefile").read_text()
assert "validate: test test-app-qml qml-check" in makefile
assert 'test-app-qml:\n\t@test -n "$(QMLTESTRUNNER)"' in makefile

# Invariant: CMake may not independently find Qt's runner outside PATH. Forward the
# already resolved executable and fail instead of silently testing nothing.
qml = make("-n", "test-app-qml", "QMLTESTRUNNER=/synthetic/qt/bin/qmltestrunner")
assert '-DQMLTESTRUNNER_EXECUTABLE="/synthetic/qt/bin/qmltestrunner"' in qml
assert '--no-tests=error' in qml

print("test_app_make.py ok")

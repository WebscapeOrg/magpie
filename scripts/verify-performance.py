#!/usr/bin/env python3
"""Run isolated verification gates and retain every result, including blocked gates."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "aeac13160f70a86f6419eaf2ceb1695fad078c7c"


def qt_tool(name):
    return shutil.which(name + "6") or (
        str(Path("/usr/lib/qt6/bin") / name) if (Path("/usr/lib/qt6/bin") / name).is_file()
        else shutil.which(name))


def private_ancestors(path):
    for ancestor in (path, *path.parents):
        info = ancestor.stat()
        if info.st_uid not in (0, os.geteuid()):
            raise RuntimeError(f"{ancestor} has a foreign owner ({info.st_uid})")
        if info.st_mode & 0o022 and not (info.st_uid == 0 and info.st_mode & stat.S_ISVTX):
            raise RuntimeError(f"{ancestor} permits unsafe writes")


def thumbnail_sandbox():
    for program in ("bwrap", "pdftoppm", "prlimit"):
        if not Path("/usr/bin", program).is_file():
            raise RuntimeError(f"PDF sandbox dependency is missing: /usr/bin/{program}")
    result = subprocess.run([
        "/usr/bin/bwrap", "--unshare-all", "--die-with-parent", "--new-session",
        "--cap-drop", "ALL", "--clearenv", "--ro-bind", "/usr", "/usr",
        "--ro-bind", "/lib", "/lib", "--ro-bind-try", "/lib64", "/lib64",
        "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--chdir", "/tmp",
        "/usr/bin/true"], capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError("PDF sandbox cannot start: " + result.stderr.strip()[:500])


def low_space_sandbox():
    result = subprocess.run([
        "/usr/bin/bwrap", "--unshare-all", "--die-with-parent", "--new-session",
        "--cap-drop", "ALL", "--ro-bind", "/", "/", "--proc", "/proc",
        "--dev", "/dev", "--size", str(64 * 1024 * 1024), "--tmpfs", "/tmp",
        "--chdir", "/tmp", "/usr/bin/true"], capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError("Low-space sandbox cannot start: " + result.stderr.strip()[:500])


def capabilities(directory):
    result = {}

    def check(name, operation):
        try:
            operation()
            result[name] = {"status": "pass"}
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            result[name] = {"status": "blocked", "reason": str(error)}

    def listener(family):
        with socket.socket(family, socket.SOCK_STREAM) as server:
            server.bind(("127.0.0.1", 0) if family == socket.AF_INET else str(directory / "probe.sock"))
            server.listen(1)

    check("tcp", lambda: listener(socket.AF_INET))
    check("unix", lambda: listener(socket.AF_UNIX))
    check("ownership", lambda: private_ancestors(directory))
    check("dbus", lambda: subprocess.run(["dbus-run-session", "--", "true"], check=True,
                                        capture_output=True, timeout=10))
    check("pdf-sandbox", thumbnail_sandbox)
    check("low-space-sandbox", low_space_sandbox)
    for name in ("cargo", "node", "make", "cmake", "omarchy", "qs"):
        result[name] = {"status": "pass"} if shutil.which(name) else {
            "status": "blocked", "reason": name + " is not installed"}
    for name in ("qmltestrunner", "qmllint"):
        result[name] = {"status": "pass"} if qt_tool(name) else {
            "status": "blocked", "reason": name + " is not installed"}
    return result


def test_environment(directory):
    keep = ("PATH", "LANG", "LC_ALL", "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN",
            "CARGO_NET_OFFLINE", "PKG_CONFIG_PATH", "LD_LIBRARY_PATH", "CMAKE_PREFIX_PATH",
            "QT_PLUGIN_PATH", "QML2_IMPORT_PATH", "QML_IMPORT_PATH", "SSL_CERT_FILE",
            "SSL_CERT_DIR", "CARGO_BUILD_JOBS")
    env = {key: os.environ[key] for key in keep if key in os.environ}
    env.setdefault("CARGO_HOME", str(Path.home() / ".cargo"))
    env.setdefault("RUSTUP_HOME", str(Path.home() / ".rustup"))
    for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
                "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
        path = directory / key.lower()
        path.mkdir(mode=0o700)
        env[key] = str(path)
    env.update(QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
               QT_QPA_PLATFORMTHEME="", GSETTINGS_BACKEND="memory", QT_SCALE_FACTOR="1",
               CARGO_TARGET_DIR=str(ROOT / "target"))
    return env


def stages(profile, output, baseline):
    qml = qt_tool("qmltestrunner") or "qmltestrunner"
    lint = qt_tool("qmllint") or "qmllint"
    make = ["make", "QMLTESTRUNNER=" + qml, "QMLLINT=" + lint,
            "APP_BACKEND=" + str(ROOT / "target/debug/omamail")]
    isolated = ["dbus-run-session", "--"]
    runtime = ["tcp", "unix", "ownership", "dbus"]
    gate = lambda name, command, needs=(): (name, command, list(needs))
    if profile == "benchmarks":
        return [
            gate("build-benchmarks", ["cargo", "test", "--release", "--locked", "--lib", "--no-run"], ["cargo"]),
            gate("list-before-after", [sys.executable, "benchmarks/mail/compare_ui.py",
                                      "--baseline", baseline, "--runner", qml,
                                      "--output", str(output / "before-after.json")], ["qmltestrunner"]),
            *[gate(name, ["cargo", "test", "--release", "--locked", "--lib",
                          "local_mail::tests::benchmark_local_queries", "--", "--ignored", "--nocapture"],
                   ["cargo"]) for name in ("database-idle", "database-background", "database-million")],
        ]
    gates = [
        gate("build", ["cargo", "build", "--locked", "--bin", "omamail"], ["cargo"]),
        gate("offline-recovery", ["cargo", "test", "--locked", "--lib", "local_mail::recovery_tests"], ["cargo"]),
        gate("provider-recovery", ["cargo", "test", "--locked", "--lib", "local_mail::provider_tests"], ["cargo"] + runtime),
        gate("send-recovery", ["cargo", "test", "--locked", "--lib", "outbox::tests::recorder_confirms"], ["cargo"] + runtime),
        gate("retained-attachments", isolated + [sys.executable, "tests/test_attachment_handles_rpc.py"], runtime),
        gate("low-space", [sys.executable, "scripts/test-low-space.py"], ["cargo", "low-space-sandbox"] + runtime),
        gate("subprocess", ["cargo", "test", "--locked", "--lib", "process::"], ["cargo"]),
        gate("rust", isolated + make + ["test-rust"], ["cargo", "pdf-sandbox"] + runtime),
        gate("javascript", make + ["test-js"], ["node"]),
        gate("source", ["bash", "tests/test_source.sh"]),
        gate("shell-independent", make + ["test-shell-independent"], ["node"]),
        gate("shell", isolated + make + ["test-shell-portable"], ["node"] + runtime),
        gate("qml", isolated + make + ["test-qml"], ["cargo", "qmltestrunner"] + runtime),
        gate("qml-components", [sys.executable, "tests/run_qml_components.py", "--runner", qml,
                                "--output", str(output / "qml-components")], ["qmltestrunner"]),
        gate("standalone-qml", make + ["test-app-qml"], ["cmake", "qmltestrunner"]),
        gate("native-host", ["ctest", "--test-dir", "app/build",
                            "--output-on-failure", "--no-tests=error"], ["cmake"]),
        gate("qml-lint", make + ["qml-check"], ["qmllint"]),
        gate("api-inventory", [sys.executable, "scripts/package-backend.py", "check-api"]),
        gate("api-contract", isolated + [sys.executable, "tests/test_backend_api.py",
                                         "--binary", "target/debug/omamail"], runtime),
        gate("native-agent", isolated + [sys.executable, "tests/test_agent_native_bridge.py"], runtime),
        gate("diff", ["git", "diff", "--check"]),
    ]
    if profile == "desktop":
        gates.extend([
            gate("validate", isolated + make + ["validate"], ["cargo", "cmake", "qmltestrunner",
                                                              "qmllint", "omarchy", "pdf-sandbox"] + runtime),
            gate("quickshell-bridge", isolated + make + ["test-backend-process"], ["qs", "cargo"] + runtime),
        ])
    return gates


def prerequisites(name):
    if name in ("qml", "api-contract", "native-agent", "standalone-qml"):
        return ["build"]
    if name == "native-host":
        return ["standalone-qml"]
    if name.startswith("database-"):
        return ["build-benchmarks"]
    return []


def execute(command, environment, log, timeout):
    started = time.monotonic()
    with log.open("w") as stream:
        try:
            process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as error:
            stream.write(str(error) + "\n")
            return {"status": "blocked", "reason": str(error)}
        try:
            while True:
                try:
                    code = process.wait(timeout=min(30, max(.1, timeout - (time.monotonic() - started))))
                    return {"status": "pass" if code == 0 else "fail", "exitCode": code,
                            "seconds": round(time.monotonic() - started, 3)}
                except subprocess.TimeoutExpired:
                    if time.monotonic() - started >= timeout:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                        return {"status": "fail", "reason": "deadline exceeded", "seconds": timeout}
                    print("  still running:", log.stem, flush=True)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


def save(output, report):
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = ["# Magpie verification", "", f"Profile: `{report['profile']}`. Result: **{report['status']}**.",
             "", "| Gate | Result | Detail |", "| --- | --- | --- |"]
    for gate in report["gates"]:
        detail = gate.get("reason", gate.get("log", ""))
        lines.append(f"| {gate['name']} | {gate['status']} | {detail.replace('|', '/')} |")
    lines += ["", "These are synthetic, isolated checks. Hosted/offscreen results do not certify physical "
              "compositor latency, real mailbox compatibility, or assistive-technology usability.",
              "Published-binary compatibility is provided separately by the existing CI Released backend gate.",
              "HTTP/2, gzip and compiler-profile changes are not enabled by this work."]
    (output / "summary.md").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=["ci", "desktop", "benchmarks"], default="ci")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("timeout must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    source_files = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=ROOT)
    digest = hashlib.sha256()
    for name in sorted(set(source_files.decode().split("\0")) - {""}):
        path = ROOT / name
        if path.is_file() and not path.is_symlink():
            digest.update(name.encode() + b"\0" + path.read_bytes())
    report = dict(profile=args.profile, startedAt=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  platform=platform.platform(), sourceSha256=digest.hexdigest(),
                  commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                  status="running", gates=[])
    with tempfile.TemporaryDirectory(prefix="magpie-verification-") as temporary:
        directory = Path(temporary)
        environment = test_environment(directory)
        available = capabilities(directory)
        report["capabilities"] = available
        for name, command, needs in stages(args.profile, output, args.baseline):
            missing = [need for need in needs if available[need]["status"] != "pass"]
            prior = {gate["name"]: gate["status"] for gate in report["gates"]}
            failed_dependencies = [item for item in prerequisites(name) if prior.get(item) != "pass"]
            result = dict(name=name, command=command)
            if missing:
                result.update(status="blocked", reason="; ".join(need + ": " + available[need]["reason"]
                                                               for need in missing))
            elif args.preflight_only:
                result.update(status="not-run", reason="preflight only")
            elif failed_dependencies:
                result.update(status="blocked", reason="prerequisite did not pass: " + ", ".join(failed_dependencies))
            else:
                print("Running", name, flush=True)
                env = dict(environment, MAGPIE_BENCH_MESSAGES="1000000" if name == "database-million" else "100000",
                           MAGPIE_BENCH_BACKGROUND="1" if name == "database-background" else "0")
                result.update(execute(command, env, output / (name + ".log"), args.timeout),
                              log=name + ".log")
            report["gates"].append(result)
            print(name + ": " + result["status"], flush=True)
            save(output, report)
    statuses = {gate["status"] for gate in report["gates"]}
    report["status"] = "fail" if "fail" in statuses else "blocked" if "blocked" in statuses else (
        "not-run" if "not-run" in statuses else "pass")
    save(output, report)
    print("Results:", output / "summary.md")
    return 0 if report["status"] == "pass" else 2 if report["status"] in ("blocked", "not-run") else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Measure a synthetic native window through physical or virtual display capture."""
import argparse
import base64
from contextlib import ExitStack
import hashlib
import io
import json
import math
import os
from pathlib import Path
import platform
import queue
import shutil
import sqlite3
import subprocess
import threading
import time

from PIL import Image, ImageGrab

ROOT = Path(__file__).resolve().parents[2]
ACCOUNT = "desktop-fixture@example.test"


def private(path, content):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(content if isinstance(content, bytes) else content.encode())
    path.chmod(0o600)


def source_hash():
    paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT).decode().split("\0")
    digest = hashlib.sha256()
    for name in sorted(set(paths)):
        if not name or name.startswith("docs/"): continue
        path = ROOT / name
        if path.is_file(): digest.update(name.encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def seed(folder, binary, count, html_bytes):
    env = dict(os.environ)
    for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"):
        path = folder / key.lower()
        path.mkdir(mode=0o700)
        env[key] = str(path)
    registry = {"version": 1, "accounts": [{"provider": "gmail", "email": ACCOUNT}], "activeId": ACCOUNT}
    private(Path(env["XDG_CONFIG_HOME"]) / "omamail/accounts.json", json.dumps(registry))
    for name in ("colors.toml", "shell.toml"):
        source = Path.home() / ".local/state/omarchy/current/theme" / name
        if source.exists():
            private(Path(env["HOME"]) / ".local/state/omarchy/current/theme" / name, source.read_bytes())
    request = {"jsonrpc": "2.0", "id": 1, "method": "local.status", "params": {"accountId": ACCOUNT}}
    initialized = subprocess.run([str(binary), "serve"], input=json.dumps(request) + "\n",
                                 text=True, capture_output=True, env=env, timeout=30, check=True)
    replies = [json.loads(line) for line in initialized.stdout.splitlines()]
    if not any(reply.get("id") == 1 and "result" in reply for reply in replies):
        raise RuntimeError(initialized.stdout + initialized.stderr)
    directory = Path(env["XDG_STATE_HOME"]) / "omamail/mail" / hashlib.sha256(ACCOUNT.encode()).hexdigest()
    db = sqlite3.connect(directory / "mail.sqlite")
    for n in range(count):
        identity = f"synthetic-{n:08}"
        body = ("needle" if n % 100 == 0 else "ordinary") + f" synthetic saved message {n}"
        large = n >= count - 3 and html_bytes > 0
        if large:
            line = "<p>Large synthetic message with readable text and no external resources.</p>"
            body = "<html><body>" + line * math.ceil(html_bytes / len(line)) + "</body></html>"
        resource = {"id": identity, "threadId": identity, "internalDate": str(1_700_000_000_000 + n),
                    "labelIds": ["INBOX"], "snippet": body[:140],
                    "payload": {"mimeType": "text/html" if large else "text/plain", "headers": [
                        {"name": "From", "value": "Synthetic sender <sender@example.test>"},
                        {"name": "To", "value": ACCOUNT},
                        {"name": "Subject", "value": f"Synthetic message {n}"}],
                        "body": {"data": base64.urlsafe_b64encode(body.encode()).decode().rstrip("="), "size": len(body)}}}
        raw = json.dumps(resource, separators=(",", ":")).encode()
        digest = hashlib.sha256(raw).hexdigest()
        private(directory / "blobs" / digest[:2] / digest, raw)
        summary = {"id": identity, "threadId": identity, "subject": f"Synthetic message {n}",
                   "snippet": body[:140], "from": {"display": "Synthetic sender", "email": "sender@example.test"},
                   "unread": False, "date": "2026-10-21T09:00:00Z", "labelIds": ["INBOX"]}
        db.execute("INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                   (identity, identity, 1_700_000_000_000 + n, json.dumps(summary), digest, '["INBOX"]',
                    "sender@example.test", ACCOUNT, "", summary["subject"], "", 0, 1, 1))
        db.execute("INSERT INTO labels VALUES(?, 'INBOX')", (identity,))
        db.execute("INSERT INTO search(id,subject,sender,recipients,copied,filenames,body) VALUES(?,?,?,?,?,?,?)",
                   (identity, summary["subject"], "sender@example.test", ACCOUNT, "", "", body))
    state = {"paused": "true", "legacyImported": "true", "history": "100", "generation": "1",
             "inventoryListed": "true", "inventoryComplete": "true", "estimate": str(count),
             "profile": json.dumps({"email": ACCOUNT, "messagesTotal": count}),
             "labels": json.dumps([{"id": "INBOX", "name": "INBOX"}])}
    db.executemany("INSERT OR REPLACE INTO state VALUES(?,?)", state.items())
    db.commit()
    db.close()
    return env


def hypr(env, *arguments):
    if arguments[0] == "dispatch":
        arguments = ("dispatch", ", ".join(json.dumps(value) for value in arguments[1:]))
    result = subprocess.run(["hyprctl", *arguments], env=env, text=True, capture_output=True, timeout=10)
    if result.returncode:
        raise RuntimeError(f"hyprctl {arguments}: {result.stdout} {result.stderr}")
    return result.stdout


def window_for(env, pid):
    for window in json.loads(hypr(env, "clients", "-j")):
        if window["pid"] == pid and window["title"] == "Magpie synthetic acceptance":
            return window
    return None


def accessible_nodes(pid):
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi, GLib
    Atspi.set_timeout(2000, 2000)
    desktop = Atspi.get_desktop(0)
    rows = []
    def walk(node, depth=0):
        if node is None: return
        if depth > 30: raise RuntimeError("Accessibility tree exceeded depth bound")
        if not node.get_state_set().contains(Atspi.StateType.SHOWING): return
        rows.append(node)
        for i in range(node.get_child_count()): walk(node.get_child_at_index(i), depth+1)
    deadline = time.monotonic() + 5
    while not rows and time.monotonic() < deadline:
        while GLib.MainContext.default().pending(): GLib.MainContext.default().iteration(False)
        for i in range(desktop.get_child_count()):
            application = desktop.get_child_at_index(i)
            if application.get_process_id() == pid: walk(application)
        if not rows: time.sleep(.05)
    if not rows: raise RuntimeError("Synthetic application is absent from AT-SPI")
    return rows


def accessibility(pid, stage, output):
    visible = accessible_nodes(pid)
    def find(name):
        found = [node for node in visible if node.get_name() == name]
        if len(found) != 1: raise RuntimeError(f"Expected one visible accessible {name}, found {len(found)}")
        return found[0]
    def press(name):
        action = find(name).get_action_iface()
        for i in range(action.get_n_actions()):
            if action.get_action_name(i).lower() == "press":
                if not action.do_action(i): raise RuntimeError(f"AT-SPI refused {name}")
                return
        raise RuntimeError(f"No accessible press action for {name}")
    rows = []
    for node in visible:
        action = node.get_action_iface()
        rows.append({"name": node.get_name(), "role": node.get_role_name(),
                     "actions": [action.get_action_name(i) for i in range(action.get_n_actions())] if action else []})
    private(output / (stage + ".json"), json.dumps(rows, indent=2))
    if stage == "accessibility-inbox":
        find("Mail downloads paused. Saved mail is available.")
        press("Resume downloads")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            from gi.repository import GLib
            while GLib.MainContext.default().pending(): GLib.MainContext.default().iteration(False)
            if any(node.get_name() == "Pause downloads" for node in visible): break
            time.sleep(.05)
        press("Pause downloads")
    else:
        for name, value in (("To", "recipient@example.test"), ("Subject", "Synthetic accessible send"), ("Message body", "Synthetic body")):
            editable = find(name).get_editable_text_iface()
            if not editable or not editable.set_text_contents(value): raise RuntimeError(f"AT-SPI cannot edit {name}")
        find("Attach...")
        press("Send")
    (output / (stage + ".done")).touch()


def stop_process(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--binary", type=Path, default=ROOT / "target/debug/omamail")
    parser.add_argument("--driver", type=Path, default=ROOT / "app/build/desktop_acceptance")
    parser.add_argument("--messages", type=int, default=1000)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--accessibility", action="store_true")
    parser.add_argument("--scale", default="1")
    parser.add_argument("--html-bytes", type=int, default=256 * 1024)
    parser.add_argument("--display-mode", choices=("physical", "xvfb"), default="physical")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700)
    binary = args.binary.resolve()
    driver = args.driver.resolve()
    source_before = source_hash()
    backend_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    driver_hash = hashlib.sha256(driver.read_bytes()).hexdigest()
    if args.messages < 50 or args.samples < 3 or args.html_bytes < 0:
        parser.error("Use at least 50 messages, 3 samples and nonnegative HTML size")
    env = seed(output, binary, args.messages, args.html_bytes)
    env["GSETTINGS_BACKEND"] = "memory"
    with ExitStack() as cleanup:
        bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1"], env=env,
                               stdout=subprocess.PIPE, stderr=cleanup.enter_context((output / "dbus.log").open("w")), text=True)
        cleanup.callback(stop_process, bus)
        env["DBUS_SESSION_BUS_ADDRESS"] = bus.stdout.readline().strip()
        os.environ["DBUS_SESSION_BUS_ADDRESS"] = env["DBUS_SESSION_BUS_ADDRESS"]
        server = None
        if args.display_mode == "physical":
            instances = json.loads(subprocess.check_output(["hyprctl", "instances", "-j"], text=True))
            if len(instances) != 1:
                raise RuntimeError("Expected one available Hyprland session")
            env.update(HYPRLAND_INSTANCE_SIGNATURE=instances[0]["instance"], WAYLAND_DISPLAY=instances[0]["wl_socket"],
                       QT_QPA_PLATFORM="wayland")
        else:
            server = subprocess.Popen(["Xvfb", "-displayfd", "1", "-screen", "0", "1920x1600x24", "-nolisten", "tcp"],
                                      stdout=subprocess.PIPE, stderr=cleanup.enter_context((output / "xvfb.log").open("w")), text=True)
            cleanup.callback(stop_process, server)
            env.update(DISPLAY=":" + server.stdout.readline().strip(), QT_QPA_PLATFORM="xcb")
        env.update(QT_SCALE_FACTOR=args.scale, OMAMAIL_DEVELOPMENT_RESOURCES="1",
                   OMAMAIL_BIN=str(binary), MAGPIE_DESKTOP_OPTIONS=str(output / "options.json"),
                   QT_ACCESSIBILITY="1", QT_LINUX_ACCESSIBILITY_ALWAYS_ON="1")
        env.pop("QT_QUICK_BACKEND", None)
        private(output / "options.json", json.dumps({"output": str(output), "samples": args.samples,
                                                    "largeIds": [f"synthetic-{args.messages-1-i:08}" for i in range(3)] if args.html_bytes else [],
                                                    "accessibility": args.accessibility}))
        if args.accessibility:
            subprocess.run(["gdbus", "call", "--session", "--dest", "org.a11y.Bus", "--object-path", "/org/a11y/bus",
                            "--method", "org.freedesktop.DBus.Properties.Set", "org.a11y.Status", "IsEnabled", "<true>"],
                           check=True, capture_output=True, text=True, env=env)
        launched = time.time() * 1000
        process = subprocess.Popen([str(driver), "-input", str(ROOT / "benchmarks/mail/tst_desktop.qml")],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        cleanup.callback(stop_process, process)
        lines = queue.Queue()

        def read():
            for line in process.stdout:
                lines.put(line)
            lines.put(None)

        threading.Thread(target=read, daemon=True).start()
        results = []
        code = None
        failure = None
        deadline = time.monotonic() + 180
        try:
            with (output / "desktop.log").open("w") as log:
                while time.monotonic() < deadline:
                    line = lines.get(timeout=20)
                    if line is None:
                        break
                    log.write(line)
                    log.flush()
                    if "DESKTOP_CHECKPOINT accessibility-" in line and args.accessibility:
                        accessibility(process.pid, line.split("DESKTOP_CHECKPOINT ", 1)[1].strip(), output)
                    if "DESKTOP_CAPTURE " not in line:
                        continue
                    event = json.loads(line.split("DESKTOP_CAPTURE ", 1)[1])
                    window = window_for(env, process.pid) if args.display_mode == "physical" else {
                        "at": [0, 0], "size": [round(1024 * float(args.scale)), round(768 * float(args.scale))]}
                    if not window:
                        raise RuntimeError("Synthetic window is not mapped")
                    expected = event["serial"] % 2
                    until = time.monotonic() + 10
                    while time.monotonic() < until:
                        if args.display_mode == "physical": window = window_for(env, process.pid)
                        x, y = window["at"]
                        scale = float(args.scale)
                        region = f"{x + round(12 * scale)},{y + round(12 * scale)} 2x2"
                        if args.display_mode == "physical":
                            capture = subprocess.check_output(["grim", "-g", region, "-t", "ppm", "-"], env=env, timeout=5)
                            pixels = Image.open(io.BytesIO(capture)).convert("RGB")
                        else:
                            pixels = ImageGrab.grab(xdisplay=env["DISPLAY"]).crop((round(12*scale), round(12*scale), round(12*scale)+2, round(12*scale)+2)).convert("RGB")
                        red, green, blue = pixels.getpixel((0, 0))
                        if blue > 100 and ((expected and red > green + 80) or (not expected and green > red + 80)):
                            elapsed = time.time() * 1000 - (launched if event["kind"] == "coldInbox" else event["started"])
                            break
                    else:
                        private(output / "window.json", json.dumps(window, indent=2))
                        x, y = window["at"]
                        width, height = window["size"]
                        if args.display_mode == "physical":
                            subprocess.run(["grim", "-g", f"{x},{y} {width}x{height}", str(output / "failed-window.png")], env=env, check=True)
                        else:
                            ImageGrab.grab(xdisplay=env["DISPLAY"]).save(output / "failed-window.png")
                        raise RuntimeError(f"Compositor never presented marker {expected}; last pixel {pixels.getpixel((0, 0))}")
                    results.append(dict(event, presentedMs=round(elapsed, 3)))
                    if event["kind"] in ("coldInbox", "compose", "composeFocus", "largeHtml", "offlineEdit"):
                        x, y = window["at"]
                        width, height = window["size"]
                        if args.display_mode == "physical":
                            subprocess.run(["grim", "-g", f"{x},{y} {width}x{height}", str(output / (event["kind"] + ".png"))], env=env, check=True)
                        else:
                            ImageGrab.grab(xdisplay=env["DISPLAY"]).crop((0,0,width,height)).save(output / (event["kind"] + ".png"))
                    (output / ("capture-" + str(event["serial"]))).touch()
                else:
                    raise RuntimeError("Desktop acceptance timed out")
            code = process.wait(timeout=10)
        except Exception as error:
            failure = str(error)
            raise
        finally:
            groups = {}
            for result in results:
                groups.setdefault(result["kind"], []).append(result["presentedMs"])
            summary = {kind: {"samplesMs": values, "p95Ms": sorted(values)[math.ceil(.95 * len(values)) - 1]}
                       for kind, values in groups.items()}
            unchanged = (source_before == source_hash()
                         and backend_hash == hashlib.sha256(binary.read_bytes()).hexdigest()
                         and driver_hash == hashlib.sha256(driver.read_bytes()).hexdigest())
            if not unchanged:
                failure = "Source or binaries changed during measurement"
                code = 1
            report = {"source": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                      "sourceSha256": source_before, "driverSha256": driver_hash,
                      "backendSha256": backend_hash, "messages": args.messages,
                      "largeHtmlBytes": args.html_bytes,
                      "backendPath": str(binary), "driverPath": str(driver),
                      "cpu": next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "unknown"),
                      "qt": next((line for line in (output / "desktop.log").read_text().splitlines() if line.startswith("Config:")), "unknown"),
                      "viewport": [1024, 768], "osCaches": "warm", "input": "Qt key event delivered to the actual application window",
                      "themeSha256": {name: hashlib.sha256((Path(env["HOME"]) / ".local/state/omarchy/current/theme" / name).read_bytes()).hexdigest()
                                       for name in ("colors.toml", "shell.toml") if (Path(env["HOME"]) / ".local/state/omarchy/current/theme" / name).exists()},
                      "scale": args.scale, "platform": platform.platform(), "results": summary, "raw": results,
                      "status": "pass" if code == 0 and failure is None else "fail", "error": failure,
                      "statusScope": "Functional acceptance only; compare timings with targets separately.",
                      "displayMode": args.display_mode,
                      "boundary": "Input/RPC/model/layout to captured pixels. Includes capture overhead. Cold means new app/backend processes; OS caches are warm. Xvfb measures an isolated virtual display, not physical compositor presentation."}
            private(output / "results.json", json.dumps(report, indent=2))
    print(json.dumps(summary, indent=2))
    raise SystemExit(code)


if __name__ == "__main__":
    main()

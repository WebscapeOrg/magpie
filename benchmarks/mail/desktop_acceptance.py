#!/usr/bin/env python3
"""Invariant: display measurements use a synthetic mailbox in a private session."""
import argparse
import base64
from contextlib import ExitStack
from dataclasses import dataclass
import hashlib
import io
import json
import math
import os
from pathlib import Path
import platform
import queue
import sqlite3
import subprocess
import threading
import time

from PIL import Image, ImageGrab

ROOT = Path(__file__).resolve().parents[2]
ACCOUNT = "desktop-fixture@example.test"
STARTUP_TIMEOUT = 10


def write_private(path, content):
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
    write_private(Path(env["XDG_CONFIG_HOME"]) / "omamail/accounts.json", json.dumps(registry))
    for name in ("colors.toml", "shell.toml"):
        source = Path.home() / ".local/state/omarchy/current/theme" / name
        if source.exists():
            write_private(Path(env["HOME"]) / ".local/state/omarchy/current/theme" / name, source.read_bytes())
    request = {"jsonrpc": "2.0", "id": 1, "method": "local.status", "params": {"accountId": ACCOUNT}}
    initialized = subprocess.run([str(binary), "serve"], input=json.dumps(request) + "\n",
                                 text=True, capture_output=True, env=env, timeout=30, check=True)
    replies = [json.loads(line) for line in initialized.stdout.splitlines()]
    if not any(reply.get("id") == 1 and "result" in reply for reply in replies):
        raise RuntimeError(initialized.stdout + initialized.stderr)
    directory = Path(env["XDG_STATE_HOME"]) / "omamail/mail" / hashlib.sha256(ACCOUNT.encode()).hexdigest()
    database = sqlite3.connect(directory / "mail.sqlite")
    for message_index in range(count):
        identity = f"synthetic-{message_index:08}"
        body = ("needle" if message_index % 100 == 0 else "ordinary") + f" synthetic saved message {message_index}"
        large = message_index >= count - 3 and html_bytes > 0
        if large:
            line = "<p>Large synthetic message with readable text and no external resources.</p>"
            body = "<html><body>" + line * math.ceil(html_bytes / len(line)) + "</body></html>"
        resource = {"id": identity, "threadId": identity, "internalDate": str(1_700_000_000_000 + message_index),
                    "labelIds": ["INBOX"], "snippet": body[:140],
                    "payload": {"mimeType": "text/html" if large else "text/plain", "headers": [
                        {"name": "From", "value": "Synthetic sender <sender@example.test>"},
                        {"name": "To", "value": ACCOUNT},
                        {"name": "Subject", "value": f"Synthetic message {message_index}"}],
                        "body": {"data": base64.urlsafe_b64encode(body.encode()).decode().rstrip("="), "size": len(body)}}}
        raw = json.dumps(resource, separators=(",", ":")).encode()
        digest = hashlib.sha256(raw).hexdigest()
        write_private(directory / "blobs" / digest[:2] / digest, raw)
        summary = {"id": identity, "threadId": identity, "subject": f"Synthetic message {message_index}",
                   "snippet": body[:140], "from": {"display": "Synthetic sender", "email": "sender@example.test"},
                   "unread": False, "date": "2026-10-21T09:00:00Z", "labelIds": ["INBOX"]}
        database.execute("INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                   (identity, identity, 1_700_000_000_000 + message_index, json.dumps(summary), digest, '["INBOX"]',
                    "sender@example.test", ACCOUNT, "", summary["subject"], "", 0, 1, 1))
        database.execute("INSERT INTO labels VALUES(?, 'INBOX')", (identity,))
        database.execute("INSERT INTO search(id,subject,sender,recipients,copied,filenames,body) VALUES(?,?,?,?,?,?,?)",
                   (identity, summary["subject"], "sender@example.test", ACCOUNT, "", "", body))
    state = {"paused": "true", "legacyImported": "true", "history": "100", "generation": "1",
             "inventoryListed": "true", "inventoryComplete": "true", "estimate": str(count),
             "profile": json.dumps({"email": ACCOUNT, "messagesTotal": count}),
             "labels": json.dumps([{"id": "INBOX", "name": "INBOX"}])}
    database.executemany("INSERT OR REPLACE INTO state VALUES(?,?)", state.items())
    database.commit()
    database.close()
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
    write_private(output / (stage + ".json"), json.dumps(rows, indent=2))
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


def readiness(process, name):
    reply = queue.Queue(maxsize=1)
    def read():
        try:
            reply.put(process.stdout.readline(4097))
        except Exception as error:
            reply.put(error)
    threading.Thread(target=read, daemon=True).start()
    try:
        line = reply.get(timeout=STARTUP_TIMEOUT)
    except queue.Empty:
        raise RuntimeError(f"{name} readiness timed out") from None
    if isinstance(line, Exception):
        raise RuntimeError(f"{name} readiness failed") from line
    if not line.endswith("\n") or len(line) > 4096 or not line.strip():
        raise RuntimeError(f"{name} did not provide a complete readiness line")
    return line.strip()


@dataclass
class PresentedFrame:
    result: dict
    window: dict


@dataclass
class DisplayCapture:
    env: dict
    pid: int
    mode: str
    scale: float

    def window(self):
        if self.mode == "physical":
            return window_for(self.env, self.pid)
        return {"at": [0, 0], "size": [round(1024 * self.scale), round(768 * self.scale)]}

    def marker(self, window):
        x, y = window["at"]
        offset = round(12 * self.scale)
        if self.mode == "physical":
            region = f"{x + offset},{y + offset} 2x2"
            capture = subprocess.check_output(["grim", "-g", region, "-t", "ppm", "-"],
                                              env=self.env, timeout=5)
            return Image.open(io.BytesIO(capture)).convert("RGB")
        return ImageGrab.grab(xdisplay=self.env["DISPLAY"]).crop(
            (offset, offset, offset + 2, offset + 2)).convert("RGB")

    def save(self, window, path, whole_display=False):
        x, y = window["at"]
        width, height = window["size"]
        if self.mode == "physical":
            subprocess.run(["grim", "-g", f"{x},{y} {width}x{height}", str(path)],
                           env=self.env, check=True)
            return
        pixels = ImageGrab.grab(xdisplay=self.env["DISPLAY"])
        if not whole_display:
            pixels = pixels.crop((0, 0, width, height))
        pixels.save(path)

    def capture(self, event, launched, output):
        window = self.window()
        if not window:
            raise RuntimeError("Synthetic window is not mapped")
        expected = event["serial"] % 2
        until = time.monotonic() + 10
        while time.monotonic() < until:
            if self.mode == "physical":
                window = self.window()
            pixels = self.marker(window)
            red, green, blue = pixels.getpixel((0, 0))
            if blue > 100 and ((expected and red > green + 80) or (not expected and green > red + 80)):
                elapsed = time.time() * 1000 - (launched if event["kind"] == "coldInbox" else event["started"])
                break
        else:
            write_private(output / "window.json", json.dumps(window, indent=2))
            self.save(window, output / "failed-window.png", whole_display=True)
            raise RuntimeError(f"Compositor never presented marker {expected}; last pixel {pixels.getpixel((0, 0))}")
        return PresentedFrame(dict(event, presentedMs=round(elapsed, 3)), window)

    def acknowledge(self, frame, output):
        event = frame.result
        if event["kind"] in ("coldInbox", "compose", "composeFocus", "largeHtml", "offlineEdit"):
            self.save(frame.window, output / (event["kind"] + ".png"))
        (output / ("capture-" + str(event["serial"]))).touch()


def validate_capture(event, expected_kind, serial):
    if event.get("kind") != expected_kind or type(event.get("serial")) is not int or event["serial"] != serial:
        raise RuntimeError("Missing, duplicated or reordered desktop capture")
    validate_duration(event.get("started"))


def validate_duration(value):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise RuntimeError("Invalid desktop measurement time")


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
        env["DBUS_SESSION_BUS_ADDRESS"] = readiness(bus, "DBus")
        os.environ["DBUS_SESSION_BUS_ADDRESS"] = env["DBUS_SESSION_BUS_ADDRESS"]
        if args.display_mode == "physical":
            instances = json.loads(subprocess.check_output(["hyprctl", "instances", "-j"], text=True, timeout=10))
            if len(instances) != 1:
                raise RuntimeError("Expected one available Hyprland session")
            env.update(HYPRLAND_INSTANCE_SIGNATURE=instances[0]["instance"], WAYLAND_DISPLAY=instances[0]["wl_socket"],
                       QT_QPA_PLATFORM="wayland")
        else:
            server = subprocess.Popen(["Xvfb", "-displayfd", "1", "-screen", "0", "1920x1600x24", "-nolisten", "tcp"],
                                      stdout=subprocess.PIPE, stderr=cleanup.enter_context((output / "xvfb.log").open("w")), text=True)
            cleanup.callback(stop_process, server)
            env.update(DISPLAY=":" + readiness(server, "Xvfb"), QT_QPA_PLATFORM="xcb")
        env.update(QT_SCALE_FACTOR=args.scale, OMAMAIL_DEVELOPMENT_RESOURCES="1",
                   OMAMAIL_BIN=str(binary), MAGPIE_DESKTOP_OPTIONS=str(output / "options.json"),
                   QT_ACCESSIBILITY="1", QT_LINUX_ACCESSIBILITY_ALWAYS_ON="1")
        env.pop("QT_QUICK_BACKEND", None)
        write_private(output / "options.json", json.dumps({"output": str(output), "samples": args.samples,
                                                    "largeIds": [f"synthetic-{args.messages-1-i:08}" for i in range(3)] if args.html_bytes else [],
                                                    "accessibility": args.accessibility}))
        if args.accessibility:
            subprocess.run(["gdbus", "call", "--session", "--dest", "org.a11y.Bus", "--object-path", "/org/a11y/bus",
                            "--method", "org.freedesktop.DBus.Properties.Set", "org.a11y.Status", "IsEnabled", "<true>"],
                           check=True, capture_output=True, text=True, env=env, timeout=10)
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
        display = DisplayCapture(env, process.pid, args.display_mode, float(args.scale))
        results = []
        expected = (["coldInbox"] + ["input"] * args.samples + ["navigation"] * args.samples
                    + ["search"] * args.samples + (["largeHtml"] * 3 if args.html_bytes else [])
                    + ["offlineEdit", "compose", "composeFocus"])
        checkpoints = []
        required_checkpoints = ["cached-inbox-visible-without-credentials"]
        if args.accessibility:
            required_checkpoints.append("accessibility-inbox")
        required_checkpoints.append("offline-star-and-archive-visible-and-undo-restores-mail")
        if args.accessibility:
            required_checkpoints.extend(["accessibility-compose", "accessible-send-durably-queued-without-credentials"])
        else:
            required_checkpoints.append("keyboard-send-durably-queued-without-credentials")
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
                    if "DESKTOP_CHECKPOINT " in line:
                        checkpoint = line.split("DESKTOP_CHECKPOINT ", 1)[1].strip()
                        if checkpoint.startswith("accessibility-") and args.accessibility:
                            accessibility(process.pid, checkpoint, output)
                        checkpoints.append(checkpoint)
                    if "DESKTOP_CAPTURE " not in line:
                        continue
                    event = json.loads(line.split("DESKTOP_CAPTURE ", 1)[1])
                    if len(results) >= len(expected):
                        raise RuntimeError("Unexpected extra desktop capture")
                    validate_capture(event, expected[len(results)], len(results) + 1)
                    frame = display.capture(event, launched, output)
                    validate_duration(frame.result.get("presentedMs"))
                    results.append(frame.result)
                    display.acknowledge(frame, output)
                else:
                    raise RuntimeError("Desktop acceptance timed out")
            code = process.wait(timeout=10)
            if len(results) != len(expected) or checkpoints != required_checkpoints:
                raise RuntimeError("Incomplete desktop measurements or functional checkpoints")
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
            write_private(output / "results.json", json.dumps(report, indent=2))
    print(json.dumps(summary, indent=2))
    raise SystemExit(code)


if __name__ == "__main__":
    main()

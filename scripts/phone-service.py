#!/usr/bin/env python3
"""Prepare and manage Enterprise's private Magpie service."""
import argparse
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "omamail"
PHONE = STATE / "phone"
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
DATA = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share") / "omamail"
HOST = "enterprise.tail615f0b.ts.net"
UNIT = "magpie-engine.service"


def safe(path, directory=False):
    if not path.is_absolute():
        raise RuntimeError("An absolute path is required")
    for part in [*reversed(path.parents), path]:
        if not part.exists() and not part.is_symlink():
            if part == path and not directory:
                continue
            part.mkdir(mode=0o700)
        info = part.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid not in (0, os.getuid()) or info.st_mode & 0o022:
            raise RuntimeError("Unsafe service path")
        if (part != path or directory) and not stat.S_ISDIR(info.st_mode):
            raise RuntimeError("Service directory is not a directory")
        if part == path and not directory and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
            raise RuntimeError("Service file is not a regular file")


def write(path, content, mode=0o600):
    safe(path.parent, True)
    safe(path)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".magpie-", delete=False) as file:
        temporary = Path(file.name)
        try:
            file.write(content)
            file.flush()
            os.fsync(file.fileno())
            temporary.chmod(mode)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def command(args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=210).stdout.strip()


def quote(value):
    if any(character in value for character in "\n\r\0"):
        raise RuntimeError("Invalid service value")
    return '"' + value.replace("%", "%%").replace("\\", "\\\\").replace('"', '\\"') + '"'


def runtime():
    spec = importlib.util.spec_from_file_location("magpie_runtime", ROOT / "scripts/backend-runtime.py")
    manager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(manager)
    result = manager.run("status")
    if result["state"] != "ready" or result["executable"] != str(DATA / "bin/omamail"):
        raise RuntimeError("Install the verified private backend first")
    info = json.loads(command([result["executable"], "info", "--json"]))
    if info.get("apiVersion", 0) < 8 or "phone.pairBegin" not in info.get("methods", []):
        raise RuntimeError("Installed backend does not support the phone service")
    return result["executable"]


def certificate():
    safe(PHONE, True)
    if PHONE.stat().st_mode & 0o077:
        raise RuntimeError("Phone storage must be private")
    for path in [PHONE / "server.crt", PHONE / "server.key"]:
        safe(path)
        if path.exists() and (path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077):
            raise RuntimeError("HTTPS credentials must be private")
    with tempfile.TemporaryDirectory(prefix=".certificate-", dir=PHONE) as stage:
        cert, key = Path(stage) / "server.crt", Path(stage) / "server.key"
        command(["tailscale", "cert", "--cert-file", str(cert), "--key-file", str(key), HOST])
        changed = not (PHONE / "server.crt").exists() or (PHONE / "server.crt").read_bytes() != cert.read_bytes()
        write(PHONE / "server.key", key.read_bytes())
        write(PHONE / "server.crt", cert.read_bytes())
    return changed


def unit(name, text):
    path = CONFIG / "systemd/user" / name
    safe(path)
    if path.exists() and not path.read_text().startswith("# Managed by Magpie\n"):
        raise RuntimeError("Refusing to replace an unrelated service")
    write(path, text.encode())


def service_environment():
    environment = "Environment=MAGPIE_WORKER_SERVICES=1\nEnvironment=" + quote("PATH=" + os.environ.get("PATH", "/usr/bin:/bin")) + "\n"
    for name in ["XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]:
        if name in os.environ:
            environment += "Environment=" + quote(name + "=" + os.environ[name]) + "\n"
    return environment


def prepare_certificate_units(environment):
    helper = DATA / "phone-service.py"
    write(helper, Path(__file__).read_bytes(), 0o700)
    unit("magpie-certificate.service", "# Managed by Magpie\n[Unit]\nDescription=Renew Magpie private HTTPS certificate\n\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 " + quote(str(helper)) + " certificate\n" + environment + "UMask=0077\n")
    unit("magpie-certificate.timer", "# Managed by Magpie\n[Unit]\nDescription=Maintain Magpie private HTTPS certificate\n\n[Timer]\nOnCalendar=weekly\nPersistent=true\nRandomizedDelaySec=1h\n\n[Install]\nWantedBy=timers.target\n")


def install_certificate():
    certificate()
    prepare_certificate_units(service_environment())
    command(["systemctl", "--user", "daemon-reload"])
    command(["systemctl", "--user", "enable", "--now", "magpie-certificate.timer"])


def prepare():
    binary = runtime()
    address = command(["tailscale", "ip", "-4"])
    if ipaddress.ip_address(address) not in ipaddress.ip_network("100.64.0.0/10"):
        raise RuntimeError("Enterprise's private network address is unavailable")
    certificate()
    write(PHONE / "server.json", json.dumps({"listen": address + ":3450", "host": HOST + ":3450"}).encode())
    environment = service_environment()
    unit(UNIT, "# Managed by Magpie\n[Unit]\nDescription=Magpie mail engine\nAfter=network-online.target\n\n[Service]\nType=simple\n"
         + "ExecStart=" + quote(binary) + " daemon\n" + environment
         + "UMask=0077\nNoNewPrivileges=true\nPrivateTmp=true\nKillMode=control-group\nRestart=on-failure\nRestartSec=5\nTimeoutStopSec=150\nTimeoutStartSec=30\n\n[Install]\nWantedBy=default.target\n")
    prepare_certificate_units(environment)
    records = {name: hashlib.sha256((CONFIG / "systemd/user" / name).read_bytes()).hexdigest()
               for name in [UNIT, "magpie-certificate.service", "magpie-certificate.timer"]}
    records["server.json"] = hashlib.sha256((PHONE / "server.json").read_bytes()).hexdigest()
    write(PHONE / "prepared.json", json.dumps(records).encode())
    command(["systemctl", "--user", "daemon-reload"])


def legacy_frontend(binary):
    if (STATE / "engine-enabled").exists():
        return False
    for process in Path("/proc").iterdir():
        if not process.name.isdigit():
            continue
        try:
            if process.stat().st_uid != os.getuid():
                continue
            executable = os.readlink(process / "exe").removesuffix(" (deleted)")
            args = (process / "cmdline").read_bytes().split(b"\0")
            if executable == binary and len(args) > 1 and args[1] == b"serve":
                return True
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    return False


def enable():
    binary = runtime()
    marker = STATE / "engine-enabled"
    safe(marker)
    safe(PHONE, True)
    if PHONE.stat().st_mode & 0o077:
        raise RuntimeError("Phone storage must be private")
    prepared = PHONE / "prepared.json"
    safe(prepared)
    records = json.loads(prepared.read_bytes())
    for name in [UNIT, "magpie-certificate.service", "magpie-certificate.timer", "server.json"]:
        path = PHONE / name if name == "server.json" else CONFIG / "systemd/user" / name
        safe(path)
        content = path.read_bytes()
        if records.get(name) != hashlib.sha256(content).hexdigest():
            raise RuntimeError("Prepare the current mail service before enabling it")
        if name.endswith((".service", ".timer")) and not content.startswith(b"# Managed by Magpie\n"):
            raise RuntimeError("Refusing an unrelated service")
    for path in [PHONE / "server.key", PHONE / "server.crt"]:
        safe(path)
        if path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077:
            raise RuntimeError("HTTPS credentials must be private")
    if legacy_frontend(binary):
        raise RuntimeError("Stop the existing Magpie frontend before enabling its shared mail service")
    write(marker, b"1\n")
    command(["systemctl", "--user", "enable", "--now", UNIT, "magpie-certificate.timer"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "enable", "certificate", "install-certificate"])
    args = parser.parse_args()
    if args.action == "prepare":
        prepare()
    elif args.action == "enable":
        enable()
    elif args.action == "install-certificate":
        install_certificate()
    elif certificate():
        for name in [UNIT, "magpie-ota.service"]:
            if (CONFIG / "systemd/user" / name).is_file():
                command(["systemctl", "--user", "try-restart", name])


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Keep the standalone application's visible identity consistent on every OS."""

from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "app"


def require(source: str, text: str, description: str) -> None:
    if text not in source:
        raise SystemExit(f"{description} is missing")


main = (APP / "src/main.cpp").read_text(encoding="utf-8")
require(main, 'setApplicationName(QStringLiteral("Omamail"))', "stable Qt data identity")
require(main, 'setApplicationDisplayName(QStringLiteral("Magpie Mail"))',
        "Qt application display name")
require(main, 'setWindowIcon(QIcon(QStringLiteral(', "Qt window icon")
require(main, ':/omamail/ui/assets/magpie-mail.png', "Qt Apple envelope icon resource")
# Invariant: The Apple envelope is the Linux and Windows window icon. A packaged
# macOS app takes the same artwork from CFBundleIconFile; a development run
# loads its generated ICNS resource.
require(main, '#ifdef Q_OS_MACOS\n    if (!QCoreApplication::applicationDirPath().endsWith(',
        "macOS bundle icon guard")
require(main, 'iconFromIcnsFile(QStringLiteral(\n            ":/omamail/app/resources/macos/omamail.icns"',
        "macOS development icon")
cmake = (APP / "CMakeLists.txt").read_text(encoding="utf-8")
require(cmake, 'resources/macos/omamail.icns"', "macOS icon resource")

# Invariant: Closing the window is not quitting: Qt must not end the process on its own
# when the last window is hidden, or Cmd+W behaves as Cmd+Q.
require(main, 'application.setQuitOnLastWindowClosed(false);', "host-owned process lifetime")

qml = (APP / "qml/Main.qml").read_text(encoding="utf-8")
require(qml, 'title: "Magpie Mail"', "window title")

with (APP / "resources/macos/Info.plist").open("rb") as stream:
    plist = plistlib.load(stream)
for key in ("CFBundleDisplayName", "CFBundleName"):
    if plist.get(key) != "Magpie Mail":
        raise SystemExit(f"macOS {key} is not Magpie Mail")
url_types = plist.get("CFBundleURLTypes", [])
if not any("mailto" in entry.get("CFBundleURLSchemes", []) for entry in url_types):
    raise SystemExit("macOS bundle does not accept incoming mailto URLs")
if plist.get("CFBundleIconFile") != "omamail.icns":
    raise SystemExit("macOS bundle icon is not omamail.icns")

generator = (APP / "resources/icons/generate-native-icons.sh").read_text(encoding="utf-8")
require(generator, 'source_art="$app/../ui/assets/magpie-mail.png"',
        "Apple envelope native icon source")
require(generator, 'magick "$source_art" -alpha on -resize 1024x1024 "PNG32:$work/master.png"',
        "native icon source rendering")
require(generator, '(b"ic10", 1024)', "portable ICNS container generation")

icns = (APP / "resources/macos/omamail.icns").read_bytes()
if icns[:4] != b"icns" or int.from_bytes(icns[4:8], "big") != len(icns):
    raise SystemExit("macOS Magpie Mail icon is not a complete ICNS file")
chunk_dimensions = {}
offset = 8
while offset < len(icns):
    size = int.from_bytes(icns[offset + 4:offset + 8], "big")
    if size < 8 or offset + size > len(icns):
        raise SystemExit("macOS Magpie Mail ICNS has a malformed image chunk")
    kind = icns[offset:offset + 4]
    payload = icns[offset + 8:offset + size]
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise SystemExit(f"macOS Magpie Mail ICNS chunk {kind!r} is not PNG")
    chunk_dimensions[kind] = (
        int.from_bytes(payload[16:20], "big"),
        int.from_bytes(payload[20:24], "big"),
        payload[25],
    )
    offset += size
expected_chunks = {
    b"ic04": 16, b"ic11": 32, b"ic05": 32, b"ic12": 64,
    b"ic07": 128, b"ic13": 256, b"ic08": 256, b"ic14": 512,
    b"ic09": 512, b"ic10": 1024,
}
if offset != len(icns) or chunk_dimensions.keys() != expected_chunks.keys():
    raise SystemExit("macOS Magpie Mail ICNS has the wrong chunk types")
for kind, dimension in expected_chunks.items():
    if chunk_dimensions[kind] != (dimension, dimension, 6):
        raise SystemExit(f"macOS Magpie Mail ICNS {kind!r} is not {dimension}px RGBA")

desktop = (APP / "resources/linux/omamail.desktop").read_text(encoding="utf-8")
require("\n" + desktop, "\nName=Magpie Mail\n", "Linux application name")
require("\n" + desktop, "\nIcon=omamail\n", "Linux application icon")
require("\n" + desktop, "\nExec=omamail %u\n", "Linux mailto launch argument")
require("\n" + desktop, "\nMimeType=x-scheme-handler/mailto;\n",
        "Linux mailto handler registration")

rc = (APP / "resources/windows/omamail.rc.in").read_text(encoding="utf-8")
require(rc, 'ICON "@CMAKE_CURRENT_SOURCE_DIR@/resources/windows/omamail.ico"',
        "Windows executable icon")
for field in ("CompanyName", "FileDescription", "ProductName"):
    require(rc, f'VALUE "{field}", "Magpie Mail\\0"', f"Windows {field}")
icon = (APP / "resources/windows/omamail.ico").read_bytes()
if len(icon) < 4 or icon[:4] != b"\x00\x00\x01\x00":
    raise SystemExit("Windows Magpie Mail icon is not an ICO file")

package = (APP / "scripts/package-release.sh").read_text(encoding="utf-8")
require(package, 'ui/assets/magpie-mail.png', "packaged Apple envelope artwork")
require(package, 'share/icons/hicolor/160x160/apps/omamail.png',
        "packaged hicolor envelope path")

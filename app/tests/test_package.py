#!/usr/bin/env python3
"""Layout tests for the native Unix release packager.

Qt deployment and executable smoke checks run on native release workers. These
tests supply synthetic executables and a platform plugin to exercise the exact
archive contract without pretending a foreign Qt binary is runnable.
"""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGER = ROOT / "app/scripts/package-release.sh"
VERSION = tomllib.loads((ROOT / "Cargo.toml").read_text(encoding="utf-8"))["package"]["version"]


class PackageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.host = self.root / "omamail-app"
        self.backend = self.root / "omamail"
        self.plugin = self.root / "platform.plugin"
        for executable in (self.host, self.backend):
            executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            executable.chmod(0o700)
        self.plugin.write_bytes(b"platform")
        self.qml = self.root / "qml"
        self.ui = self.root / "ui"
        self.qml.mkdir()
        self.ui.mkdir()
        (self.qml / "Main.qml").write_text("import QtQuick\nItem {}\n", encoding="utf-8")
        (self.ui / "Service.qml").write_text("import QtQuick\nItem {}\n", encoding="utf-8")
        (self.ui / "assets").mkdir()
        (self.ui / "assets/magpie-mail.png").write_bytes(
            (ROOT / "ui/assets/magpie-mail.png").read_bytes())
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps({"version": VERSION}), encoding="utf-8")
        self.dist = self.root / "dist"

    def tearDown(self):
        self.temp.cleanup()

    def package(self, target, **environment):
        env = dict(os.environ, OMAMAIL_PACKAGE_TEST_MODE="1", **environment)
        return subprocess.run(
            [
                str(PACKAGER), target,
                "--host", str(self.host),
                "--backend", str(self.backend),
                "--qml", str(self.qml),
                "--ui", str(self.ui),
                "--manifest", str(self.manifest),
                "--dist", str(self.dist),
                "--platform-plugin", str(self.plugin),
                "--test-layout",
            ],
            cwd=ROOT, env=env, text=True, capture_output=True,
        )

    def assert_archive(self, target, archive_name, top, required):
        result = self.package(target)
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.dist / archive_name
        self.assertEqual(Path(result.stdout.strip()), archive)
        self.assertTrue(archive.is_file())
        with tarfile.open(archive, "r:gz") as package:
            members = package.getmembers()
            names = [member.name.rstrip("/") for member in members]
            roots = {Path(name).parts[0] for name in names if name}
            self.assertEqual(roots, {top})
            self.assertEqual(len(names), len(set(names)))
            self.assertFalse(any(member.isdev() or member.isfifo() for member in members))
            self.assertFalse(any("JetBrainsMono" in name for name in names))
            for path in required:
                self.assertIn(f"{top}/{path}", names)
            resources = f"{top}/Contents/Resources" if target == "macos-aarch64" else top
            unicode_notice = package.extractfile(f"{resources}/licenses/Unicode-LICENSE.txt").read()
            self.assertEqual(unicode_notice, (ROOT / "data/unicode/LICENSE.txt").read_bytes())
            metadata_name = (f"{top}/Contents/Resources/release.json"
                             if target == "macos-aarch64" else f"{top}/release.json")
            metadata = json.load(package.extractfile(metadata_name))
            self.assertEqual(metadata, {
                "schemaVersion": 1,
                "name": "omamail",
                "version": VERSION,
                "target": target,
                "topLevel": top,
            })
            if target == "macos-aarch64":
                info = plistlib.load(package.extractfile(f"{top}/Contents/Info.plist"))
                self.assertEqual(info["CFBundleDisplayName"], "Magpie Mail")
                self.assertEqual(info["CFBundleName"], "Magpie Mail")
                self.assertEqual(info["CFBundleIdentifier"], "com.omamail.app")
                self.assertEqual(info["CFBundleIconFile"], "omamail.icns")
                self.assertEqual(info["CFBundleExecutable"], "omamail-app")
                self.assertEqual(info["CFBundleShortVersionString"], VERSION)
                self.assertEqual(info["CFBundleVersion"], VERSION)
                self.assertTrue(any(
                    "mailto" in entry.get("CFBundleURLSchemes", [])
                    for entry in info.get("CFBundleURLTypes", [])
                ), "the packaged macOS app must accept mailto URLs")
                packaged_icon = package.extractfile(
                    f"{top}/Contents/Resources/omamail.icns"
                ).read()
                self.assertEqual(
                    packaged_icon,
                    (ROOT / "app/resources/macos/omamail.icns").read_bytes(),
                )

    def test_macos_archive_layout(self):
        self.assert_archive(
            "macos-aarch64", "omamail-app-macos-aarch64.tar.gz", "Omamail.app",
            [
                "Contents/MacOS/omamail-app", "Contents/MacOS/omamail",
                "Contents/Resources/qml/Main.qml", "Contents/Resources/ui/Service.qml",
                "Contents/Resources/ui/assets/magpie-mail.png", "Contents/Resources/manifest.json",
                "Contents/Resources/licenses/NerdFonts-LICENSE",
                "Contents/Resources/licenses/NerdFonts-README.md",
                "Contents/Resources/licenses/NerdFonts-PROVENANCE.md",
                "Contents/Resources/licenses/Apache-2.0.txt",
                "Contents/Resources/licenses/Pomicons-OFL-1.1.txt",
                "Contents/Resources/licenses/GLYPH-SOURCES.md",
                "Contents/PlugIns/platforms/libqcocoa.dylib",
                "Contents/Resources/omamail.icns",
                "Contents/Resources/backend-api.json", "Contents/Resources/backend-version",
                "Contents/Resources/scripts/attachment.sh",
                "Contents/Resources/scripts/default-mail.sh",
                "Contents/Resources/scripts/register-mailto.sh",
                "Contents/Resources/scripts/mailto.sh",
                "Contents/Resources/scripts/diagnostics.py",
                "Contents/Resources/scripts/open-link-window.py",
                "Contents/Resources/scripts/link-window.html",
                "Contents/Resources/scripts/open-magpie-calendar.py",
                "Contents/Info.plist",
            ],
        )

    def test_linux_archive_layout(self):
        self.assert_archive(
            "linux-x86_64", "omamail-app-linux-x86_64.tar.gz", "omamail.app",
            [
                "bin/omamail-app", "bin/omamail", "bin/qt.conf", "qml/Main.qml", "ui/Service.qml",
                "ui/assets/magpie-mail.png", "manifest.json", "plugins/platforms/libqxcb.so",
                "licenses/NerdFonts-LICENSE", "licenses/NerdFonts-README.md",
                "licenses/NerdFonts-PROVENANCE.md", "licenses/Apache-2.0.txt",
                "licenses/Pomicons-OFL-1.1.txt", "licenses/GLYPH-SOURCES.md",
                "backend-api.json", "backend-version",
                "scripts/attachment.sh", "scripts/default-mail.sh",
                "scripts/register-mailto.sh", "scripts/mailto.sh", "scripts/diagnostics.py",
                "scripts/open-link-window.py", "scripts/link-window.html",
                "scripts/open-magpie-calendar.py",
                "share/applications/omamail.desktop",
                "share/icons/hicolor/160x160/apps/omamail.png",
            ],
        )

        archive = self.dist / "omamail-app-linux-x86_64.tar.gz"
        with tarfile.open(archive, "r:gz") as package:
            desktop = package.extractfile(
                "omamail.app/share/applications/omamail.desktop"
            ).read().decode("utf-8")
            self.assertIn("\nName=Magpie Mail\n", "\n" + desktop)
            self.assertIn("\nIcon=omamail\n", "\n" + desktop)
            self.assertIn("\nExec=omamail %u\n", "\n" + desktop)
            self.assertIn("\nMimeType=x-scheme-handler/mailto;\n", "\n" + desktop)
            icon = package.extractfile(
                "omamail.app/share/icons/hicolor/160x160/apps/omamail.png"
            ).read()
            self.assertEqual(icon, (ROOT / "ui/assets/magpie-mail.png").read_bytes())

    def test_packaged_diagnostics_opens_with_isolated_state(self):
        result = self.package("linux-x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        unpacked = self.root / "unpacked"
        with tarfile.open(self.dist / "omamail-app-linux-x86_64.tar.gz", "r:gz") as package:
            package.extractall(unpacked)
        product = unpacked / "omamail.app"
        self.assertTrue((product / "backend-version").is_file())
        fake_bin = self.root / "agent-bin"
        fake_bin.mkdir()
        log = self.root / "agent-call.json"
        agent = fake_bin / "omarchy-agent"
        agent.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['FAKE_LOG']).write_text(json.dumps(sys.argv))\n",
            encoding="utf-8",
        )
        agent.chmod(0o700)
        state = self.root / "state"
        env = dict(
            os.environ,
            HOME=str(self.root / "home"),
            XDG_STATE_HOME=str(state),
            XDG_CONFIG_HOME=str(self.root / "config"),
            XDG_CACHE_HOME=str(self.root / "cache"),
            PATH=str(fake_bin) + os.pathsep + os.environ["PATH"],
            FAKE_LOG=str(log),
        )
        opened = subprocess.run(
            [sys.executable, str(product / "scripts/diagnostics.py"), "open"],
            env=env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(opened.returncode, 0, opened.stderr)
        report = state / "omamail/diagnostics/report.txt"
        self.assertTrue(report.is_file())
        self.assertIn(f"pinned backend: {VERSION}", report.read_text(encoding="utf-8"))
        self.assertTrue(log.is_file())
        self.assertIn("Diagnose an Omamail error", log.read_text(encoding="utf-8"))

    def test_missing_payload_fails_without_archive(self):
        self.backend.unlink()
        result = self.package("linux-x86_64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("backend is missing", result.stderr)
        self.assertFalse((self.dist / "omamail-app-linux-x86_64.tar.gz").exists())

    def test_manifest_version_mismatch_fails(self):
        self.manifest.write_text(json.dumps({"version": "9.9.9"}), encoding="utf-8")
        result = self.package("macos-aarch64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match Cargo version", result.stderr)

    def test_test_layout_switch_is_not_a_production_bypass(self):
        env = dict(os.environ)
        env.pop("OMAMAIL_PACKAGE_TEST_MODE", None)
        result = subprocess.run(
            [str(PACKAGER), "linux-x86_64", "--test-layout"],
            cwd=ROOT, env=env, text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires OMAMAIL_PACKAGE_TEST_MODE=1", result.stderr)

    def test_macos_deployment_handles_split_qt_and_reseals_bundle(self):
        source = PACKAGER.read_text(encoding="utf-8")
        self.assertIn('QtSvg.framework/Versions/A/QtSvg', source)
        self.assertIn('-libpath="$svg_libraries"', source)
        # Invariant: Qt 6.8.3's macdeployqt rejects -no-codesign; the bundle is re-sealed below.
        self.assertNotIn('-no-codesign', source)
        self.assertNotIn('-codesign=', source)
        self.assertIn('codesign --force --deep --sign - "$app"', source)
        self.assertIn('codesign --verify --deep --strict "$app"', source)
        self.assertIn('smoke_platform=cocoa', source)


if __name__ == "__main__":
    unittest.main()

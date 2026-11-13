#!/usr/bin/env python3
"""Every component file must be reachable and consistently named.

A component that nothing instantiates is dead weight; a component named in the
Makefile that does not exist makes `make qml-check` fail with a path error
rather than a useful message.
"""
import pathlib
import json
import re
import sys

repo = pathlib.Path(__file__).resolve().parent.parent
root = repo / "ui"
failures = []

components = sorted(p.name for p in (root / "components").glob("*.qml"))

# Every directory holding QML, so "is this type instantiated anywhere" has the
# whole tree to answer from rather than the two directories that existed first.
qml_files = [p for p in sorted(root.rglob("*.qml")) if "tests" not in p.relative_to(root).parts]
sources = "\n".join(p.read_text(encoding="utf-8") for p in qml_files)

for name in components:
    stem = name[:-4]
    if not re.search(rf"\b{stem}\s*{{", sources):
        failures.append(f"components/{name} is never instantiated")

makefile = (repo / "Makefile").read_text(encoding="utf-8")
for name in components:
    if f"components/{name}" not in makefile:
        failures.append(f"components/{name} is missing from QML_FILES in the Makefile")

for listed in re.findall(r"components/(\w+\.qml)", makefile):
    if listed not in components:
        failures.append(f"Makefile lists components/{listed}, which does not exist")

# The shell loads only the envelope. Service.qml and App.qml remain at the UI
# root because the native app composes them as shared resources.
manifest = json.loads((repo / "manifest.json").read_text(encoding="utf-8"))
if manifest["entryPoints"] != {"barWidget": "ui/BarWidget.qml"}:
    failures.append("the shell manifest must expose only ui/BarWidget.qml")
if manifest.get("kinds") != ["bar-widget"]:
    failures.append("the shell manifest must be envelope-only")
if not (root / "BarWidget.qml").is_file():
    failures.append("BarWidget.qml is declared in the manifest but missing")

# Only the shared app components and the shell envelope belong at the UI root.
for stray in sorted(root.glob("*.qml")):
    if stray.name not in ("Service.qml", "BarWidget.qml", "App.qml"):
        failures.append(f"{stray.name} sits at the root; it belongs in a module directory")
for stray in sorted(repo.glob("*.qml")):
    failures.append(f"{stray.name} sits at repository root; Qt sources belong in ui/")

# Invariant: every production QML file must be included in the lint inputs.
for path in qml_files:
    listed = path.relative_to(repo).as_posix()
    if listed not in makefile:
        failures.append(f"{listed} is missing from QML_FILES in the Makefile")

if failures:
    for line in failures:
        print(f"test_qml_names.py: {line}", file=sys.stderr)
    sys.exit(1)

print("test_qml_names.py ok")

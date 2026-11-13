#!/usr/bin/env python3
"""Every local OmaStore asset and the visible product identity must stay valid."""
from pathlib import Path
import tomllib

ROOT = Path(__file__).resolve().parents[1]
metadata = tomllib.loads((ROOT / "omastore.toml").read_text(encoding="utf-8"))
assert metadata["name"] == "Magpie Mail"
assert "Gmail" in metadata["summary"]
for unsupported in ("Outlook", "HEY", "JMAP", "IMAP", "calendar app"):
    assert unsupported not in metadata["summary"]
for reference in [metadata["icon"], *metadata["screenshots"]]:
    path = ROOT / reference
    assert path.is_file() and not path.is_symlink(), f"missing OmaStore asset: {reference}"
assert metadata["icon"] == "ui/assets/magpie-mail.png"
assert "docs/images/full-calendar.webp" not in metadata["screenshots"]
print("test_omastore.py ok")

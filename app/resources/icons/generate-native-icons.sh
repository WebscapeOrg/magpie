#!/bin/sh
set -eu

app=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
source_art="$app/../ui/assets/magpie-mail.png"
mac_icon="$app/resources/macos/omamail.icns"
windows_icon="$app/resources/windows/omamail.ico"
work=$(mktemp -d "${TMPDIR:-/tmp}/magpie-native-icons-XXXXXX")
trap 'rm -rf -- "${work:?}"' EXIT HUP INT TERM

command -v magick >/dev/null 2>&1 || { printf 'ImageMagick is required\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'Python 3 is required\n' >&2; exit 1; }
[ -f "$source_art" ] || { printf 'Apple envelope artwork is missing\n' >&2; exit 1; }

magick "$source_art" -alpha on -resize 1024x1024 "PNG32:$work/master.png"
for size in 16 32 64 128 256 512 1024; do
  magick "$work/master.png" -resize "${size}x${size}" "PNG32:$work/icon-$size.png"
done
magick "$work/master.png" -define icon:auto-resize=256,128,64,48,32,16 "$windows_icon"

# ICNS stores ordinary PNG payloads behind typed, big-endian chunk headers.
# Keeping that small container writer here makes the same Apple artwork
# reproducible on Linux as well as macOS, without a platform-only iconutil.
python3 - "$work" "$mac_icon" <<'PY'
from pathlib import Path
import struct
import sys

work, destination = Path(sys.argv[1]), Path(sys.argv[2])
chunks = (
    (b"ic04", 16),
    (b"ic11", 32),
    (b"ic05", 32),
    (b"ic12", 64),
    (b"ic07", 128),
    (b"ic13", 256),
    (b"ic08", 256),
    (b"ic14", 512),
    (b"ic09", 512),
    (b"ic10", 1024),
)
body = bytearray()
for kind, size in chunks:
    payload = (work / f"icon-{size}.png").read_bytes()
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise SystemExit(f"{kind} is not a PNG")
    body.extend(kind + struct.pack(">I", len(payload) + 8) + payload)
destination.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY

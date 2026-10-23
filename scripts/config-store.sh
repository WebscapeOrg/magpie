#!/bin/sh
# Writes one line from stdin to $XDG_CONFIG_HOME/omamail/<name> with
# owner-only permissions.
#
# No file it writes is world-readable: a desktop client's secret is only
# "not treated as confidential" by Google, which is not the same as public, and
# the account list names every mailbox on this machine. Compose recovery also
# contains message text. Plugin settings would have been the obvious home for
# these files, but shell.json is world-readable.
#
# One line, read with `read` rather than `cat`: Quickshell's Process.write()
# never closes stdin, so anything waiting for EOF hangs forever.
set -eu

name=${1:-}
case "$name" in
  credentials.json|accounts.json|window.json|calendars.json|compose.json) ;;
  *)
    printf '%s\n' 'usage: config-store.sh credentials.json|accounts.json|window.json|calendars.json|compose.json' >&2
    exit 2
    ;;
esac

umask 077

config_home=${XDG_CONFIG_HOME:-$HOME/.config}
target_dir="$config_home/omamail"
target="$target_dir/$name"
[ ! -L "$target_dir" ] || {
  printf '%s\n' 'refusing a symbolic link for the private config directory' >&2
  exit 5
}

IFS= read -r payload
if [ -z "$payload" ]; then
  exit 3
fi

if [ "$name" = credentials.json ]; then
  printf '%s\n' "$payload" | python3 -c '
import json
import os
from pathlib import Path
import stat
import sys

def validate_provider(value):
    if not isinstance(value, dict):
        return
    provider = value.get("provider")
    if provider is not None and (
        not isinstance(provider, str) or provider.strip().lower() not in ("", "gmail")
    ):
        raise ValueError()

def validate_record(value):
    validate_provider(value)
    if isinstance(value, dict):
        for key in ("installed", "web"):
            validate_provider(value.get(key))

def validate(value):
    if not isinstance(value, dict):
        raise ValueError()
    validate_record(value)
    if isinstance(value.get("accounts"), list):
        for account in value["accounts"]:
            validate_record(account)

def invalid_constant(value):
    raise ValueError()

def read_clients(source):
    limit = 1024 * 1024
    data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError()
    validate(json.loads(data.decode("utf-8"), parse_constant=invalid_constant))

try:
    read_clients(sys.stdin.buffer)
    target = Path(sys.argv[1])
    if os.path.lexists(target):
        if not stat.S_ISREG(target.lstat().st_mode):
            raise ValueError()
        with target.open("rb") as source:
            read_clients(source)
except (OSError, ValueError, RecursionError):
    print("refusing to replace unsupported or unreadable Google client settings", file=sys.stderr)
    sys.exit(6)
' "$target"
fi

# A plugin reload can briefly leave the retiring service with only its setup
# row in memory. If that stale instance reaches this writer after a real list
# has already been stored, accepting the write would replace every mailbox
# with first-run state. A saved account always has a validated email address;
# a draft has an empty one. Keep this invariant at the final write boundary so
# it also protects an old service instance during an upgrade.
#
# A merely non-empty address is not the test. A row holding something that is
# not an address — a username typed into the address field — derives no account
# id, so it is setup state too, and treating it as a saved account is what let
# a working mailbox be overwritten by a row nothing could select or remove.
# This is a coarse stand-in for Accounts.js's EMAIL_PATTERN rather than a mirror
# of it: it only has to tell an address from setup state, and the QML guard has
# already refused anything looser by the time a payload reaches here.
saved_account='"email"[[:space:]]*:[[:space:]]*"[^"@]+@[^"@.]+(\.[^"@.]+)+"'

if [ "$name" = accounts.json ] && [ -s "$target" ] \
  && grep -Eq "$saved_account" "$target" \
  && ! printf '%s\n' "$payload" | grep -Eq "$saved_account"; then
  printf '%s\n' 'refusing to replace saved accounts with setup state' >&2
  exit 4
fi

mkdir -p "$target_dir"
chmod 700 "$target_dir" 2>/dev/null || true

tmp=$(mktemp "$target.tmp.XXXXXX")
trap 'rm -f "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
printf '%s\n' "$payload" > "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$target"
printf '%s\n' "$target"

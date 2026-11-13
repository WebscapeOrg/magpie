#!/bin/sh
# The desktop helper must preserve the exact mailto: URL for the native app.
# Its single-instance activation raises the window; it never toggles it closed.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/mailto.sh"
fail() { printf 'test_mailto.sh: %s\n' "$1" >&2; exit 1; }

[ -x "$script" ] || fail "scripts/mailto.sh must be executable"

printed=$(OMAMAIL_MAILTO_PRINT=1 sh "$script" 'mailto:jane@example.com?subject=Hi')
expected='magpie-mail mailto:jane@example.com?subject=Hi'
[ "$printed" = "$expected" ] || fail "expected:
$expected
got:
$printed"

quoted=$(OMAMAIL_MAILTO_PRINT=1 sh "$script" 'mailto:jane@example.com?subject=Say "hi"')
[ "$quoted" = 'magpie-mail mailto:jane@example.com?subject=Say "hi"' ] \
  || fail "the exact URL argument changed: $quoted"

blank=$(OMAMAIL_MAILTO_PRINT=1 sh "$script")
[ "$blank" = 'magpie-mail' ] || fail "no URL must still open the app, got: $blank"

if sh "$script" one two >/dev/null 2>&1; then
  fail "more than one URL must be refused"
fi

printf 'test_mailto.sh ok\n'

#!/bin/sh
# Hands a mailto: URL to the native Magpie Mail app.
# The app's single-instance boundary preserves the exact argument and raises
# the existing window rather than toggling it closed.
set -eu

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

if [ "$#" -gt 1 ]; then
  fail 'usage: mailto.sh [mailto:url]'
fi

if [ -n "${OMAMAIL_MAILTO_PRINT:-}" ]; then
  if [ "$#" -eq 0 ] || [ -z "${1:-}" ]; then
    printf '%s\n' 'magpie-mail'
  else
    printf '%s\n' "magpie-mail $1"
  fi
  exit 0
fi

command -v magpie-mail >/dev/null 2>&1 || fail 'Magpie Mail: magpie-mail is not on PATH'
if [ "$#" -eq 0 ] || [ -z "${1:-}" ]; then
  exec magpie-mail
fi
exec magpie-mail "$1"

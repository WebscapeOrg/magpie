#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ''|--no-restart) ;;
  -h|--help) echo 'Install Magpie through Enterprise as guarded copies; Quickshell is never restarted.'; exit 0 ;;
  *) echo 'Usage: link-plugin.sh [--no-restart]' >&2; exit 2 ;;
esac
installer="$HOME/code/enterprise/omarchy/install.sh"
if [ ! -x "$installer" ]; then
  echo 'Enterprise installer missing; see MAGPIE.md.' >&2
  exit 1
fi
exec "$installer"

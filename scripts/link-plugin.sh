#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ''|--no-restart) ;;
  -h|--help) echo 'Install Magpie through the main machine as guarded copies; Quickshell is never restarted.'; exit 0 ;;
  *) echo 'Usage: link-plugin.sh [--no-restart]' >&2; exit 2 ;;
esac
installer="$(command -v magpie-mail-install || true)"
# Only an absolute path counts, so a relative PATH entry cannot run an installer from the current folder.
case "$installer" in /*) ;; *) installer="" ;; esac
if [ ! -x "$installer" ]; then
  echo 'Magpie installer missing; see MAGPIE.md.' >&2
  exit 1
fi
exec "$installer"

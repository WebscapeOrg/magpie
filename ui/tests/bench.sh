#!/usr/bin/env bash
# Diagnostic Node and QML columns use the same synthetic fixtures.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

node ui/tests/bench_node.js

runtime=""
for candidate in qml6 qml /usr/lib/qt6/bin/qml; do
  if command -v "$candidate" >/dev/null 2>&1; then
    runtime=$candidate
    break
  fi
done

if [[ -z $runtime ]]; then
  printf '\nNo qml runtime on PATH, so only the V8 column ran.\n'
  printf 'It ships with qt6-declarative; install that and run this again.\n'
  exit 0
fi

printf '\n'
# Keep Qt diagnostics in this command's output instead of the desktop journal.
export QT_FORCE_STDERR_LOGGING=1
# The Node-only diagnostic remains useful when Qt is unavailable.
if ! "$runtime" ui/tests/bench_html.qml; then
  printf '\nThe QML column did not run: %s exited non-zero above.\n' "$runtime"
  printf 'On a machine where the shell itself runs, that is worth looking into.\n'
fi

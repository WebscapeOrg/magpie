#!/usr/bin/env bash
set -euo pipefail

if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ]]; then
  echo 'Document test provisioning is restricted to disposable GitHub-hosted runners.' >&2
  exit 1
fi

sandbox_probe() {
  /usr/bin/bwrap --unshare-all --die-with-parent --new-session --cap-drop ALL \
    --clearenv --ro-bind /usr /usr --ro-bind /lib /lib --ro-bind-try /lib64 /lib64 \
    --proc /proc --dev /dev --tmpfs /tmp --chdir /tmp /usr/bin/true
}

if sandbox_probe; then
  exit 0
fi

if [[ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]] &&
   [[ $(< /proc/sys/kernel/apparmor_restrict_unprivileged_userns) == 1 ]]; then
  sudo tee /etc/apparmor.d/magpie-ci-bwrap >/dev/null <<'PROFILE'
abi <abi/4.0>,
include <tunables/global>
profile magpie-ci-bwrap /usr/bin/bwrap flags=(default_allow) {
  userns,
}
PROFILE
  sudo apparmor_parser -r /etc/apparmor.d/magpie-ci-bwrap
fi

sandbox_probe

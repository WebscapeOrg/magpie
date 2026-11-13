#!/usr/bin/env bash
# The manifest is the contract with the shell. Every entry point it names has
# to exist, or the plugin loads halfway and fails at the moment the user
# clicks something.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() { printf 'test_link_plugin.sh: %s\n' "$1" >&2; exit 1; }

python3 -c "import json; json.load(open('manifest.json'))" || fail "manifest.json is not valid JSON"

kinds=$(python3 -c "import json; print(' '.join(json.load(open('manifest.json'))['kinds']))")
[ "$kinds" = bar-widget ] || fail "manifest must contain only the envelope bar widget"
[ "$(python3 -c "import json; print(json.load(open('manifest.json'))['entryPoints'].get('barWidget',''))")" = ui/BarWidget.qml ] \
  || fail "entryPoints.barWidget must be ui/BarWidget.qml"
[ -f ui/BarWidget.qml ] || fail "ui/BarWidget.qml is declared in the manifest but does not exist"
python3 - <<'PY' || fail "the envelope must not load a shell service or panel"
import json
manifest = json.load(open('manifest.json'))
assert 'service' not in manifest['entryPoints']
assert 'panel' not in manifest['entryPoints']
PY

[ -x scripts/link-plugin.sh ] || fail "scripts/link-plugin.sh must be executable"
# Every run gets a PATH of test folders only, so the real installer can never run here. The fake installer lives
# outside HOME, so only the PATH lookup can find it.
installer_root=$(mktemp -d)
mkdir -p "$installer_root/bin" "$installer_root/home" "$installer_root/none" "$installer_root/plain" "$installer_root/here"
printf '#!/bin/sh\nprintf delegated > "$HOME/delegated"\n' > "$installer_root/bin/magpie-mail-install"
chmod +x "$installer_root/bin/magpie-mail-install"
cp "$installer_root/bin/magpie-mail-install" "$installer_root/here/magpie-mail-install"
cp "$installer_root/bin/magpie-mail-install" "$installer_root/plain/magpie-mail-install"
chmod -x "$installer_root/plain/magpie-mail-install"
link_plugin="$PWD/scripts/link-plugin.sh"
HOME="$installer_root/home" PATH="$installer_root/bin" "$BASH" "$link_plugin" --no-restart
[ -f "$installer_root/home/delegated" ] || fail "Magpie must delegate to the main machine's guarded copy installer"
rm -f "$installer_root/home/delegated"
# No installer, one that cannot run, and one reached only through a relative PATH entry all stop with the message.
# Each case is "the folder it runs from, under the test root:PATH".
for case in "here:$installer_root/none" "here:$installer_root/plain" "here:." "here:$installer_root/none:" ".:here" "none:../here"; do
  from="$installer_root/${case%%:*}" search=${case#*:}
  if out=$(cd "$from" && HOME="$installer_root/home" PATH="$search" "$BASH" "$link_plugin" --no-restart 2>&1); then
    fail "link-plugin.sh succeeded with PATH=$search from ${case%%:*}"
  fi
  [ "$out" = 'Magpie installer missing; see MAGPIE.md.' ] || fail "link-plugin.sh with PATH=$search printed: $out"
  [ ! -e "$installer_root/home/delegated" ] || fail "link-plugin.sh ran an installer it found through PATH=$search"
done
rm -rf "$installer_root"

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
# A stale service instance from before a plugin reload must not be able to
# replace a real account list with the first-run setup row. The writer is the
# one boundary both old and new service code still cross.
saved_accounts='{"version":1,"accounts":[{"id":"imap:me@example.com","email":"me@example.com"}],"activeId":"imap:me@example.com"}'
setup_accounts='{"version":1,"accounts":[{"id":"","email":""}],"activeId":""}'
printf '%s\n' "$saved_accounts" \
  | XDG_CONFIG_HOME="$test_root/config" sh scripts/config-store.sh accounts.json >/dev/null
if printf '%s\n' "$setup_accounts" \
  | XDG_CONFIG_HOME="$test_root/config" sh scripts/config-store.sh accounts.json >/dev/null 2>&1; then
  fail "config-store.sh replaced saved accounts with setup state"
fi
actual_accounts=$(cat "$test_root/config/omamail/accounts.json")
[ "$actual_accounts" = "$saved_accounts" ] \
  || fail "config-store.sh changed the account list after refusing setup state"
updated_accounts='{"version":1,"accounts":[{"id":"imap:you@example.com","email":"you@example.com"}],"activeId":"imap:you@example.com"}'
printf '%s\n' "$updated_accounts" \
  | XDG_CONFIG_HOME="$test_root/config" sh scripts/config-store.sh accounts.json >/dev/null
actual_accounts=$(cat "$test_root/config/omamail/accounts.json")
[ "$actual_accounts" = "$updated_accounts" ] \
  || fail "config-store.sh refused a replacement that still contains a saved account"

printf '%s\n' '{"version":1,"active":true}' \
  | XDG_CONFIG_HOME="$test_root/config" sh scripts/config-store.sh compose.json >/dev/null
[ "$(stat -c '%a' "$test_root/config/omamail/compose.json")" = 600 ] \
  || fail "compose recovery must be owner-readable only"

# The keyring helper takes attribute pairs now, because keying a refresh token
# on the OAuth client alone lets two accounts sharing one client overwrite each
# other. An empty value is a secret-tool wildcard, so it is refused outright.
for bad in "" "a" "client-id "; do
  if printf 'token\n' | sh scripts/keyring-store.sh $bad >/dev/null 2>&1; then
    fail "keyring-store.sh accepted a malformed attribute list: '$bad'"
  fi
done

# libsecret replaces an existing item that matches the unversioned attributes
# without adding a newly introduced attribute. Remove that old shape first so
# a successful Calendar consent is stored as the versioned grant that restore
# looks up on the next launch.
mkdir -p "$test_root/bin"
printf '%s\n' '#!/bin/sh' 'printf '\''%s\n'\'' "$*" >> "$KEYRING_CALLS"' \
  > "$test_root/bin/secret-tool"
chmod +x "$test_root/bin/secret-tool"
KEYRING_CALLS="$test_root/keyring-calls" PATH="$test_root/bin:$PATH" \
  sh scripts/keyring-store.sh \
    service omamail kind refresh-token client-id client account me@example.com \
    grant calendar-events-v1 <<EOF
token
EOF
expected_calls='clear service omamail kind refresh-token client-id client account me@example.com
store --label=Omamail refresh token service omamail kind refresh-token client-id client account me@example.com grant calendar-events-v1'
actual_calls=$(cat "$test_root/keyring-calls")
[ "$actual_calls" = "$expected_calls" ] \
  || fail "keyring-store.sh did not replace the unversioned grant before storing the versioned one"

[ -x scripts/register-mailto.sh ] || fail "scripts/register-mailto.sh must be executable"
mailto_home=$(mktemp -d)
XDG_DATA_HOME="$mailto_home/share" XDG_CONFIG_HOME="$mailto_home/config" \
  sh scripts/register-mailto.sh "$(pwd)"
desktop="$mailto_home/share/applications/omamail.desktop"
[ -f "$desktop" ] || fail "register-mailto.sh did not write omamail.desktop"
grep -q '^MimeType=x-scheme-handler/mailto;$' "$desktop" \
  || fail "omamail.desktop must claim mailto"
grep -F '"magpie-mail" %u' "$desktop" >/dev/null \
  || fail "omamail.desktop Exec must use the stable native launcher"
grep -q '^Icon=omamail$' "$desktop" || fail "omamail.desktop must use the installed app icon"
! grep -q 'omarchy-shell shell summon' "$desktop" || fail "the native handler must not summon the shell"
# A second run with the file already there must not require --claim-default
# just to keep the desktop file current.
XDG_DATA_HOME="$mailto_home/share" XDG_CONFIG_HOME="$mailto_home/config" \
  sh scripts/register-mailto.sh "$(pwd)"
[ -f "$desktop" ] || fail "a second register-mailto.sh run removed omamail.desktop"
rm -rf "$mailto_home"

printf 'test_link_plugin.sh ok\n'

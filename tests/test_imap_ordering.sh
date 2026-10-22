# Algorithm: curl selects a URL mailbox before custom commands. A pathless URL changes FETCH output
# routing; --fail-early stops after a rejected ID. The controlled peer verifies all three
# constraints.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v curl >/dev/null 2>&1 || { echo "test_imap_ordering.sh: no curl, skipped"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "test_imap_ordering.sh: no python3, skipped"; exit 0; }

work=$(mktemp -d "${TMPDIR:-/tmp}/omamail-imap-ordering.XXXXXX")
trap 'rm -rf "$work"; [ -z "${srv_pid:-}" ] || kill "$srv_pid" 2>/dev/null || true' EXIT INT TERM HUP

fail() { printf 'test_imap_ordering.sh: %s\n' "$1" >&2; exit 1; }

cat > "$work/server.py" <<'PY'
import re, socket, sys, threading

log_path, id_reply = sys.argv[1], sys.argv[2]

def handle(conn):
    f = conn.makefile("rwb", buffering=0)
    f.write(b"* OK [CAPABILITY IMAP4rev1 ID AUTH=XOAUTH2] fake ready\r\n")
    auth_tag = None
    while True:
        line = f.readline()
        if not line:
            break
        text = line.decode("latin1").rstrip("\r\n")
        if auth_tag is not None:
            with open(log_path, "a") as fh:
                fh.write("OAUTH-RESPONSE\n")
            f.write(("%s OK authenticated\r\n" % auth_tag).encode())
            auth_tag = None
            continue
        with open(log_path, "a") as fh:
            # Invariant: The controlled server log must redact LOGIN and AUTHENTICATE credentials.
            safe = re.sub(r"(?i)^(\S+\s+LOGIN)\s+.*$", r"\1", text)
            safe = re.sub(r"(?i)^(\S+\s+AUTHENTICATE)\s+.*$", r"\1", safe)
            fh.write(safe + "\n")
        parts = text.split(" ", 2)
        if len(parts) < 2:
            continue
        tag, cmd = parts[0], parts[1].upper()
        rest = parts[2].upper() if len(parts) > 2 else ""
        if cmd == "AUTHENTICATE":
            auth_tag = tag
            f.write(b"+ \r\n")
        elif cmd == "ID" and id_reply == "bad":
            f.write(("%s BAD Unknown command\r\n" % tag).encode())
        elif cmd == "ID":
            # Algorithm: Real peers return an untagged ID line on stdout. Keeping it in this fixture
            # detects transport contamination of message bodies.
            f.write(b'* ID ("name" "fake" "version" "1")\r\n')
            f.write(("%s OK done\r\n" % tag).encode())
        elif cmd == "CAPABILITY":
            f.write(b"* CAPABILITY IMAP4rev1 ID AUTH=XOAUTH2\r\n")
            f.write(("%s OK done\r\n" % tag).encode())
        elif cmd == "SELECT":
            f.write(b"* 2 EXISTS\r\n")
            f.write(("%s OK [READ-WRITE] done\r\n" % tag).encode())
        elif cmd == "UID" and "BODY" in rest:
            # Algorithm: A single numeric UID with a BODY item is the one request libcurl recognises
            # as a message fetch, and it puts the answer on stdout rather than through the header
            # callback.
            body = b"Subject: hello\r\n\r\nthe body\r\n"
            f.write(b"* 1 FETCH (UID 101 BODY[] {%d}\r\n" % len(body))
            f.write(body)
            f.write(b")\r\n")
            f.write(("%s OK done\r\n" % tag).encode())
        elif cmd == "UID" and "FETCH" in rest:
            f.write(b"* 1 FETCH (UID 101)\r\n* 2 FETCH (UID 102)\r\n")
            f.write(("%s OK done\r\n" % tag).encode())
        elif cmd in ("UID", "SEARCH"):
            f.write(b"* SEARCH 1\r\n")
            f.write(("%s OK done\r\n" % tag).encode())
        elif cmd == "LOGOUT":
            f.write(b"* BYE bye\r\n")
            f.write(("%s OK done\r\n" % tag).encode())
            break
        else:
            f.write(("%s OK done\r\n" % tag).encode())
    conn.close()

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(5)
print(srv.getsockname()[1], flush=True)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

start_server() {
  : > "$work/log"
  : > "$work/port"
  python3 "$work/server.py" "$work/log" "$1" > "$work/port" 2>/dev/null &
  srv_pid=$!
  port=""
  for _ in $(seq 1 50); do
    port=$(cat "$work/port" 2>/dev/null || true)
    [ -n "$port" ] && break
    sleep 0.1
  done
  [ -n "$port" ] || fail "the fake server never reported a port"
}

stop_server() {
  kill "$srv_pid" 2>/dev/null || true
  wait "$srv_pid" 2>/dev/null || true
  srv_pid=""
}

# Algorithm: One transport invocation. Prints curl's exit code; leaves the commands the server saw
# in "$work/log" and what the caller was handed in "$work/reply".
transport() {
  local id_reply=$1 path=$2; shift 2
  start_server "$id_reply"
  local fields=""
  for c in "$@"; do fields="$fields $(b64 "$c")"; done
  printf 'imap %s %s%s\n' "$(b64 "imap://127.0.0.1:$port$path")" "$(b64 'jane:pw')" "$fields" \
    | ./scripts/mail-transport.sh > "$work/out" 2>/dev/null || true
  stop_server
  sed -n 2p "$work/out" | base64 -d > "$work/reply" 2>/dev/null || : > "$work/reply"
  head -1 "$work/out"
}

commands() { sed -E 's/^[A-Za-z0-9]+ //' "$work/log" | tr '\n' '|'; }
fetch_rows() { grep -c '^\* [0-9]* FETCH' "$work/reply" || true; }

# Invariant: The same real curl must turn the bearer option into XOAUTH2 rather than a password
# LOGIN. The server log redacts the initial response, so a failure cannot print the synthetic token
# either.
start_server ok
printf 'imap-oauth %s %s %s %s\n' \
  "$(b64 "imap://127.0.0.1:$port")" "$(b64 'jane@example.com')" \
  "$(b64 'synthetic-access-token')" "$(b64 'NOOP')" \
  | ./scripts/mail-transport.sh > "$work/out" 2>/dev/null || true
stop_server
[ "$(head -1 "$work/out")" = "0" ] || fail "OAuth IMAP should have succeeded, curl exited $(head -1 "$work/out")"
[ "$(commands)" = 'CAPABILITY|AUTHENTICATE|OAUTH-RESPONSE|NOOP|LOGOUT|' ] \
  || fail "the bearer token must select XOAUTH2, saw: $(commands)"

# Algorithm: The mode that carries the fix: the opening command runs against the server, the mailbox
# is opened after it, and the answer still reaches the caller.
start_server ok
printf 'imap-id %s %s %s %s %s\n' \
  "$(b64 "imap://127.0.0.1:$port")" "$(b64 "imap://127.0.0.1:$port/INBOX")" \
  "$(b64 'jane:pw')" "$(b64 'ID ("name" "omamail")')" "$(b64 'UID FETCH 1:* (UID)')" \
  | ./scripts/mail-transport.sh > "$work/out" 2>/dev/null || true
stop_server
sed -n 2p "$work/out" | base64 -d > "$work/reply" 2>/dev/null || : > "$work/reply"
[ "$(head -1 "$work/out")" = "0" ] || fail "imap-id should have succeeded, curl exited $(head -1 "$work/out")"
[ "$(commands)" = 'CAPABILITY|LOGIN|ID ("name" "omamail")|SELECT INBOX|UID FETCH 1:* (UID)|LOGOUT|' ] \
  || fail "ID must reach the server before SELECT, saw: $(commands)"
[ "$(fetch_rows)" = "2" ] || fail "imap-id must still deliver its FETCH rows, saw $(fetch_rows)"
[ "$(grep -c '^[A-Za-z0-9]* LOGIN$' "$work/log")" = "1" ] \
  || fail "the two sections must share one connection, and so one LOGIN"

# Algorithm: A single BODY FETCH reaches stdout while sequence-set replies use the header callback.
# The preliminary ID response must not enter the message body.
start_server ok
printf 'imap-id %s %s %s %s %s\n' \
  "$(b64 "imap://127.0.0.1:$port")" "$(b64 "imap://127.0.0.1:$port/INBOX")" \
  "$(b64 'jane:pw')" "$(b64 'ID ("name" "omamail")')" \
  "$(b64 'UID FETCH 101 (UID FLAGS BODY.PEEK[])')" \
  | ./scripts/mail-transport.sh > "$work/out" 2>/dev/null || true
stop_server
sed -n 2p "$work/out" | base64 -d > "$work/reply" 2>/dev/null || : > "$work/reply"
[ "$(head -1 "$work/out")" = "0" ] || fail "a body fetch should have succeeded, curl exited $(head -1 "$work/out")"
grep -q "the body" "$work/reply" \
  || fail "imap-id must deliver a message body, got: $(head -c 200 "$work/reply")"
case "$(commands)" in
  *'ID ("name" "omamail")|SELECT INBOX|UID FETCH 101'*) ;;
  *) fail "the body fetch must still run behind ID and SELECT, saw: $(commands)" ;;
esac

code=$(transport ok "/INBOX" 'ID ("name" "omamail")' 'UID FETCH 1:* (UID)')
[ "$code" = "0" ] || fail "a pathed URL should have succeeded, curl exited $code"
case "$(commands)" in
  *'SELECT INBOX|ID '*) ;;
  *) fail "expected curl's own SELECT to precede the first command, saw: $(commands)" ;;
esac

code=$(transport ok "" 'ID ("name" "omamail")' 'SELECT "INBOX"' 'UID FETCH 1:* (UID)')
[ "$code" = "0" ] || fail "a pathless URL should have succeeded, curl exited $code"
[ "$(fetch_rows)" = "0" ] \
  || fail "a pathless URL now delivers FETCH rows; imap-id may be simplifiable"

code=$(transport bad "" 'ID ("name" "omamail")' 'SELECT "INBOX"' 'UID FETCH 1:* (UID)')
[ "$code" = "0" ] && fail "a server that refuses ID must not be reported as success"
case "$(commands)" in
  *'UID FETCH'*) fail "--fail-early must stop the run at the BAD, saw: $(commands)" ;;
esac

# Invariant: --next resets --globoff. A URL in a later section must never expand into requests for
# other folders. Use real curl: checking argv misses the reset.
for path in '{one,two}' '[1-2]'; do
  start_server ok
  printf 'imap-id %s %s %s %s %s %s\n' \
    "$(b64 "imap://127.0.0.1:$port")" "$(b64 "imap://127.0.0.1:$port/$path")" \
    "$(b64 'jane:pw')" "$(b64 'ID NIL')" \
    "$(b64 'UID FETCH 1:* (UID)')" "$(b64 'NOOP')" \
    | ./scripts/mail-transport.sh > "$work/out" 2>/dev/null || true
  stop_server
  case "$(commands)" in
    *SELECT*|*'UID FETCH'*|*NOOP*) fail "a raw glob must not select or act on expanded folders, saw: $(commands)" ;;
  esac
  [ "$(head -1 "$work/out")" != "0" ] || fail "curl must refuse the raw folder URL"
done

# Invariant: The provider percent-encodes folder names. A legitimate name containing braces must
# still select exactly that mailbox and run each command once.
start_server ok
printf 'imap-id %s %s %s %s %s %s\n' \
  "$(b64 "imap://127.0.0.1:$port")" "$(b64 "imap://127.0.0.1:$port/%7Bone%2Ctwo%7D")" \
  "$(b64 'jane:pw')" "$(b64 'ID NIL')" \
  "$(b64 'UID FETCH 1:* (UID)')" "$(b64 'NOOP')" \
  | ./scripts/mail-transport.sh > "$work/out" 2>/dev/null || true
stop_server
[ "$(head -1 "$work/out")" = "0" ] || fail "an encoded folder name must succeed"
[ "$(commands)" = 'CAPABILITY|LOGIN|ID NIL|SELECT "{one,two}"|UID FETCH 1:* (UID)|NOOP|LOGOUT|' ] \
  || fail "an encoded folder must remain literal across all sections, saw: $(commands)"

# Invariant: Rust owns capability negotiation and sends ID once before selecting a folder. The
# native controlled-server test proves both ID/non-ID peers and pool reuse.
python3 - <<'SRC' || exit 1
from pathlib import Path
text = Path("src/providers/imap/mod.rs").read_text()
acquire = text[text.index("async fn acquire("):text.index("async fn release(")]
assert 'command(&mut wire, "CAPABILITY")' in acquire
assert 'if advertises(&capabilities, "ID")' in acquire
assert acquire.index('if advertises(&capabilities, "ID")') < acquire.index('"ID (')
assert 'p["identify"]' not in text
assert 'native_id_gate_is_checked_once_before_select' in Path("src/providers/imap/tests.rs").read_text()
SRC

echo "imap ordering ok"

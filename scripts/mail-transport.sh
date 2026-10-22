#!/bin/sh
# Protocol: one space-separated, base64-encoded request line on stdin.
#   imap <b64 url> <b64 user:password> <b64 command> [<b64 command> ...]
#   imap-id <b64 root url> <b64 url> <b64 user:password> <b64 preamble> <b64 command> ...
#   imap-append <b64 url> <b64 user:password> <b64 message> <b64 flags>
#   smtp <b64 url> <b64 user:password> <b64 from> <b64 message> <b64 rcpt> ...
#   *-oauth replaces <b64 user:password> with <b64 username> <b64 bearer token>.
#   graph-send <b64 url> <b64 token> <b64 message>
# Response: three lines containing the curl exit code, base64 stdout and base64 stderr.
# Invariant: credentials stay off argv. Read one line, not EOF: Quickshell keeps
# stdin open. Base64 preserves IMAP literal octets and response framing.
set -eu

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

decode() {
  printf '%s' "$1" | base64 -d 2>/dev/null || fail 'mail-transport.sh: bad base64 field'
}

# Invariant: validate_config_fields rejects controls before values reach escape.
escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Invariant: GNU/BSD base64 wrapping must not add response framing lines.
encode() {
  base64 < "$1" | tr -d '\n'
}

. "$(dirname "$0")/curl-config.sh"

IFS= read -r line || fail 'mail-transport.sh: no request on stdin'
[ -n "$line" ] || fail 'mail-transport.sh: empty request'

# Invariant: encoded fields contain no spaces.
# shellcheck disable=SC2086
set -- $line
[ $# -ge 4 ] || fail 'mail-transport.sh: usage: <mode> <url> <credentials> <arg>...'

mode=$1
case "$mode" in
  imap-oauth) [ $# -ge 5 ] || fail 'mail-transport.sh: imap-oauth needs a URL, a username, a bearer token and a command' ;;
  imap-id-oauth) [ $# -ge 7 ] || fail 'mail-transport.sh: imap-id-oauth needs two URLs, a username, a bearer token, a preamble and a command' ;;
  imap-append-oauth) [ $# -eq 6 ] || fail 'mail-transport.sh: imap-append-oauth needs a URL, a username, a bearer token, a message and flags' ;;
  smtp-oauth) [ $# -ge 7 ] || fail 'mail-transport.sh: smtp-oauth needs a URL, a username, a bearer token, a sender, a message and a recipient' ;;
  graph-send) [ $# -eq 4 ] || fail 'mail-transport.sh: graph-send needs a url, a token and a message' ;;
esac
# Invariant: validate every config field before curl starts. Only uploaded
# message bodies bypass this check; APPEND flags remain config values.
field_number=0
for field in "$@"; do
  field_number=$((field_number + 1))
  case "$mode:$field_number" in
    *:1|smtp:5|imap-append:4|smtp-oauth:6|imap-append-oauth:5|graph-send:4) continue ;;
  esac
  validate_config_fields "$field"
done
# Invariant: RFC 2971 ID runs at the root URL before curl's path-derived SELECT.
# curl reuses the connection for the subsequent mailbox commands.
case "$mode" in
  imap-oauth|imap-id-oauth|imap-append-oauth|smtp-oauth) oauth=1 ;;
  *) oauth=0 ;;
esac

case "$mode" in
  imap-id|imap-id-oauth) identified=1 ;;
  *) identified=0 ;;
esac

if [ "$identified" = 1 ]; then
  [ $# -ge 6 ] || fail 'mail-transport.sh: imap-id needs a root url, a url, credentials, a preamble and a command'
  root_url=$(decode "$2")
  url=$(decode "$3")
  if [ "$oauth" = 1 ]; then
    [ $# -ge 7 ] || fail 'mail-transport.sh: imap-id-oauth needs a root url, a url, a username, a bearer token, a preamble and a command'
    username=$(decode "$4")
    bearer=$(decode "$5")
    shift 5
  else
    credentials=$(decode "$4")
    shift 4
  fi
  case "$root_url" in
    imaps://*|imap://*) ;;
    *) fail 'mail-transport.sh: refusing a root URL that is not imap(s)' ;;
  esac
  escaped_root_url=$(escape "$root_url")
else
  url=$(decode "$2")
  if [ "$oauth" = 1 ]; then
    username=$(decode "$3")
    bearer=$(decode "$4")
    shift 4
  else
    credentials=$(decode "$3")
    shift 3
  fi
fi

case "$mode" in
  imap|imap-id|imap-append|smtp|imap-oauth|imap-id-oauth|imap-append-oauth|smtp-oauth|graph-send) ;;
  *) fail 'mail-transport.sh: unsupported mode' ;;
esac

# Invariant: reject non-mail schemes even when the caller was bypassed.
case "$url" in
  # Invariant: Graph bearer tokens may only reach this fixed endpoint.
  https://graph.microsoft.com/v1.0/me/sendMail) [ "$mode" = "graph-send" ] || fail 'mail-transport.sh: refusing a URL that is not imap(s) or smtp(s)' ;;
  imaps://*|imap://*|smtps://*|smtp://*) [ "$mode" != "graph-send" ] || fail 'mail-transport.sh: graph-send goes to Graph alone' ;;
  *) fail 'mail-transport.sh: refusing a URL that is not imap(s) or smtp(s)' ;;
esac

escaped_url=$(escape "$url")
if [ "$oauth" = 1 ]; then
  escaped_username=$(escape "$username")
  escaped_bearer=$(escape "$bearer")
else
  escaped_credentials=$(escape "$credentials")
fi

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/omamail.XXXXXX") || fail 'mail-transport.sh: no temporary directory'
trap 'rm -rf "$work"' EXIT INT TERM HUP

case "$mode" in smtp|smtp-oauth) sending=1 ;; *) sending=0 ;; esac
case "$mode" in imap-append|imap-append-oauth) appending=1 ;; *) appending=0 ;; esac

# Invariant: credential-bearing config reaches curl through stdin, never disk.
build_config() {
if [ "$mode" = "graph-send" ]; then
  printf 'url = "%s"\n' "$escaped_url"
  printf 'noproxy = "*"\n'
  printf 'request = "POST"\n'
  printf 'header = "%s"\n' "$(escape "Authorization: Bearer $graph_token")"
  printf 'header = "Content-Type: text/plain"\n'
  printf 'max-time = 60\n'
  printf 'connect-timeout = 20\n'
  printf 'data-binary = "@%s"\n' "$(escape "$work/message")"
elif [ "$sending" = 1 ]; then
  [ $# -ge 3 ] || fail 'mail-transport.sh: smtp needs a sender, a message and a recipient'
  sender=$(decode "$1")
  shift 2

  printf 'url = "%s"\n' "$escaped_url"
  printf 'noproxy = "*"\n'
  print_authentication
  printf 'max-time = 60\n'
  printf 'connect-timeout = 20\n'
  case "$url" in
    smtp://127.0.0.1:*|smtp://localhost:*) ;;
    smtp://*) printf 'ssl-reqd\n' ;;
  esac
  printf 'mail-from = "%s"\n' "$(escape "$sender")"
  for recipient in "$@"; do
    printf 'mail-rcpt = "%s"\n' "$(escape "$(decode "$recipient")")"
  done
  # Invariant: stdin carries config; uploads use the private temporary directory.
  printf 'upload-file = "%s"\n' "$(escape "$work/message")"
elif [ "$appending" = 1 ]; then
  printf 'url = "%s"\n' "$escaped_url"
  printf 'noproxy = "*"\n'
  print_authentication
  printf 'max-time = 60\n'
  printf 'connect-timeout = 20\n'
  case "$url" in
    imap://127.0.0.1:*|imap://localhost:*) ;;
    imap://*) printf 'ssl-reqd\n' ;;
  esac
  printf 'upload-file = "%s"\n' "$(escape "$work/message")"
  # Protocol: the caller supplies space-separated curl upload flags.
  printf 'upload-flags = "%s"\n' "$(escape "$(decode "$2")")"
else
  # Performance: curl reuses the connection across command sections.
  # Invariant: next resets transfer options; repeat credentials and bounds.
  first=1
  for argument in "$@"; do
    [ "$first" = "1" ] || printf 'next\n'
    # Invariant: next also resets globoff.
    printf 'globoff\n'
    # Invariant: only the opening ID command uses the root URL.
    if [ "$identified" = 1 ] && [ "$first" = "1" ]; then
      printf 'url = "%s"\n' "$escaped_root_url"
      # Invariant: an ID reply on stdout would suppress the BODY FETCH fallback.
      # output applies only to this section.
      printf 'output = "%s"\n' "/dev/null"
    else
      printf 'url = "%s"\n' "$escaped_url"
    fi
    first=0
    # Invariant: desktop web proxies must not receive mail credentials.
    # Omarchy's SOCKS proxy also drops IMAPS TLS; repeat after next.
    printf 'noproxy = "*"\n'
    print_authentication
    printf 'max-time = 60\n'
    printf 'connect-timeout = 20\n'
    case "$url" in
      imap://127.0.0.1:*|imap://localhost:*) ;;
      imap://*) printf 'ssl-reqd\n' ;;
    esac
    printf 'request = "%s"\n' "$(escape "$(decode "$argument")")"
  done
fi
}

print_authentication() {
  if [ "$oauth" = 1 ]; then
    printf 'user = "%s"\n' "$escaped_username"
    printf 'oauth2-bearer = "%s"\n' "$escaped_bearer"
  else
    printf 'user = "%s"\n' "$escaped_credentials"
  fi
}

if [ "$mode" = "graph-send" ]; then
  [ $# -eq 1 ] || fail 'mail-transport.sh: graph-send needs a url, a token and a message'
  graph_token=$credentials
  # Protocol: Graph accepts base64 MIME in a text/plain POST.
  decode "$1" > "$work/mime"
  base64 < "$work/mime" > "$work/encoded"
  tr -d '\n' < "$work/encoded" > "$work/message"
elif [ "$sending" = 1 ]; then
  [ $# -ge 3 ] || fail 'mail-transport.sh: smtp needs a sender, a message and a recipient'
  decode "$2" > "$work/message"
elif [ "$appending" = 1 ]; then
  [ $# -eq 2 ] || fail 'mail-transport.sh: imap-append needs one message and its flags'
  decode "$1" > "$work/message"
fi

# Invariant: the pipeline exit code belongs to curl.
attempt_curl() {
  build_config "$@" | curl -q --globoff \
    --fail-early \
    --config - \
    --silent \
    --show-error \
    --dump-header "$work/headers" \
    > "$work/out" 2> "$work/err"
}

# Invariant: retry only pre-session failures: DNS (6), connect (7), TLS (35).
# Broader curl retries can duplicate SMTP delivery or APPEND after acceptance.
# Authentication failures (67) must not multiply attempts against account limits.
attempt=0
while :; do
  set +e
  attempt_curl "$@"
  status=$?
  set -e
  case "$status" in
    6|7|35) ;;
    *) break ;;
  esac
  attempt=$((attempt + 1))
  [ "$attempt" -le 2 ] || break
  sleep 1
done

# Protocol: Graph HTTP failures need an explicit status check after curl succeeds.
if [ "$mode" = "graph-send" ] && [ "$status" -eq 0 ]; then
  http=$(sed -n 's/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' "$work/headers" 2>/dev/null | tail -1)
  case "$http" in
    2[0-9][0-9]) ;;
    "") status=22; printf 'Graph gave no HTTP status' > "$work/err" ;;
    *) status=22; printf 'Graph answered %s: %s' "$http" "$(tr -d '\r' < "$work/out" | head -c 400)" > "$work/err" ;;
  esac
fi

printf '%s\n' "$status"
if { [ "$mode" = "imap" ] || [ "$mode" = "imap-id" ] \
  || [ "$mode" = "imap-oauth" ] || [ "$mode" = "imap-id-oauth" ]; } \
  && [ ! -s "$work/out" ] && [ -s "$work/headers" ]; then
  # Invariant: libcurl sends sequence-set FETCH replies through its header
  # callback. Prefer stdout for single-UID BODY FETCH; headers are partial there.
  encode "$work/headers"
else
  encode "$work/out"
fi
printf '\n'
encode "$work/err"
printf '\n'

#!/usr/bin/env python3
"""Open Magpie Calendar, or hand it an invitation or a suggested event to review.

Usage: open-magpie-calendar.py [magpiecalendar: link | skylark: link | handoff JSON]

Magpie Calendar was called Skylark. A copy installed before the rename answers only to that name, so
the calendar is summoned by its new name first and by the old one when the shell knows no other.
"""
import base64
import json
import subprocess
import sys
import urllib.parse

# Invariant: the calendar's name, then its name before the rename.
CALENDAR_PLUGINS = ('magpie-calendar', 'skylark')
LINK_SCHEMES = ('magpiecalendar', 'skylark')
NOT_OPENED = 'Magpie Calendar could not open. Check that Magpie Calendar is installed and the desktop is unlocked.'


def payload(value):
    if len(value.encode()) > 100_000:
        raise ValueError('The calendar link is too large.')
    if value.startswith(tuple(scheme + ':' for scheme in LINK_SCHEMES)):
        url = urllib.parse.urlsplit(value)
        if url.scheme not in LINK_SCHEMES or url.username or url.password or url.port or url.fragment:
            raise ValueError('This is not a Magpie Calendar link.')
        if url.netloc == 'calendar' and url.path in ('', '/') and not url.query:
            return {}
        if url.netloc != 'handoff' or url.path not in ('', '/'):
            raise ValueError('This is not a Magpie Calendar handoff.')
        query = [tuple(urllib.parse.unquote(part) for part in item.split('=', 1)) for item in url.query.split('&')]
        if len(query) != 1 or len(query[0]) != 2 or query[0][0] != 'data':
            raise ValueError('This calendar link is incomplete.')
        raw = base64.b64decode(query[0][1], validate=True)
        if len(raw) > 49152:
            raise ValueError('The calendar link is too large.')
        request = json.loads(raw)
    else:
        request = json.loads(value or '{}')
    if request == {}:
        return {}
    if not isinstance(request, dict) or type(request.get('version')) is not int or request.get('version') != 1 or request.get('kind') not in ('invitation', 'suggestion', 'event'):
        raise ValueError('This calendar handoff is not supported.')
    owner = request.get('accountId')
    if not isinstance(owner, str) or not owner or len(owner.encode()) > 1024 or any(ord(c) < 32 for c in owner):
        raise ValueError('This calendar link has no account.')
    return {'handoff': request}


def summon(value):
    message = json.dumps(value, ensure_ascii=False)
    for plugin in CALENDAR_PLUGINS:
        answer = subprocess.run(['omarchy-shell', 'shell', 'summon', plugin, message], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, check=True, timeout=15).stdout.strip()
        if answer == 'ok':
            return
        # Invariant: the shell answers `unknown` for a plugin it does not have; anything else is no answer.
        if answer != 'unknown':
            raise OSError('The shell gave no answer.')
    raise OSError('Magpie Calendar is not installed.')


def main():
    if len(sys.argv) > 2:
        raise ValueError('Open one calendar link at a time.')
    summon(payload(sys.argv[1] if len(sys.argv) == 2 else '{}'))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RecursionError, OSError, subprocess.SubprocessError):
        print(NOT_OPENED, file=sys.stderr)
        sys.exit(1)

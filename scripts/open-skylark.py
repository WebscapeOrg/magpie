#!/usr/bin/env python3
import base64
import json
import subprocess
import sys
import urllib.parse


def payload(value):
    if len(value.encode()) > 100_000:
        raise ValueError('The calendar link is too large.')
    if value.startswith('skylark:'):
        url = urllib.parse.urlsplit(value)
        if url.scheme != 'skylark' or url.username or url.password or url.port or url.fragment:
            raise ValueError('This is not a Skylark link.')
        if url.netloc == 'calendar' and url.path in ('', '/') and not url.query:
            return {}
        if url.netloc != 'handoff' or url.path not in ('', '/'):
            raise ValueError('This is not a Skylark handoff.')
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


def main():
    if len(sys.argv) > 2:
        raise ValueError('Open one calendar link at a time.')
    value = payload(sys.argv[1] if len(sys.argv) == 2 else '{}')
    subprocess.run(['omarchy-shell', 'shell', 'summon', 'skylark', json.dumps(value, ensure_ascii=False)], check=True, timeout=15)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('Skylark could not open. Check that Skylark is installed and the desktop is unlocked.', file=sys.stderr)
        sys.exit(1)

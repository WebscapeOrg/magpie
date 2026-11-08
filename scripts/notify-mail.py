#!/usr/bin/env python3
"""Show a new-mail notification with Magpie Mail's icon, Apple's ✉️ (ui/assets/magpie-mail.png)."""
import os
from pathlib import Path
import sys
from html import escape

ICON = Path(__file__).resolve().parents[1] / 'ui/assets/magpie-mail.png'


def main(args):
    if len(args) != 3 or args[0] != '--':
        return 2
    _, title, body = args
    # Preserve notify-send's stdout action and lifetime for the QML waiter.
    # notify-send treats these arguments as markup. Escape sender-authored text
    # at the last boundary so native notification APIs still receive plain text.
    title = escape(title, quote=False)
    body = escape(body, quote=False)
    actions = ['--action=default=Read...']
    os.execvp('notify-send', ['notify-send', '-a', 'Magpie Mail', '-i', str(ICON)]
              + actions + ['--', title, body])


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

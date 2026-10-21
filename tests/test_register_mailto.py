#!/usr/bin/env python3
"""Desktop Entry parsing must preserve a plugin path and one mailto argument."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MailtoRegistration(unittest.TestCase):
    @unittest.skipUnless(importlib.util.find_spec('gi'), 'requires the Linux Desktop Entry launcher bindings')
    def test_special_path_launches_the_exact_handler(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plugin = root / 'space "quote" $dollar `tick` \\slash %u'
            (plugin / 'scripts').mkdir(parents=True)
            (plugin / 'ui/assets').mkdir(parents=True)
            (plugin / 'ui/assets/magpie.svg').touch()
            marker = root / 'received.json'
            handler = plugin / 'scripts/mailto.sh'
            handler.write_text(f'#!{sys.executable}\nimport json,sys\nfrom pathlib import Path\nPath({str(marker)!r}).write_text(json.dumps(sys.argv))\n')
            handler.chmod(0o700)
            tools = root / 'bin'
            tools.mkdir()
            for name in ('update-desktop-database', 'xdg-mime', 'xdg-settings'):
                tool = tools / name
                tool.write_text('#!/bin/sh\nexit 0\n')
                tool.chmod(0o700)
            env = dict(os.environ, HOME=str(root), XDG_DATA_HOME=str(root/'data'),
                       XDG_CONFIG_HOME=str(root/'config'), XDG_CACHE_HOME=str(root/'cache'),
                       PATH=str(tools)+os.pathsep+os.environ['PATH'])
            subprocess.run(['sh', str(ROOT/'scripts/register-mailto.sh'), str(plugin)], env=env, check=True, capture_output=True)
            desktop = root/'data/applications/omamail.desktop'
            url = 'mailto:ada@example.test?subject=One%20argument'
            launcher = 'import sys;from gi.repository import Gio;app=Gio.DesktopAppInfo.new_from_filename(sys.argv[1]);assert app;app.launch_uris([sys.argv[2]],None)'
            result = subprocess.run([sys.executable, '-c', launcher, str(desktop), url], env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr + desktop.read_text())
            deadline = time.monotonic()+3
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(marker.exists(), 'the exact handler did not launch')
            self.assertEqual(json.loads(marker.read_text()), [str(handler), url])


if __name__ == '__main__':
    unittest.main()

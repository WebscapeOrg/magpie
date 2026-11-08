#!/usr/bin/env python3
"""Exercise the icon writer and its exact notify-send argv, without a desktop."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NotificationTest(unittest.TestCase):
    def test_icon_and_sender_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            notify = tmp / 'notify-send'
            notify.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                              'open(os.environ["CAPTURE"],"w").write(json.dumps(sys.argv[1:]))\n'
                              'print("default")\n')
            notify.chmod(0o700)
            env = dict(os.environ, PATH=str(tmp) + ':' + os.environ['PATH'], CAPTURE=str(tmp / 'argv'))
            result = subprocess.run(['python3', str(ROOT / 'scripts/notify-mail.py'),
                '--', '-u critical $(touch forbidden)', 'Quotes " \\ 你好\nbody'], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'default\n')
            args = json.loads((tmp / 'argv').read_text())
            self.assertEqual(args[:2], ['-a', 'Magpie Mail'])
            self.assertEqual(args[-3:], ['--', '-u critical $(touch forbidden)', 'Quotes " \\ 你好\nbody'])
            self.assertIn('--action=default=Read...', args)
            icon = Path(args[args.index('-i') + 1])
            self.assertEqual(icon, ROOT / 'ui/assets/magpie-mail.png')
            self.assertEqual(icon.read_bytes()[:8], b'\x89PNG\r\n\x1a\n')
            (tmp / 'argv').unlink()
            for bad in [['title', 'body'], ['#eeeeee', '#abcdef', '--', 'title', 'body'], ['--', 'title']]:
                result = subprocess.run(['python3', str(ROOT / 'scripts/notify-mail.py'), *bad], env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((tmp / 'argv').exists(), 'malformed arguments started notify-send')
            self.assertFalse((ROOT / 'forbidden').exists())

    def test_sender_markup_is_escaped_only_at_notify_send(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            notify = tmp / 'notify-send'
            notify.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                              'open(os.environ["CAPTURE"],"w").write(json.dumps(sys.argv[1:]))\n')
            notify.chmod(0o700)
            env = dict(os.environ, PATH=str(tmp) + ':' + os.environ['PATH'], CAPTURE=str(tmp / 'argv'))
            result = subprocess.run(['python3', str(ROOT / 'scripts/notify-mail.py'),
                '--', '<img> & sender', 'body <b>&'], env=env)
            self.assertEqual(result.returncode, 0)
            args = json.loads((tmp / 'argv').read_text())
            self.assertEqual(args[-2:], ['&lt;img&gt; &amp; sender', 'body &lt;b&gt;&amp;'])
            before = (tmp / 'argv').read_bytes()
            result = subprocess.run(['python3', str(ROOT / 'scripts/notify-mail.py'), '--calendar',
                '--', '<img> & event', '--action=evil'], env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((tmp / 'argv').read_bytes(), before, 'removed calendar mode must not notify')



if __name__ == '__main__':
    unittest.main()

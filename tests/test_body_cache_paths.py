#!/usr/bin/env python3
"""The historical cache helper must confine writes and deletion to its directory."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1]/'scripts/body-cache.sh'


class CachePaths(unittest.TestCase):
    def test_clear_cannot_traverse_out_of_an_account_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            account = root/'omamail/bodies/account'
            account.mkdir(parents=True)
            outside = root/'outside'
            outside.mkdir()
            marker = outside/'keep'
            marker.write_text('KEEP')
            result = subprocess.run([str(SCRIPT), 'clear', str(account)+'/../../../outside'], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(), 'KEEP')

    def test_linked_directory_cannot_receive_cached_mail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root/'outside'
            outside.mkdir(mode=0o755)
            before = outside.stat().st_mode
            linked = root/'linked'
            linked.symlink_to(outside, target_is_directory=True)
            result = subprocess.run([str(SCRIPT), 'put', str(linked), 'mail.json'],
                                    input='{"body":"synthetic"}\n', text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(outside.iterdir()), [])
            self.assertEqual(outside.stat().st_mode, before)

    def test_put_prune_touch_and_clear_keep_the_expected_account_scope(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            account = root/'omamail/bodies/account'
            for name in ('first.json', 'second.json'):
                subprocess.run([str(SCRIPT), 'put', str(account), name, '1'],
                               input='{"body":"synthetic"}\n', text=True, check=True)
                if name == 'first.json':
                    os.utime(account/name, (1, 1))
            self.assertEqual([p.name for p in account.iterdir()], ['second.json'])
            self.assertEqual((account/'second.json').stat().st_mode & 0o777, 0o600)
            subprocess.run([str(SCRIPT), 'touch', str(account), 'second.json'], check=True)
            neighbor = account.parent/'neighbor'
            neighbor.mkdir()
            subprocess.run([str(SCRIPT), 'clear', str(account)], check=True)
            self.assertFalse(account.exists())
            self.assertTrue(neighbor.is_dir())


if __name__ == '__main__':
    unittest.main()

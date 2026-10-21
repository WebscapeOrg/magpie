#!/usr/bin/env python3
"""Private config writes cannot follow a predictable temporary link or store link."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1]/'scripts/config-store.sh'


class ConfigPaths(unittest.TestCase):
    def test_precreated_pid_temporary_link_cannot_overwrite_another_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root/'config/omamail'
            config.mkdir(parents=True)
            outside = root/'keep'
            outside.write_text('KEEP')
            env = dict(os.environ, XDG_CONFIG_HOME=str(root/'config'))
            process = subprocess.Popen(['sh', '-c', 'printf "%s\\n" "$$"; exec "$1" credentials.json',
                                        'test-config-store', str(SCRIPT)], env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                pid = int(process.stdout.readline())
                (config/f'credentials.json.tmp.{pid}').symlink_to(outside)
                stdout, stderr = process.communicate('{"clientSecret":"synthetic-private"}\n', timeout=5)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(outside.read_text(), 'KEEP')
            target = config/'credentials.json'
            self.assertEqual(target.read_text(), '{"clientSecret":"synthetic-private"}\n')
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertNotIn('synthetic-private', stdout+stderr)

    def test_store_directory_link_cannot_create_or_chmod_outside_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'config').mkdir()
            outside = root/'outside'
            outside.mkdir(mode=0o755)
            before_mode = outside.stat().st_mode
            (root/'config/omamail').symlink_to(outside, target_is_directory=True)
            result = subprocess.run([str(SCRIPT), 'credentials.json'],
                input='{"clientSecret":"synthetic-private"}\n', text=True, capture_output=True,
                env=dict(os.environ, XDG_CONFIG_HOME=str(root/'config')), timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(outside.iterdir()), [])
            self.assertEqual(outside.stat().st_mode, before_mode)
            self.assertNotIn('synthetic-private', result.stdout+result.stderr)


if __name__ == '__main__':
    unittest.main()

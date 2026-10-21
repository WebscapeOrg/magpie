#!/usr/bin/env python3
"""The QML fixture retains ownership until its process group is stopped."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('backend_process', ROOT / 'tests/test_backend_process.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class CleanupTests(unittest.TestCase):
    def test_leader_remains_owned_until_descendant_cleanup(self):
        real_popen = subprocess.Popen
        real_killpg = os.killpg
        observed = []

        def start(command, **options):
            return real_popen([sys.executable, '-c', "print('BACKEND_PROCESS_PASS')"], **options)

        def stop(group, signum):
            try:
                os.waitid(os.P_PID, group, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            except ChildProcessError:
                self.fail('the fixture already reaped the leader before signaling its saved process-group number')
            observed.append(group)
            real_killpg(group, signum)

        with mock.patch.object(fixture.shutil, 'which', return_value='synthetic-qs'), \
                mock.patch.object(fixture.subprocess, 'Popen', side_effect=start), \
                mock.patch.object(fixture.os, 'killpg', side_effect=stop):
            fixture.main()
        self.assertEqual(len(observed), 1)

    def test_exited_leader_does_not_leave_a_descendant_running(self):
        real_popen = subprocess.Popen
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / 'forbidden-write'
            child = f"import time;from pathlib import Path;time.sleep(1);Path({str(marker)!r}).touch()"
            parent = (f"import subprocess,sys;subprocess.Popen([sys.executable,'-c',{child!r}],"
                      "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);print('BACKEND_PROCESS_PASS')")

            def start(command, **options):
                return real_popen([sys.executable, '-c', parent], **options)

            with mock.patch.object(fixture.shutil, 'which', return_value='synthetic-qs'), \
                    mock.patch.object(fixture.subprocess, 'Popen', side_effect=start):
                fixture.main()
            time.sleep(1.1)
            self.assertFalse(marker.exists(), 'the child must stop even after its leader exits')


if __name__ == '__main__':
    unittest.main()

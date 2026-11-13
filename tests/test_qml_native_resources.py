#!/usr/bin/env python3
"""Private QML bridge resources must stop when fixture preparation fails."""
import importlib.util
from pathlib import Path
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('qml_native', ROOT / 'tests/run_qml_native.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class ResourceTests(unittest.TestCase):
    def test_import_preparation_failure_stops_the_private_server_and_backend(self):
        backend = mock.Mock()
        server = mock.Mock(server_port=12345)
        with mock.patch.object(native.subprocess, 'Popen', return_value=backend), \
                mock.patch.object(native.http.server, 'ThreadingHTTPServer', return_value=server), \
                mock.patch.object(native.threading, 'Thread'), \
                mock.patch.object(native.shutil, 'copytree', side_effect=OSError('synthetic import failure')), \
                mock.patch.object(native.sys, 'argv', ['run_qml_native.py', 'synthetic-runner']):
            with self.assertRaisesRegex(OSError, 'synthetic import failure'):
                native.main()
        server.shutdown.assert_called_once()
        server.server_close.assert_called_once()
        backend.terminate.assert_called_once()
        backend.wait.assert_called_once_with(timeout=5)

    def test_server_creation_failure_stops_the_private_backend(self):
        backend = mock.Mock()
        with mock.patch.object(native.subprocess, 'Popen', return_value=backend), \
                mock.patch.object(native.http.server, 'ThreadingHTTPServer', side_effect=OSError('synthetic bind failure')), \
                mock.patch.object(native.sys, 'argv', ['run_qml_native.py', 'synthetic-runner']):
            with self.assertRaisesRegex(OSError, 'synthetic bind failure'):
                native.main()
        backend.terminate.assert_called_once()
        backend.wait.assert_called_once_with(timeout=5)


if __name__ == '__main__':
    unittest.main()

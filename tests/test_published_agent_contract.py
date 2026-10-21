#!/usr/bin/env python3
"""The published agent fixture verifies the selected version and API together."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('published_agent', Path(__file__).with_name('test_agent_published_qml.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class PublishedContractTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / 'backend-version').write_text('0.11.0\n')
        (root / 'backend-api.json').write_text(json.dumps({'apiVersion': 8, 'releasedApiVersion': 7}))
        self.root = patch.object(fixture, 'ROOT', root)
        self.root.start()
        self.addCleanup(self.root.stop)

    def test_default_contract_requires_current_published_pin(self):
        expected = fixture.expected_contract(None)
        self.assertEqual(expected, {'version': '0.11.0', 'apiVersion': 7})
        fixture.verify_contract(expected, expected)
        for wrong in ({'version': '0.11.0', 'apiVersion': 5},
                      {'version': '0.11.0', 'apiVersion': 8},
                      {'version': '0.10.0', 'apiVersion': 7}):
            with self.subTest(wrong=wrong), self.assertRaises(AssertionError):
                fixture.verify_contract(wrong, expected)

    def test_import_failure_closes_the_private_http_listener(self):
        server = Mock(server_port=12345)
        info = Mock(stdout=json.dumps({'ok': True, 'result': {'version': '0.11.0', 'apiVersion': 7}}))
        with patch.object(fixture.subprocess, 'run', return_value=info), \
                patch.object(fixture.http.server, 'ThreadingHTTPServer', return_value=server), \
                patch.object(fixture.threading, 'Thread'), \
                patch.object(fixture.shutil, 'copytree', side_effect=OSError('synthetic import failure')), \
                patch.object(fixture.sys, 'argv', ['test', '--binary', '/unused-synthetic-backend']):
            with self.assertRaisesRegex(OSError, 'synthetic import failure'):
                fixture.main()
        server.shutdown.assert_called_once()
        server.server_close.assert_called_once()

    def test_historical_api5_requires_an_explicit_version(self):
        expected = fixture.expected_contract('0.9.3')
        self.assertEqual(expected, {'version': '0.9.3', 'apiVersion': 5})
        fixture.verify_contract(expected, expected)
        with self.assertRaises(AssertionError):
            fixture.verify_contract({'version': '0.11.0', 'apiVersion': 7}, expected)


if __name__ == '__main__':
    unittest.main()

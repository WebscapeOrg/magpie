#!/usr/bin/env python3
"""Exercise phone commands without live accounts, credentials or desktop services."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('MAGPIE_TEST_BINARY', ROOT / 'target/debug/omamail'))


@unittest.skipUnless(sys.platform == 'linux', 'Enterprise phone CLI is Linux only')
class PhoneCLI(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='magpie-phone-cli-')
        self.home = Path(self.temporary.name)
        self.env = {**os.environ, 'HOME': str(self.home),
                    'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/nonexistent-magpie-phone-fixture'}
        self.env.pop('DISPLAY', None)
        self.env.pop('WAYLAND_DISPLAY', None)
        for kind in ['CONFIG', 'STATE', 'CACHE', 'DATA', 'RUNTIME']:
            path = self.home / kind.lower()
            path.mkdir(mode=0o700)
            self.env['XDG_' + kind + ('_DIR' if kind == 'RUNTIME' else '_HOME')] = str(path)
        self.env['TMPDIR'] = self.env['XDG_RUNTIME_DIR']
        self.state = self.home / 'state/omamail'
        self.state.mkdir(mode=0o700)
        self.marker = self.state / 'engine-enabled'
        self.marker.write_text('fixture')
        self.marker.chmod(0o600)
        self.endpoint = self.home / 'runtime/omamail/engine/outbox.sock'
        self.endpoint.parent.mkdir(parents=True, mode=0o700)
        self.endpoint.parent.parent.chmod(0o700)
        self.daemon = None
        self.listeners = []
        self.threads = []
        self.received = []

    def tearDown(self):
        if self.daemon:
            self.daemon.terminate()
            try:
                self.daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.daemon.kill()
                self.daemon.wait(timeout=5)
        for listener in self.listeners:
            listener.close()
        for thread in self.threads:
            thread.join(timeout=3)
        self.temporary.cleanup()

    def run_cli(self, *args):
        return subprocess.run([str(BINARY), 'phone', *args], env=self.env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=40)

    def mock(self, responses, mode=0o600):
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(self.endpoint))
        self.endpoint.chmod(mode)
        listener.listen()
        listener.settimeout(2)
        self.listeners.append(listener)

        def serve():
            for response in responses:
                try:
                    connection, _ = listener.accept()
                except (TimeoutError, OSError):
                    return
                with connection:
                    connection.settimeout(2)
                    with connection.makefile('rb') as stream:
                        request = json.loads(stream.readline(1024 * 1024))
                    self.received.append(request)
                    if isinstance(response, bytes):
                        payload = response
                    else:
                        payload = (json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': response}) + '\n').encode()
                    try:
                        connection.sendall(b'{"jsonrpc":"2.0","method":"local.changed"}\n' + payload)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
        thread = threading.Thread(target=serve)
        thread.start()
        self.threads.append(thread)

    def test_pair_uses_owner_and_redacts_unexpected_fields(self):
        self.mock([{'code': '012345', 'expiresInSeconds': 300, 'token': 'never-print-this'}])
        answer = self.run_cli('pair', '--json')
        self.assertEqual(answer.returncode, 0, answer.stderr)
        self.assertEqual(json.loads(answer.stdout), {'ok': True, 'result': {'code': '012345', 'expiresInSeconds': 300}})
        self.assertEqual(answer.stderr, '')
        self.assertEqual(self.received[0]['method'], 'phone.pairBegin')
        self.assertEqual(self.received[0]['params'], {})
        self.assertFalse((self.state / 'phone').exists())
        self.assertFalse((self.state / 'mail').exists())

    def test_human_pair_code_and_instructions(self):
        self.mock([{'code': '012345', 'expiresInSeconds': 300}])
        answer = self.run_cli('pair')
        self.assertEqual(answer.returncode, 0, answer.stderr)
        self.assertIn('Pairing code: 012345', answer.stdout)
        self.assertIn('Settings → Enterprise', answer.stdout)
        self.assertIn('5 minutes', answer.stdout)
        self.assertIn('replaces this one', answer.stdout)
        self.assertNotIn('012345', answer.stderr)

    def test_disabled_and_absent_engine_never_start_an_owner(self):
        self.marker.unlink()
        before = sorted(str(p.relative_to(self.home)) for p in self.home.rglob('*'))
        answer = self.run_cli('pair', '--json')
        self.assertEqual(answer.returncode, 1)
        self.assertEqual(json.loads(answer.stdout)['error']['code'], 'phone_engine_not_enabled')
        self.assertEqual(before, sorted(str(p.relative_to(self.home)) for p in self.home.rglob('*')))
        self.marker.write_text('fixture')
        self.marker.chmod(0o600)
        answer = self.run_cli('list', '--json')
        self.assertEqual(answer.returncode, 1)
        self.assertFalse(self.endpoint.exists())
        self.assertFalse((self.state / 'phone').exists())
        self.assertFalse((self.state / 'mail').exists())

    def test_unsafe_socket_receives_no_pairing_request(self):
        self.mock([{'code': '012345', 'expiresInSeconds': 300}], mode=0o666)
        answer = self.run_cli('pair', '--json')
        self.assertEqual(answer.returncode, 1)
        self.assertEqual(self.received, [])
        self.assertNotIn('012345', answer.stdout)

    def test_response_shape_errors_and_codes_do_not_escape(self):
        for response in [b'{"jsonrpc":"2.0","id":1,"error":{"message":"secret\\u001b[31m"}}\n',
                         b'{"jsonrpc":"2.0","id":1,"result":{"code":"012345","expiresInSeconds":300}}',
                         {'code': '\x1b[31m', 'expiresInSeconds': 300},
                         {'code': '012345', 'expiresInSeconds': 999}]:
            with self.subTest(response=response):
                self.mock([response])
                answer = self.run_cli('pair', '--json')
                self.threads[-1].join(timeout=3)
                self.listeners[-1].close()
                self.endpoint.unlink()
                self.assertEqual(answer.returncode, 1)
                self.assertFalse(json.loads(answer.stdout)['ok'])
                self.assertNotIn('secret', answer.stdout + answer.stderr)
                self.assertNotIn('\x1b', answer.stdout + answer.stderr)

    def test_real_owner_list_preview_revoke_and_missing_device(self):
        phone = self.state / 'phone'
        phone.mkdir(mode=0o700)
        device_id = 'a' * 64
        other_id = 'b' * 64
        devices = {device_id: {'name': 'Test\x1b[31m\nPhone', 'accounts': [], 'notifications': False, 'created': 1},
                   other_id: {'name': 'Keep this phone', 'accounts': [], 'notifications': False, 'created': 1}}
        registry = phone / 'devices.json'
        registry.write_text(json.dumps(devices))
        registry.chmod(0o600)
        self.daemon = subprocess.Popen([str(BINARY), 'daemon'], env=self.env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 10
        while not self.endpoint.exists():
            self.assertIsNone(self.daemon.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.02)
        answer = self.run_cli('list')
        self.assertEqual(answer.returncode, 0, answer.stderr)
        self.assertNotIn('\x1b', answer.stdout)
        self.assertIn('Test\\u{1b}[31m\\nPhone', answer.stdout)
        self.assertIn(device_id, answer.stdout)
        self.assertIn(other_id, answer.stdout)
        before = registry.read_bytes()
        answer = self.run_cli('disconnect', device_id, '--json')
        self.assertEqual(answer.returncode, 0, answer.stderr)
        self.assertTrue(json.loads(answer.stdout)['result']['preview'])
        self.assertEqual(registry.read_bytes(), before)
        answer = self.run_cli('disconnect', device_id, '--execute', '--json')
        self.assertEqual(answer.returncode, 0, answer.stderr)
        self.assertTrue(json.loads(answer.stdout)['result']['revoked'])
        self.assertEqual(json.loads(registry.read_bytes()), {other_id: devices[other_id]})
        answer = self.run_cli('disconnect', device_id, '--execute', '--json')
        self.assertEqual(answer.returncode, 1)
        self.assertEqual(json.loads(answer.stdout)['error']['code'], 'phone_device_not_found')
        self.assertEqual(json.loads(registry.read_bytes()), {other_id: devices[other_id]})
        answer = self.run_cli('pair', '--json')
        self.assertEqual(answer.returncode, 1)
        self.assertEqual(json.loads(answer.stdout)['error']['code'], 'phone_service_unavailable')
        self.assertIsNone(self.daemon.poll())

    def test_invalid_id_is_refused_before_contacting_engine(self):
        self.mock([{}])
        answer = self.run_cli('disconnect', '../../devices.json', '--execute')
        self.assertEqual(answer.returncode, 2)
        self.assertEqual(self.received, [])


if __name__ == '__main__':
    unittest.main()

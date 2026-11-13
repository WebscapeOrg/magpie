#!/usr/bin/env python3
"""Private config writes cannot follow a predictable temporary link or store link."""
import os
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1]/'scripts/config-store.sh'


class ConfigPaths(unittest.TestCase):
    def store_credentials(self, root, payload, **environment):
        return subprocess.run([str(SCRIPT), 'credentials.json'],
            input=payload + '\n', text=True, capture_output=True,
            env=dict(os.environ, XDG_CONFIG_HOME=str(root/'config'), **environment), timeout=5)

    def assert_private_failure(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('synthetic-private', result.stdout + result.stderr)

    def incompatible_credentials(self):
        for provider in ['imap', 'outlook', 'jmap', 'gmail-other', True, 0, [], {}]:
            yield json.dumps({'provider': provider, 'clientSecret': 'synthetic-private'})
            yield json.dumps({'accounts': [
                {'id': 'first@workspace.example', 'provider': 'gmail'},
                {'id': 'second@workspace.example', 'provider': provider,
                 'clientSecret': 'synthetic-private'}]})
            for key in ['installed', 'web']:
                yield json.dumps({key: {'provider': provider, 'clientSecret': 'synthetic-private'}})
                yield json.dumps({'accounts': [{'id': 'alice@workspace.example',
                    key: {'provider': provider, 'clientSecret': 'synthetic-private'}}]})
        yield '{"clientSecret":"synthetic-private"'
        yield '{"clientId":NaN}'
        yield '[]'
        yield 'null'

    def test_incompatible_incoming_credentials_cannot_create_directories_or_files(self):
        for payload in self.incompatible_credentials():
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.assert_private_failure(self.store_credentials(root, payload))
                self.assertEqual(list(root.iterdir()), [])

    def test_incompatible_stored_credentials_cannot_be_replaced_or_chmodded(self):
        for payload in [*self.incompatible_credentials(), '']:
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                config = root/'config/omamail'
                config.mkdir(parents=True)
                config.chmod(0o751)
                target = config/'credentials.json'
                original = (payload + '\n').encode()
                target.write_bytes(original)
                target.chmod(0o640)
                result = self.store_credentials(root, '{"clientSecret":"synthetic-private"}')
                self.assert_private_failure(result)
                self.assertEqual(target.read_bytes(), original)
                self.assertEqual(target.stat().st_mode & 0o777, 0o640)
                self.assertEqual(config.stat().st_mode & 0o777, 0o751)
                self.assertEqual(list(config.iterdir()), [target])

    def test_incompatible_incoming_credentials_cannot_touch_supported_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root/'config/omamail'
            config.mkdir(parents=True)
            target = config/'credentials.json'
            original = b'{"installed":{"client_id":"keep","client_secret":"synthetic-private"}}\n'
            target.write_bytes(original)
            target.chmod(0o640)
            commands = root/'commands'
            commands.mkdir()
            calls = root/'calls'
            for name in ['mkdir', 'chmod', 'mktemp', 'mv']:
                command = commands/name
                command.write_text('#!/bin/sh\nprintf called >> "$CONFIG_TEST_CALLS"\nexit 90\n')
                command.chmod(0o700)
            for payload in self.incompatible_credentials():
                self.assert_private_failure(self.store_credentials(root, payload,
                    PATH=str(commands) + os.pathsep + os.environ['PATH'], CONFIG_TEST_CALLS=str(calls)))
                self.assertFalse(calls.exists())
                self.assertEqual(target.read_bytes(), original)
                self.assertEqual(target.stat().st_mode & 0o777, 0o640)
                self.assertEqual(list(config.iterdir()), [target])

    def test_stale_writer_checks_disk_after_its_input_arrives(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root/'config/omamail'
            config.mkdir(parents=True)
            target = config/'credentials.json'
            target.write_text('{"installed":{"client_id":"old"}}\n')
            process = subprocess.Popen(['sh', '-c', 'printf "ready\\n"; exec "$1" credentials.json',
                                        'test-config-store', str(SCRIPT)],
                env=dict(os.environ, XDG_CONFIG_HOME=str(root/'config')),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertEqual(process.stdout.readline(), 'ready\n')
                original = b'{"provider":"imap","clientSecret":"synthetic-private"}\n'
                target.write_bytes(original)
                target.chmod(0o640)
                stdout, stderr = process.communicate('{"installed":{"client_id":"new"}}\n', timeout=5)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(target.read_bytes(), original)
            self.assertEqual(target.stat().st_mode & 0o777, 0o640)
            self.assertEqual(list(config.iterdir()), [target])
            self.assertNotIn('synthetic-private', stdout + stderr)

    def test_oversized_credentials_cannot_create_or_mutate_files(self):
        supported = '{"clientSecret":"synthetic-private"}'
        oversized = json.dumps({'clientSecret': 'synthetic-private',
                                'padding': 'é' * (512 * 1024)}, ensure_ascii=False)
        self.assertGreater(len(oversized.encode()), 1024 * 1024)
        self.assertLess(len(oversized), 1024 * 1024)
        for stored, incoming in [(None, oversized), (supported, oversized), (oversized, supported)]:
            with self.subTest(stored_exists=stored is not None, oversized_incoming=incoming == oversized), \
                    tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                config = root/'config/omamail'
                target = config/'credentials.json'
                original = None
                if stored is not None:
                    config.mkdir(parents=True)
                    config.chmod(0o751)
                    original = (stored + '\n').encode()
                    target.write_bytes(original)
                    target.chmod(0o640)
                commands = root/'commands'
                commands.mkdir()
                calls = root/'calls'
                for name in ['mkdir', 'chmod', 'mktemp', 'mv']:
                    command = commands/name
                    command.write_text('#!/bin/sh\nprintf called >> "$CONFIG_TEST_CALLS"\nexit 90\n')
                    command.chmod(0o700)
                result = self.store_credentials(root, incoming,
                    PATH=str(commands) + os.pathsep + os.environ['PATH'], CONFIG_TEST_CALLS=str(calls))
                self.assert_private_failure(result)
                self.assertEqual(result.returncode, 6)
                self.assertFalse(calls.exists())
                if original is None:
                    self.assertFalse((root/'config').exists())
                else:
                    self.assertEqual(target.read_bytes(), original)
                    self.assertEqual(target.stat().st_mode & 0o777, 0o640)
                    self.assertEqual(config.stat().st_mode & 0o777, 0o751)
                    self.assertEqual(list(config.iterdir()), [target])

    @unittest.skipIf(os.geteuid() == 0, 'root can read mode-000 files')
    def test_unreadable_stored_credentials_cannot_be_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root/'config/omamail'
            config.mkdir(parents=True)
            target = config/'credentials.json'
            original = b'{"clientSecret":"synthetic-private"}\n'
            target.write_bytes(original)
            target.chmod(0)
            try:
                result = self.store_credentials(root, '{"clientId":"replacement"}')
                self.assert_private_failure(result)
                self.assertEqual(target.stat().st_mode & 0o777, 0)
                self.assertEqual(list(config.iterdir()), [target])
            finally:
                target.chmod(0o600)
            self.assertEqual(target.read_bytes(), original)

    def test_supported_legacy_and_workspace_credentials_can_be_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            values = [
                {'installed': {'client_id': 'legacy', 'client_secret': 'synthetic-private'}},
                {'accounts': None, 'clientId': 'legacy-flat'},
                {'provider': None, 'accounts': [
                    {'id': 'alice@workspace.example', 'provider': ' GMAIL ',
                     'installed': {'client_id': 'workspace', 'client_secret': 'synthetic-private'}},
                    {'id': 'bob@another.example', 'provider': '', 'clientId': 'other'}]},
                {'provider': 'GMAIL', 'accounts': [{'id': 'alice@workspace.example', 'provider': None}]},
            ]
            for value in values:
                payload = json.dumps(value)
                result = self.store_credentials(root, payload)
                self.assertEqual(result.returncode, 0, result.stderr)
                target = root/'config/omamail/credentials.json'
                self.assertEqual(target.read_text(), payload + '\n')
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
                self.assertNotIn('synthetic-private', result.stdout + result.stderr)

    def test_validator_never_receives_credentials_in_arguments(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root/'python3'
            arguments = root/'arguments'
            executable.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CONFIG_TEST_ARGUMENTS"\n'
                                  + 'exec ' + shlex.quote(sys.executable) + ' "$@"\n')
            executable.chmod(0o700)
            result = self.store_credentials(root, '{"clientSecret":"synthetic-private"}',
                PATH=str(root) + os.pathsep + os.environ['PATH'], CONFIG_TEST_ARGUMENTS=str(arguments))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('synthetic-private', arguments.read_text() + result.stdout + result.stderr)

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

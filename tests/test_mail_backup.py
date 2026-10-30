#!/usr/bin/env python3
"""Restore an owner-coordinated export using an isolated engine and synthetic mail."""
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

if sys.platform == 'linux':
    import fcntl

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('MAGPIE_TEST_BINARY', ROOT / 'target/debug/omamail'))


@unittest.skipUnless(sys.platform == 'linux', 'Enterprise backup integration is Linux only')
class MailBackup(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='magpie-backup-')
        self.home = Path(self.temporary.name)
        self.env = {**os.environ, 'HOME': str(self.home), 'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/nonexistent-magpie-fixture'}
        for kind in ['CONFIG', 'STATE', 'CACHE', 'DATA', 'RUNTIME']:
            path = self.home / kind.lower()
            path.mkdir(mode=0o700)
            self.env['XDG_' + kind + ('_DIR' if kind == 'RUNTIME' else '_HOME')] = str(path)
        self.env['TMPDIR'] = self.env['XDG_RUNTIME_DIR']
        self.state = self.home / 'state/omamail'
        self.state.mkdir(mode=0o700)
        self.account = 'backup@example.org'
        self.key = hashlib.sha256(self.account.encode()).hexdigest()
        self.store = self.state / 'mail' / self.key
        self.store.mkdir(parents=True, mode=0o700)
        self.store.parent.chmod(0o700)
        self.resource = {'id': 'one', 'threadId': 'thread', 'labelIds': ['INBOX'],
                         'payload': {'mimeType': 'text/plain', 'body': {'data': base64.urlsafe_b64encode(b'Offline backup text').decode().rstrip('=')}}}
        payload = json.dumps(self.resource).encode()
        self.hash = hashlib.sha256(payload).hexdigest()
        self.blob = self.store / 'blobs' / self.hash[:2] / self.hash
        self.blob.parent.mkdir(parents=True, mode=0o700)
        self.blob.parent.parent.chmod(0o700)
        self.blob.write_bytes(payload)
        self.blob.chmod(0o600)
        with sqlite3.connect(self.store / 'mail.sqlite') as db:
            db.executescript((ROOT / 'src/local_mail/schema.sql').read_text())
            db.execute("INSERT INTO state VALUES('paused','true')")
            db.execute('INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                       ('one', 'thread', 1, json.dumps({'id': 'one'}), self.hash, '["INBOX"]', 'sender@example.org', '', '', 'Subject', '', 0, 1, 1))
            db.execute("INSERT INTO labels VALUES('one','INBOX')")
            db.execute("INSERT INTO labels VALUES('one','STARRED')")
            db.execute("INSERT INTO edits(ticket,id,additions,removals,before_labels,state) VALUES('pending','one','[\"STARRED\"]','[]','[\"INBOX\"]','queued')")
            db.execute("INSERT INTO search VALUES('one','Subject','sender@example.org','','','','Offline backup text')")
        self.store.joinpath('mail.sqlite').chmod(0o600)
        config = self.home / 'config/omamail'
        config.mkdir(mode=0o700)
        registry = config / 'accounts.json'
        registry.write_text(json.dumps({'version': 1, 'accounts': [{'email': self.account}]}))
        registry.chmod(0o600)
        self.process = None

    def tearDown(self):
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.temporary.cleanup()

    def export(self):
        return subprocess.run([str(BINARY), 'backup', 'export', '--json'], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def start_owner(self):
        marker = self.state / 'engine-enabled'
        marker.write_text('fixture')
        marker.chmod(0o600)
        self.process = subprocess.Popen([str(BINARY), 'daemon'], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        endpoint = self.home / 'runtime/omamail/engine/outbox.sock'
        deadline = time.monotonic() + 10
        while not endpoint.exists():
            self.assertIsNone(self.process.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.02)
        with socket.socket(socket.AF_UNIX) as stream:
            stream.settimeout(10)
            stream.connect(str(endpoint))
            stream.sendall((json.dumps({'jsonrpc': '2.0', 'id': 7, 'method': 'local.status',
                                      'params': {'accountId': self.account}}) + '\n').encode())
            with stream.makefile('rb') as reader:
                while True:
                    answer = json.loads(reader.readline())
                    if answer.get('id') == 7:
                        self.assertNotIn('error', answer)
                        break
        with (self.store / '.owner').open('rb') as lease:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def assert_restorable(self, answer):
        self.assertEqual(answer.returncode, 0, answer.stdout + answer.stderr)
        receipt = json.loads(answer.stdout)['result']
        archive = self.state / 'mail-backup.tar'
        self.assertTrue(receipt['complete'])
        self.assertEqual(receipt['sha256'], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        restored = self.home / 'restore'
        restored.mkdir(mode=0o700)
        with tarfile.open(archive) as tar:
            self.assertTrue(all(entry.isfile() and entry.mode == 0o600 for entry in tar))
            tar.extractall(restored, filter='data')
        manifest = json.loads((restored / 'manifest.json').read_text())
        account = restored / 'mail' / self.key
        self.assertEqual(manifest['accounts'][0]['databaseSha256'], hashlib.sha256((account / 'mail.sqlite').read_bytes()).hexdigest())
        with sqlite3.connect(account / 'mail.sqlite') as db:
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchall(), [('ok',)])
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])
            self.assertEqual(db.execute('SELECT ticket,state FROM edits').fetchall(), [('pending', 'queued')])
            self.assertEqual(db.execute("SELECT id FROM search WHERE search MATCH 'backup'").fetchall(), [('one',)])
            blob = db.execute('SELECT blob FROM messages').fetchone()[0]
        self.assertEqual(json.loads((account / 'blobs' / blob[:2] / blob).read_bytes()), self.resource)
        return archive.read_bytes()

    def test_live_owner_cli_export_and_failure_preservation(self):
        self.start_owner()
        previous = self.assert_restorable(self.export())
        self.blob.unlink()
        result = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)['ok'])
        self.assertEqual((self.state / 'mail-backup.tar').read_bytes(), previous)
        self.assertIsNone(self.process.poll())

    def test_offline_retained_store_export_without_account_registry(self):
        (self.home / 'config/omamail/accounts.json').unlink()
        self.assert_restorable(self.export())

    def test_activated_engine_unavailable_does_not_fall_back_or_publish(self):
        marker = self.state / 'engine-enabled'
        marker.write_text('fixture')
        marker.chmod(0o600)
        result = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state / 'mail-backup.tar').exists())
        self.assertFalse((self.store / '.owner').exists())


if __name__ == '__main__':
    unittest.main()

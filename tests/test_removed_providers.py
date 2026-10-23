#!/usr/bin/env python3
"""Verify deleted provider operations cannot reach storage, credentials or network."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

from test_search_backend import Backend, ROOT


REMOVED_METHODS = (
    'auth.clear',
    'auth.invalidate',
    'auth.store',
    'cache.querySession',
    'cache.querySessionGet',
    'hey.act',
    'hey.labels',
    'hey.list',
    'hey.loginCancel',
    'hey.loginPoll',
    'hey.loginStart',
    'hey.logout',
    'hey.probe',
    'hey.profile',
    'hey.read',
    'hey.saveDraft',
    'hey.send',
    'hey.sendAs',
    'hey.status',
    'imap.append',
    'imap.attachment',
    'imap.cancel',
    'imap.check',
    'imap.count',
    'imap.createFolder',
    'imap.deleteDraft',
    'imap.deleteFolder',
    'imap.folders',
    'imap.list',
    'imap.listContinue',
    'imap.messages',
    'imap.modify',
    'imap.renameFolder',
    'imap.request',
    'imap.saveDraft',
    'imap.send',
    'imap.trash',
    'imap.untrash',
    'jmap.attachment',
    'jmap.batchModify',
    'jmap.cancel',
    'jmap.invalidate',
    'jmap.labelCounts',
    'jmap.labels',
    'jmap.list',
    'jmap.messages',
    'jmap.modify',
    'jmap.profile',
    'jmap.read',
    'jmap.request',
    'jmap.saveDraft',
    'jmap.send',
    'jmap.sendAs',
    'jmap.session',
    'jmap.stream.close',
    'jmap.stream.open',
    'jmap.stream.poll',
    'jmap.trash',
    'jmap.untrash',
    'jmap.verify',
    'jmap.watch',
    'outlook.connectionCheck',
    'outlook.graphSend',
    'smtp.send',
)


def snapshot(root):
    return {
        str(path.relative_to(root)): (path.stat().st_mode,
                                    hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
        for path in sorted(root.rglob('*'))
    }


@unittest.skipUnless(sys.platform == 'linux' and shutil.which('bwrap') and shutil.which('strace'),
                     'Linux bubblewrap and strace are required for effect verification')
class RemovedProviders(unittest.TestCase):
    def test_removed_methods_have_no_provider_effects(self):
        contract = json.loads((ROOT / 'backend-api.json').read_text())
        self.assertFalse(set(REMOVED_METHODS) & set(contract['methods']))
        with tempfile.TemporaryDirectory(prefix='magpie-removed-providers-') as name:
            temporary = Path(name)
            env = {key: value for key, value in os.environ.items() if key in ('PATH', 'LANG', 'LC_ALL')}
            for key in ('HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_RUNTIME_DIR'):
                folder = temporary / key.lower()
                folder.mkdir(mode=0o700)
                env[key] = str(folder)
            registry = Path(env['XDG_CONFIG_HOME']) / 'omamail/accounts.json'
            registry.parent.mkdir(mode=0o700)
            registry.write_text(json.dumps({'version': 1, 'activeId': 'imap:legacy@example.test',
                                            'accounts': [{'provider': 'imap', 'email': 'legacy@example.test'}]}))
            registry.chmod(0o600)
            for key in ('HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_RUNTIME_DIR'):
                (Path(env[key]) / 'sentinel').write_text('preserve existing synthetic data')
            helpers = Path(env['HOME']) / 'bin'
            helpers.mkdir()
            marker = Path(env['HOME']) / 'forbidden-credential-access'
            for name in ('secret-tool', 'curl', 'security'):
                helper = helpers / name
                helper.write_text('#!/bin/sh\nprintf forbidden > "$HOME/forbidden-credential-access"\nexit 1\n')
                helper.chmod(0o700)
            env['PATH'] = str(helpers) + os.pathsep + env['PATH']
            env['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=' + str(temporary / 'forbidden-keyring.sock')
            roots = [Path(env[key]) for key in ('HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
                                               'XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_RUNTIME_DIR')]
            before = [snapshot(root) for root in roots]
            backend = Backend(temporary, env)
            try:
                info = backend.call('system.info', {})['result']
                self.assertEqual(set(info['methods']), set(contract['methods']))
                for method in REMOVED_METHODS:
                    for params in ({}, {'accountId': 'imap:legacy@example.test', 'execute': True,
                                        'url': 'http://127.0.0.1:9/forbidden',
                                        'path': str(marker), 'secret': 'synthetic-private-secret'}, None):
                        with self.subTest(method=method, params=params):
                            response = backend.call(method, params)
                            self.assertEqual(response['error'], {'code': -32601, 'message': 'Method not found'})
                            self.assertEqual([snapshot(root) for root in roots], before)
                self.assertFalse(marker.exists())
            finally:
                backend.close()
            trace = backend.trace.read_text()
            self.assertNotRegex(trace, r'AF_INET6?\b', 'deleted methods must not attempt network access')
            self.assertNotIn('forbidden-keyring.sock', trace, 'deleted methods must not contact the keyring')
            self.assertNotIn('synthetic-private-secret', backend.stderr)
            diagnostics = Path(env['XDG_STATE_HOME']) / 'omamail/diagnostics'
            for path in diagnostics.glob('*.json'):
                self.assertNotIn('synthetic-private-secret', path.read_text())
            self.assertFalse(marker.exists())
            self.assertEqual(registry.read_text(), json.dumps({'version': 1, 'activeId': 'imap:legacy@example.test',
                                                               'accounts': [{'provider': 'imap', 'email': 'legacy@example.test'}]}))


if __name__ == '__main__':
    unittest.main()

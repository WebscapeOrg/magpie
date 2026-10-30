#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('service', Path(__file__).resolve().parents[1]/'scripts/phone-service.py')
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.magpie-service-test-',dir=Path.home())
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for key, path in [('STATE','state/omamail'),('PHONE','state/omamail/phone'),('CONFIG','config'),('DATA','data/omamail')]:
            self.start(patch.object(service,key,self.root/path))
        self.start(patch.object(service,'runtime',return_value='/private/omamail'))
        self.start(patch.object(service,'legacy_frontend',return_value=False))
        self.calls = []
        def command(args):
            self.calls.append(args)
            return '100.100.100.100' if args[:2] == ['tailscale','ip'] else ''
        self.start(patch.object(service,'command',side_effect=command))
        def certificate():
            service.write(service.PHONE/'server.crt',b'synthetic certificate')
            service.write(service.PHONE/'server.key',b'synthetic key')
        self.start(patch.object(service,'certificate',side_effect=certificate))

    def start(self, replacement):
        self.addCleanup(replacement.stop)
        return replacement.start()

    def test_unprepared_and_changed_units_cannot_activate(self):
        with self.assertRaises((OSError,ValueError,RuntimeError)):
            service.enable()
        self.assertEqual(self.calls,[])
        self.assertFalse((service.STATE/'engine-enabled').exists())
        service.prepare()
        self.calls.clear()
        unit = service.CONFIG/'systemd/user'/service.UNIT
        unit.write_text('# Unrelated\n[Service]\nExecStart=/bin/false\n')
        with self.assertRaises(RuntimeError):
            service.enable()
        self.assertEqual(self.calls,[])
        self.assertFalse((service.STATE/'engine-enabled').exists())
        self.assertIn('Unrelated',unit.read_text())

    def test_legacy_frontend_and_unsafe_credentials_cannot_activate(self):
        service.prepare()
        self.calls.clear()
        with patch.object(service,'legacy_frontend',return_value=True):
            with self.assertRaises(RuntimeError):
                service.enable()
        self.assertEqual(self.calls,[])
        self.assertFalse((service.STATE/'engine-enabled').exists())
        key = service.PHONE/'server.key'
        key.chmod(0o644)
        with self.assertRaises(RuntimeError):
            service.enable()
        self.assertFalse((service.STATE/'engine-enabled').exists())
        key.chmod(0o600)
        link = self.root/'linked-key'
        os.link(key,link)
        with self.assertRaises(RuntimeError):
            service.enable()
        self.assertEqual(link.read_bytes(),b'synthetic key')
        self.assertEqual(self.calls,[])

    def test_prepared_service_retains_data_and_enables_only_owned_units(self):
        service.prepare()
        self.calls.clear()
        service.enable()
        marker = service.STATE/'engine-enabled'
        self.assertEqual(marker.read_bytes(),b'1\n')
        self.assertEqual(marker.stat().st_mode & 0o777,0o600)
        self.assertEqual(self.calls,[['systemctl','--user','enable','--now','magpie-engine.service','magpie-certificate.timer']])
        unit = (service.CONFIG/'systemd/user'/service.UNIT).read_text()
        self.assertIn('KillMode=control-group',unit)
        self.assertIn('Environment=MAGPIE_WORKER_SERVICES=1',unit)
        self.assertEqual(json.loads((service.PHONE/'server.json').read_bytes()),{'listen':'100.100.100.100:3450','host':'enterprise.tail615f0b.ts.net:3450'})

    def test_certificate_install_cannot_start_or_prepare_mail_engine(self):
        with patch.object(service,'runtime',side_effect=AssertionError('No mail runtime during certificate setup')):
            service.install_certificate()
        self.assertFalse((service.STATE/'engine-enabled').exists())
        self.assertFalse((service.PHONE/'server.json').exists())
        self.assertFalse((service.CONFIG/'systemd/user'/service.UNIT).exists())
        self.assertEqual(self.calls,[['systemctl','--user','daemon-reload'],['systemctl','--user','enable','--now','magpie-certificate.timer']])
        self.assertEqual((service.DATA/'phone-service.py').stat().st_mode & 0o777,0o700)

    def test_certificate_install_preserves_unrelated_timer(self):
        timer=service.CONFIG/'systemd/user/magpie-certificate.timer'
        service.write(timer,b'# another owner\n')
        with self.assertRaises(RuntimeError): service.install_certificate()
        self.assertEqual(timer.read_bytes(),b'# another owner\n')
        self.assertEqual(self.calls,[])
        self.assertFalse((service.STATE/'engine-enabled').exists())

    def test_service_path_cannot_retain_or_execute_session_tools(self):
        tool = self.root / 'magpie-test-session-tool'
        touched = self.root / 'session-tool-ran'
        tool.write_text('#!/bin/sh\nprintf executed > ' + shlex.quote(str(touched)) + '\n')
        tool.chmod(0o700)
        subprocess.run([str(tool)], env={'PATH': str(self.root)}, check=True, timeout=5)
        self.assertEqual(touched.read_text(), 'executed')
        touched.unlink()
        with patch.dict(os.environ, PATH=str(self.root) + ':/old/mise/installs/claude/1.0'):
            service.prepare()
        paths = []
        for name in [service.UNIT, 'magpie-certificate.service']:
            text = (service.CONFIG/'systemd/user'/name).read_text()
            value = next(line.removeprefix('Environment=') for line in text.splitlines()
                         if line.startswith('Environment="PATH='))
            path = shlex.split(value)[0].removeprefix('PATH=')
            paths.append(path)
            self.assertEqual(path.split(os.pathsep), [str(Path.home()/'.local/share/mise/shims'),
                             str(Path.home()/'.local/bin'), '/usr/local/bin', '/usr/bin'])
            result = subprocess.run(['/bin/sh', '-c', 'exec magpie-test-session-tool'],
                                    env={'PATH': path}, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 127)
            self.assertFalse(touched.exists())
        self.assertEqual(paths[0], paths[1])
        before = (service.CONFIG/'systemd/user'/service.UNIT).read_bytes()
        with patch.dict(os.environ, PATH='/another/session:/new/mise/installs/claude/2.0'):
            service.prepare()
        self.assertEqual((service.CONFIG/'systemd/user'/service.UNIT).read_bytes(), before)


if __name__ == '__main__':
    unittest.main()

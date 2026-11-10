#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('service', Path(__file__).resolve().parents[1]/'scripts/phone-service.py')
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)
RUNTIME = service.runtime
CERTIFICATE = service.certificate
NAME = 'service.example-tailnet.ts.net'
LONG_LABEL = 'a'*64 + '.example-tailnet.ts.net'
LONG_NAME = '.'.join(['a'*63]*3 + ['b'*62])


def status(name=NAME + '.', domains=(NAME,)):
    return json.dumps({'Self':{'DNSName':name},'CertDomains':list(domains) if domains is not None else None})


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
            return ''
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
        self.assertEqual(self.calls,[['systemctl','--user','enable','--now','magpie-mail-engine.service','magpie-mail-certificate.timer']])
        unit = (service.CONFIG/'systemd/user'/service.UNIT).read_text()
        self.assertIn('KillMode=control-group',unit)
        self.assertIn('Environment=MAGPIE_WORKER_SERVICES=1',unit)
        self.assertFalse((service.PHONE/'server.json').exists(),'the engine no longer listens for phones')

    def test_certificate_install_cannot_start_or_prepare_mail_engine(self):
        with patch.object(service,'runtime',side_effect=AssertionError('No mail runtime during certificate setup')):
            service.install_certificate()
        self.assertFalse((service.STATE/'engine-enabled').exists())
        self.assertFalse((service.PHONE/'server.json').exists())
        self.assertFalse((service.CONFIG/'systemd/user'/service.UNIT).exists())
        self.assertEqual(self.calls,[['systemctl','--user','daemon-reload'],['systemctl','--user','enable','--now','magpie-mail-certificate.timer']])
        self.assertEqual((service.DATA/'phone-service.py').stat().st_mode & 0o777,0o700)

    def test_rename_units_moves_an_enabled_engine_to_the_new_names(self):
        units = service.CONFIG/'systemd/user'
        units.mkdir(parents=True)
        for name in service.OLD_UNITS:
            (units/name).write_text('# Managed by Magpie\n[Service]\n')
        service.write(service.STATE/'engine-enabled',b'1\n')
        self.assertTrue(service.rename_units())
        self.assertEqual([name for name in service.OLD_UNITS if (units/name).exists()],[])
        for name in [service.UNIT,service.CERTIFICATE,service.TIMER]:
            self.assertTrue((units/name).read_text().startswith('# Managed by Magpie\n'),name)
        self.assertIn('RuntimeDirectory=magpie-mail-engine',(units/service.UNIT).read_text())
        self.assertEqual(self.calls[-3:],[['systemctl','--user','disable','--now','magpie-engine.service','magpie-certificate.timer'],
                                          ['systemctl','--user','daemon-reload'],
                                          ['systemctl','--user','enable','--now','magpie-mail-engine.service','magpie-mail-certificate.timer']])
        self.calls.clear()
        self.assertFalse(service.rename_units(),'running it again changes nothing')
        self.assertEqual(self.calls,[])

    def test_rename_units_recovers_from_partial_failure(self):
        units = service.CONFIG/'systemd/user'
        units.mkdir(parents=True)
        # Case 1: only magpie-certificate.service remains, engine-enabled is set
        (units/'magpie-certificate.service').write_text('# Managed by Magpie\n[Service]\n')
        service.write(service.STATE/'engine-enabled',b'1\n')
        self.assertTrue(service.rename_units())
        self.assertFalse((units/'magpie-certificate.service').exists())
        self.assertTrue((units/service.UNIT).exists())
        self.assertTrue((units/service.TIMER).exists())
        # Disable was not called with empty arguments; daemon-reload and enable were called
        self.assertEqual(self.calls,[['systemctl','--user','daemon-reload'],
                                     ['systemctl','--user','daemon-reload'],
                                     ['systemctl','--user','enable','--now','magpie-mail-engine.service','magpie-mail-certificate.timer']])
        # Case 2: all old units removed, new units removed, rename_units prepares and enables again
        for name in [service.UNIT, service.CERTIFICATE, service.TIMER]:
            (units/name).unlink()
        self.calls.clear()
        self.assertTrue(service.rename_units())
        self.assertTrue((units/service.UNIT).exists())
        self.assertTrue((units/service.TIMER).exists())
        self.calls.clear()
        self.assertFalse(service.rename_units())

    def test_rename_units_without_the_engine_keeps_it_off_and_refuses_unrelated_units(self):
        units = service.CONFIG/'systemd/user'
        units.mkdir(parents=True)
        (units/'magpie-certificate.timer').write_text('# Managed by Magpie\n[Timer]\n')
        with patch.object(service,'runtime',side_effect=AssertionError('no engine to prepare')):
            self.assertTrue(service.rename_units())
        self.assertFalse((units/service.UNIT).exists())
        self.assertEqual(self.calls[-1],['systemctl','--user','enable','--now','magpie-mail-certificate.timer'])
        (units/'magpie-engine.service').write_text('# Someone else\n[Service]\n')
        self.calls.clear()
        with self.assertRaises(RuntimeError):
            service.rename_units()
        self.assertEqual(self.calls,[])
        self.assertTrue((units/'magpie-engine.service').exists())

    def test_certificate_renewal_restarts_only_the_installation_page(self):
        units = service.CONFIG/'systemd/user'
        units.mkdir(parents=True)
        for name in [service.UNIT,'magpie-mail-ota.service']:
            (units/name).write_text('[Service]\n')
        with patch.object(service,'certificate',return_value=True), patch('sys.argv',['phone-service.py','certificate']):
            service.main()
        self.assertEqual(self.calls,[['systemctl','--user','try-restart','magpie-mail-ota.service']])
        self.calls.clear()
        with patch.object(service,'certificate',return_value=False), patch('sys.argv',['phone-service.py','certificate']):
            service.main()
        self.assertEqual(self.calls,[],'an unchanged certificate restarts nothing')

    def test_runtime_refuses_builds_that_still_serve_phones(self):
        executable = str(service.DATA/'bin/omamail')
        manager = type('Manager',(),{'run':staticmethod(lambda action: {'state':'ready','executable':executable})})
        loader = type('Loader',(),{'exec_module':staticmethod(lambda module: None)})
        current = {'apiVersion':8,'engineService':False,'methods':['system.info','inbox.list']}
        cases = [
            ({**current,'methods':['system.info','phone.pairBegin']},False),
            ({k:v for k,v in current.items() if k != 'engineService'},False),
            ({**current,'apiVersion':7},False),
            ({**current,'methods':None},False),
            (current,True),
        ]
        for info, accepted in cases:
            with self.subTest(info=info), \
                    patch('importlib.util.spec_from_file_location',return_value=type('Spec',(),{'loader':loader})()), \
                    patch('importlib.util.module_from_spec',return_value=manager), \
                    patch.object(service,'command',return_value=json.dumps(info)):
                if accepted:
                    self.assertEqual(RUNTIME(),executable)
                else:
                    with self.assertRaises(RuntimeError):
                        RUNTIME()

    def test_engine_unit_requires_activation_and_no_pending_uninstall(self):
        service.prepare()
        unit = (service.CONFIG/'systemd/user'/service.UNIT).read_text()
        conditions = [line.split('=', 1)[1] for line in unit.splitlines()
                      if line.startswith('ConditionPathExists=')]
        self.assertEqual(conditions, [str(service.STATE/'engine-enabled'), '!' + str(service.STATE/'engine-uninstalling')])

    def test_condition_paths_preserve_spaces_escape_specifiers_and_refuse_newlines(self):
        self.assertEqual(service.condition_path(Path('/private/state with space % name/engine-enabled')),
                         '/private/state with space %% name/engine-enabled')
        for path in ['/private/state\nRestart=always', '/private/state\rRestart=always', '/private/state\0marker']:
            with self.assertRaises(RuntimeError):
                service.condition_path(path)

    @unittest.skipUnless(shutil.which('systemd-analyze'), 'systemd parser unavailable')
    def test_systemd_enforces_generated_conditions_with_spaces_and_percent_in_paths(self):
        with patch.object(service, 'STATE', self.root/'state with space % marker'):
            service.STATE.mkdir(mode=0o700)
            service.prepare()
            marker = service.STATE/'engine-enabled'
            pending = service.STATE/'engine-uninstalling'
            unit_path = service.CONFIG/'systemd/user'
            for activated, uninstalling, allowed in [(False, False, False), (True, False, True),
                                                     (True, True, False), (False, True, False)]:
                with self.subTest(activated=activated, uninstalling=uninstalling):
                    for path, exists in [(marker, activated), (pending, uninstalling)]:
                        if exists:
                            service.write(path, b'1\n')
                        else:
                            path.unlink(missing_ok=True)
                    result = subprocess.run(['systemd-analyze', '--user', '--unit='+service.UNIT, 'condition'],
                                            env={**os.environ, 'SYSTEMD_UNIT_PATH': str(unit_path)},
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0 if allowed else 1, result.stderr)
                    self.assertNotIn('ignoring', result.stderr.lower())
                    self.assertIn('Conditions succeeded.' if allowed else 'Conditions failed.', result.stderr)

    def test_unfinished_uninstall_cannot_be_reactivated(self):
        service.prepare()
        pending = service.STATE/'engine-uninstalling'
        service.write(pending,b'1\n')
        self.calls.clear()
        with self.assertRaisesRegex(RuntimeError,'Finish uninstalling'):
            service.enable()
        self.assertFalse((service.STATE/'engine-enabled').exists())
        self.assertEqual(pending.read_bytes(),b'1\n')
        self.assertEqual(self.calls,[])

    def test_certificate_install_preserves_unrelated_timer(self):
        timer=service.CONFIG/'systemd/user/magpie-mail-certificate.timer'
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
        for name in [service.UNIT, 'magpie-mail-certificate.service']:
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

    def answer(self, reply):
        def command(args):
            self.calls.append(args)
            if args[:2] == ['tailscale','cert']:
                Path(args[3]).write_bytes(b'synthetic certificate')
                Path(args[5]).write_bytes(b'synthetic key')
                return ''
            return reply
        return patch.object(service,'command',side_effect=command)

    def test_the_certificate_is_issued_for_the_name_tailscale_reports(self):
        with self.answer(status()):
            self.assertEqual(service.host(),NAME)
            self.assertEqual(self.calls,[['tailscale','status','--json']])
            self.calls.clear()
            self.assertTrue(CERTIFICATE())
        self.assertEqual(self.calls[0],['tailscale','status','--json'])
        self.assertEqual(self.calls[1][:2],['tailscale','cert'])
        self.assertEqual(self.calls[1][-1],NAME)
        self.assertEqual(len(self.calls),2)
        self.assertEqual((service.PHONE/'server.crt').read_bytes(),b'synthetic certificate')
        self.assertEqual((service.PHONE/'server.key').stat().st_mode & 0o777,0o600)

    def test_names_at_the_dns_limits_are_accepted(self):
        for name in ['a'*63 + '.example-tailnet.ts.net', '.'.join(['a'*63]*3 + ['b'*61])]:
            with self.subTest(len(name)), self.answer(status(name + '.',[name])):
                self.assertEqual(service.host(),name)

    def test_an_unusable_tailscale_answer_issues_no_certificate(self):
        answers = {
            'not JSON': 'tailscale is stopped',
            'a list': '[]',
            'no Self': json.dumps({'CertDomains':[NAME]}),
            'a number for the name': json.dumps({'Self':{'DNSName':7},'CertDomains':[NAME]}),
            'an option for a name': status('-x.example-tailnet.ts.net.',['-x.example-tailnet.ts.net']),
            'a name with a space': status(NAME + ' --x.',[NAME + ' --x']),
            'a name with a newline': status(NAME + '\n.',[NAME + '\n']),
            'a bare word': status('service.',['service']),
            'capitals': status('Service.example-tailnet.ts.net.',['Service.example-tailnet.ts.net']),
            'no certificate names': status(domains=()),
            'certificates off': status(domains=None),
            'another machine\'s certificate': status(domains=('other.example-tailnet.ts.net',)),
            'names as one string': json.dumps({'Self':{'DNSName':NAME + '.'},'CertDomains':'x ' + NAME}),
            'a space inside a label': status('ent erprise.example-tailnet.ts.net.',['ent erprise.example-tailnet.ts.net']),
            'no certificate names listed': json.dumps({'Self':{'DNSName':NAME + '.'}}),
            'a label over 63 characters': status(LONG_LABEL + '.',[LONG_LABEL]),
            'a name over 253 characters': status(LONG_NAME + '.',[LONG_NAME]),
        }
        for case, reply in answers.items():
            with self.subTest(case), self.answer(reply):
                self.calls.clear()
                with self.assertRaises(RuntimeError):
                    CERTIFICATE()
                self.assertEqual(self.calls,[['tailscale','status','--json']])
                self.assertFalse((service.PHONE/'server.crt').exists())


if __name__ == '__main__':
    unittest.main()

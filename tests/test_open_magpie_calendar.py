#!/usr/bin/env python3
"""Verify the calendar opener against a fake Omarchy shell.

PATH holds only the fake, so no test can reach the real shell. The fake answers each summon from a
list the test gives it, as the shell answers `ok` for a plugin it has and `unknown` for one it lacks.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
NOT_OPENED = 'Magpie Calendar could not open. Check that Magpie Calendar is installed and the desktop is unlocked.'
REQUEST = {'version': 1, 'kind': 'invitation', 'accountId': 'gmail:reader@example.com', 'uid': 'meeting-7'}

FAKE_SHELL = r'''
import json, os, sys
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\n')
answers = os.environ['FAKE_ANSWERS'].split(',')
with open(os.environ['FAKE_LOG']) as log:
    turn = len(log.read().splitlines()) - 1
answer = answers[min(turn, len(answers) - 1)]
if answer == 'hang':
    import time
    time.sleep(60)
if answer == 'down':
    print('omarchy-shell is not running', file=sys.stderr)
    sys.exit(1)
print(answer)
'''


def handoff_link(scheme, request):
    return f'{scheme}://handoff?data=' + base64.b64encode(json.dumps(request).encode()).decode()


class CalendarOpener(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='magpie-calendar-opener-')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.bin = root / 'bin'
        self.bin.mkdir()
        shell = self.bin / 'omarchy-shell'
        shell.write_text(f'#!{sys.executable}\n' + textwrap.dedent(FAKE_SHELL))
        shell.chmod(0o755)
        self.log = root / 'log'
        self.log.write_text('')
        self.data = root / 'data'
        self.data.mkdir()

    def run_opener(self, *arguments, answers='ok'):
        environment = {'PATH': str(self.bin), 'XDG_DATA_HOME': str(self.data),
                       'FAKE_LOG': str(self.log), 'FAKE_ANSWERS': answers}
        return subprocess.run([sys.executable, '-I', str(ROOT / 'scripts/open-magpie-calendar.py'), *arguments],
                              env=environment, capture_output=True, text=True, timeout=30)

    def summons(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_an_installed_calendar_opener_receives_the_same_handoff(self):
        native = self.data / 'magpie-calendar/open-magpie-calendar.py'
        native.parent.mkdir()
        native.write_text('import json, os, sys\n'
                          'with open(os.environ["FAKE_LOG"], "a") as log:\n'
                          '    log.write(json.dumps(sys.argv[1:]) + "\\n")\n')
        result = self.run_opener(json.dumps(REQUEST))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.summons(), [[json.dumps({'handoff': REQUEST})]])

    def test_the_calendar_is_summoned_by_its_name_when_no_installed_opener_exists(self):
        result = self.run_opener()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.summons(), [['shell', 'summon', 'magpie-calendar', '{}']])

    def test_a_calendar_installed_before_the_rename_is_summoned_by_its_old_name(self):
        result = self.run_opener(json.dumps(REQUEST), answers='unknown,ok')
        self.assertEqual(result.returncode, 0, result.stderr)
        message = json.dumps({'handoff': REQUEST})
        self.assertEqual(self.summons(), [['shell', 'summon', 'magpie-calendar', message],
                                          ['shell', 'summon', 'skylark', message]])

    def test_no_calendar_at_all_is_said(self):
        result = self.run_opener(answers='unknown,unknown')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), NOT_OPENED)
        self.assertEqual(len(self.summons()), 2)

    def test_a_shell_that_does_not_answer_is_not_asked_for_the_old_name(self):
        for answers in ('down', 'Not ready', ''):
            with self.subTest(answers=answers):
                self.log.write_text('')
                result = self.run_opener(answers=answers)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr.strip(), NOT_OPENED)
                self.assertEqual(self.summons(), [['shell', 'summon', 'magpie-calendar', '{}']])

    def test_a_shell_that_fails_on_the_old_name_is_not_taken_for_an_open_calendar(self):
        for answers in ('unknown,down', 'unknown,Not ready', 'unknown,'):
            with self.subTest(answers=answers):
                self.log.write_text('')
                result = self.run_opener(answers=answers)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr.strip(), NOT_OPENED)
                self.assertEqual([call[2] for call in self.summons()], ['magpie-calendar', 'skylark'])

    def test_a_shell_that_hangs_is_given_up_on(self):
        began = time.monotonic()
        result = self.run_opener(answers='hang')
        self.assertLess(time.monotonic() - began, 25)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), NOT_OPENED)
        self.assertEqual(len(self.summons()), 1)

    def test_a_request_with_non_ascii_text_reaches_the_calendar_whole(self):
        request = {**REQUEST, 'title': 'Café \u2014 planning \U0001f426'}
        result = self.run_opener(json.dumps(request, ensure_ascii=False))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.summons()[0][3]), {'handoff': request})

    def test_both_link_schemes_open_the_calendar(self):
        for scheme in ('magpiecalendar', 'skylark'):
            for link, sent in ((f'{scheme}://calendar', {}), (f'{scheme}://calendar/', {}),
                               (handoff_link(scheme, REQUEST), {'handoff': REQUEST})):
                with self.subTest(link=link[:40]):
                    self.log.write_text('')
                    result = self.run_opener(link)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.summons(), [['shell', 'summon', 'magpie-calendar', json.dumps(sent)]])

    def test_links_and_requests_the_calendar_does_not_take_are_refused_before_the_shell(self):
        for value in ('magpiecalendar://elsewhere', 'magpiecalendar://calendar?x=1', 'magpiecalendar://calendar#x',
                      'magpiecalendar://user@calendar', 'magpiecalendar://calendar:80', 'skylark://handoff/x',
                      'magpiecalendar://handoff?data=not-base64!', 'magpiecalendar://handoff?other=1',
                      handoff_link('magpiecalendar', {**REQUEST, 'kind': 'send'}),
                      handoff_link('magpiecalendar', {**REQUEST, 'accountId': ''}),
                      json.dumps({**REQUEST, 'version': True}), json.dumps({**REQUEST, 'accountId': 'a\nb'}),
                      '[]', 'not json', '[' * 100000,
                      json.dumps({**REQUEST, 'padding': 'x' * 100000}),
                      handoff_link('magpiecalendar', {**REQUEST, 'padding': 'x' * 50000}),
                      '{"version": 1, "kind": "invitation", "accountId": "a", "start": NaN}',
                      handoff_link('skylark', {**REQUEST, 'start': float('inf')})):
            with self.subTest(value=value[:40]):
                self.log.write_text('')
                result = self.run_opener(value)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr.strip(), NOT_OPENED)
                self.assertEqual(self.summons(), [])

    def test_one_link_at_a_time(self):
        result = self.run_opener('{}', '{}')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.summons(), [])


if __name__ == '__main__':
    unittest.main(verbosity=1)

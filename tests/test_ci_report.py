#!/usr/bin/env python3
"""Exercise CI comment routing with untrusted artifacts and a local gh stub."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ReportRoutingTests(unittest.TestCase):
    def run_report(self, resolved_pr):
        workflow = (ROOT / '.github/workflows/ci-report.yml').read_text()
        script = textwrap.dedent(workflow.rsplit('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            notes = directory / 'notes/ci-report-fork'
            notes.mkdir(parents=True)
            (notes / 'pr.txt').write_text('999\nforged-revision\n')
            (notes / 'failure.md').write_text('Synthetic failure\n')
            stub = directory / 'gh'
            stub.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['GH_CALLS'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['pr', 'list']:
    print(os.environ['RESOLVED_PR'])
''')
            stub.chmod(0o700)
            log = directory / 'calls.jsonl'
            environment = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                               GH_CALLS=str(log), RESOLVED_PR=resolved_pr,
                               GITHUB_REPOSITORY='owner/repository', HEAD_REPO='fork/repository',
                               HEAD_BRANCH='feature', HEAD_SHA='a' * 40,
                               RUN_URL='https://example.test/run/1', CONCLUSION='failure')
            result = subprocess.run(['bash', '-c', script], cwd=directory, env=environment,
                                    capture_output=True, text=True, timeout=10)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    def test_artifact_cannot_choose_the_comment_destination(self):
        result, calls = self.run_report('17')
        self.assertEqual(result.returncode, 0, result.stderr)
        endpoints = [argument for call in calls for argument in call if '/issues/' in argument]
        self.assertTrue(endpoints)
        self.assertEqual(set(endpoints), {'repos/owner/repository/issues/17/comments'})
        self.assertTrue(any(call[:2] == ['pr', 'list'] and 'headRefOid' in ' '.join(call) for call in calls))

    def test_missing_trusted_pull_request_cannot_post(self):
        result, calls = self.run_report('')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any('--method' in call for call in calls))

    def test_malformed_pull_request_number_cannot_post(self):
        result, calls = self.run_report('../../other')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('--method' in call for call in calls))


if __name__ == '__main__':
    unittest.main()

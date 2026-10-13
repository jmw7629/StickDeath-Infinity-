"""Exercise the real readiness gate; subprocesses mocked, no native PASS claim."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2] / 'scripts/native-smoke'
sys.path.insert(0, str(ROOT))
import seed_image_fixture as seed
from seed_diagnostics import Result

ID = '00000000-0000-4000-8000-000000000001'


class Readiness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.output = self.root / 'evidence'
        self.output.mkdir()
        self.environment = patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'RUNNER_TEMP': str(self.root)})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.tmp.cleanup()

    def test_one_explicit_readonly_probe_preserves_bounded_budget_and_redacts_output(self):
        raw = b'private-path private-token admin@example.test connection Code=123'
        with patch.object(seed.time, 'monotonic', return_value=10), patch.object(seed, 'run_bounded', return_value=Result(0, False, 0.1, stdout=raw, stdout_seen=len(raw))) as run:
            seed.wait_for_command_readiness(ID, self.output)
        run.assert_called_once_with(['xcrun', 'simctl', 'spawn', ID, 'launchctl', 'list'], 131, work_deadline=130)
        text = (self.output / 'image-seed-readiness.json').read_text()
        for value in ('private-path', 'private-token', 'admin@example.test'):
            self.assertNotIn(value, text)
        report = json.loads(text)
        self.assertTrue(report['readOnly'])
        self.assertEqual(report['attempts'], 1)
        self.assertEqual(report['result']['stdout']['numericErrorCodes'], ['123'])
        self.assertFalse((self.output / 'image-fixture.json').exists())

    def test_timeout_preserves_its_actual_stage_and_never_imports(self):
        with patch.object(seed, 'run_bounded', return_value=Result(-9, True, 120)) as run:
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                seed.wait_for_command_readiness(ID, self.output)
        self.assertEqual(caught.exception.timeout, 120)
        self.assertEqual(run.call_count, 1)
        self.assertNotIn('addmedia', caught.exception.cmd)
        self.assertTrue(json.loads((self.output / 'image-seed-readiness.json').read_text())['result']['timedOut'])
        self.assertFalse((self.output / 'image-fixture.json').exists())

    def test_nonzero_exit_is_never_readiness_success(self):
        with patch.object(seed, 'run_bounded', return_value=Result(7, False, 0.1)) as run:
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                seed.wait_for_command_readiness(ID, self.output)
        self.assertEqual(caught.exception.returncode, 7)
        self.assertEqual(run.call_count, 1)

    def test_existing_report_is_preserved(self):
        report = self.output / 'image-seed-readiness.json'
        report.write_text('original report')
        with patch.object(seed, 'run_bounded', return_value=Result(0, False, 0.1)):
            with self.assertRaises(FileExistsError):
                seed.wait_for_command_readiness(ID, self.output)
        self.assertEqual(report.read_text(), 'original report')

    def test_alias_device_and_nonci_environment_never_spawn(self):
        with patch.object(seed, 'run_bounded') as run:
            with self.assertRaises(ValueError):
                seed.wait_for_command_readiness('booted', self.output)
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}):
                with self.assertRaises(ValueError):
                    seed.wait_for_command_readiness(ID, self.output)
            run.assert_not_called()

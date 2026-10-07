"""Check seed guards/failure propagation; subprocess doubles are not iOS evidence."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/native-smoke'))
import seed_video_fixture as seed

ID = '00000000-0000-4000-8000-000000000001'

class VideoSeed(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.output = self.root / 'evidence'; self.output.mkdir()
        self.env = patch.dict(os.environ, GITHUB_ACTIONS='true', RUNNER_TEMP=str(self.root)); self.env.start()
        self.calls = []
    def tearDown(self):
        self.env.stop(); self.temp.cleanup()
    def run_command(self, command, **kwargs):
        self.calls.append(command)
        if len(command) == 2:
            Path(command[1]).write_bytes(b'only a subprocess test double; actual generator tested separately')
        return subprocess.CompletedProcess(command, 0)
    def test_success_has_one_explicit_seed_after_generation_and_never_overwrites(self):
        with patch.object(seed.subprocess, 'run', side_effect=self.run_command):
            seed.seed_video_fixture(ID, self.output)
            with self.assertRaises(FileExistsError): seed.seed_video_fixture(ID, self.output)
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(self.calls[2][:4], ['xcrun', 'simctl', 'addmedia', ID])
        report = json.loads((self.output / 'video-fixture/result.json').read_text())
        self.assertEqual(report['status'], 'passed'); self.assertEqual(report['attempts'], 1)
        self.assertEqual(len(report['sha256']), 64)
        self.assertEqual([entry['timeoutSeconds'] for entry in report['stages']], [180, 45, 120])
    def test_failed_generation_never_calls_addmedia_and_preserves_original_status(self):
        def run(command, **kwargs):
            if len(command) == 2: return subprocess.CompletedProcess(command, 65)
            return self.run_command(command, **kwargs)
        with patch.object(seed.subprocess, 'run', side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError): seed.seed_video_fixture(ID, self.output)
        self.assertFalse(any(c[:3] == ['xcrun', 'simctl', 'addmedia'] for c in self.calls))
        report = json.loads((self.output / 'video-fixture/result.json').read_text())
        self.assertEqual(report['status'], 'failed'); self.assertEqual(report['stages'][-1]['exitCode'], 65)
    def test_timeout_is_not_retried_or_marked_seeded(self):
        with patch.object(seed.subprocess, 'run', side_effect=subprocess.TimeoutExpired('compile', 180)) as run:
            with self.assertRaises(subprocess.TimeoutExpired): seed.seed_video_fixture(ID, self.output)
        self.assertEqual(run.call_count, 1)
        report = json.loads((self.output / 'video-fixture/result.json').read_text())
        self.assertEqual(report['status'], 'failed'); self.assertEqual(report['failureClass'], 'TimeoutExpired')
    def test_environment_identity_and_output_guards_prevent_any_command(self):
        with patch.object(seed.subprocess, 'run') as run:
            with patch.dict(os.environ, GITHUB_ACTIONS='false'):
                with self.assertRaises(ValueError): seed.seed_video_fixture(ID, self.output)
            with self.assertRaises(ValueError): seed.seed_video_fixture('booted', self.output)
            with self.assertRaises(ValueError): seed.seed_video_fixture(ID, self.root.parent)
            link = self.root / 'linked'; link.symlink_to(self.output, target_is_directory=True)
            with self.assertRaises(ValueError): seed.seed_video_fixture(ID, link)
            run.assert_not_called()

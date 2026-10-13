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
import seed_diagnostics as diag

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
        def bounded(command, deadline, **kwargs):
            self.calls.append(command)
            self.assertEqual(deadline - kwargs['work_deadline'], 1)
            return diag.Result(0, False, 0.1)
        with patch.object(seed.subprocess, 'run', side_effect=self.run_command), patch.object(seed, 'run_bounded', side_effect=bounded):
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

    def test_video_timeout_preserves_one_mutation_owned_reap_and_fixed_diagnostic_namespace(self):
        result = diag.Result(-9, True, 120.1, stderr=b'private details must be redacted', reaped=True)
        with patch.object(seed.subprocess, 'run', side_effect=self.run_command), \
             patch.object(seed.time, 'monotonic', return_value=10), \
             patch.object(seed, 'run_bounded', return_value=result) as run, \
             patch.object(seed, 'collect_failure') as collect:
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                seed.seed_video_fixture(ID, self.output)
        self.assertEqual(caught.exception.timeout, 120)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][:4], ['xcrun', 'simctl', 'addmedia', ID])
        self.assertEqual(run.call_args.args[1], 131)
        self.assertEqual(run.call_args.kwargs['work_deadline'], 130)
        collect.assert_called_once()
        self.assertEqual(collect.call_args.args[0].namespace, 'video')
        folder = self.output / 'video-fixture'
        text = (folder / 'video-seed-command.json').read_text()
        self.assertNotIn('private details', text)
        self.assertTrue(json.loads(text)['result']['ownedChildReaped'])
        report = json.loads((folder / 'result.json').read_text())
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['failureClass'], 'TimeoutExpired')
        self.assertFalse((folder / 'image-seed-command.json').exists())

    def test_video_diagnostic_failure_cannot_mask_original_timeout_or_leak_message(self):
        with patch.object(seed.subprocess, 'run', side_effect=self.run_command), \
             patch.object(seed, 'run_bounded', return_value=diag.Result(-9, True, 120, reaped=False)) as run, \
             patch.object(seed, 'collect_failure', side_effect=RuntimeError('secret diagnostic text')), \
             patch('builtins.print') as printed:
            with self.assertRaises(subprocess.TimeoutExpired): seed.seed_video_fixture(ID, self.output)
        self.assertEqual(run.call_count, 1)
        self.assertNotIn('secret diagnostic text', str(printed.call_args_list))
        result = json.loads((self.output / 'video-fixture/result.json').read_text())
        self.assertFalse(result['stages'][-1]['supervision']['ownedChildReaped'])
        self.assertEqual(result['failureClass'], 'TimeoutExpired')

    def test_video_failure_diagnostics_remain_read_only_bounded_and_namespaced(self):
        folder = self.output / 'diagnostics'; folder.mkdir()
        evidence = diag.Evidence(ID, folder, namespace='video')
        calls = []
        def bounded(command, deadline, **kwargs):
            calls.append((command, deadline, kwargs))
            return diag.Result(0, False, 0.1)
        try:
            with patch.object(diag.time, 'monotonic', return_value=10), patch.object(diag, 'run_bounded', side_effect=bounded):
                report = diag.collect_failure(evidence, ID, 'video-addmedia')
        finally: evidence.close()
        self.assertEqual(report['budgetSeconds'], 30)
        self.assertEqual(len(calls), 3)
        self.assertTrue(all(deadline <= 39 for _, deadline, _ in calls))
        self.assertTrue(all('addmedia' not in command for command, _, _ in calls))
        self.assertTrue(all(command[2] in ('spawn', 'io') and command[3] == ID for command, _, _ in calls))
        self.assertTrue((folder / 'video-seed-diagnostics.json').exists())
        self.assertFalse((folder / 'image-seed-diagnostics.json').exists())
        with self.assertRaises(ValueError): diag.Evidence(ID, folder, namespace='../outside')

    def test_command_projection_enospc_cannot_replace_timeout_or_exit_failure(self):
        cases = [(diag.Result(-9, True, 120, reaped=True), subprocess.TimeoutExpired),
                 (diag.Result(65, False, 0.1), subprocess.CalledProcessError)]
        for index, (result, expected) in enumerate(cases):
            output = self.root / ('write-failure-' + str(index)); output.mkdir()
            with patch.object(seed.subprocess, 'run', side_effect=self.run_command), \
                 patch.object(seed, 'run_bounded', return_value=result) as run, \
                 patch.object(seed.Evidence, 'json', side_effect=OSError(28, 'private ENOSPC path')), \
                 patch.object(seed, 'collect_failure', side_effect=OSError(28, 'private diagnostic path')), \
                 patch('builtins.print') as printed:
                with self.assertRaises(expected) as caught: seed.seed_video_fixture(ID, output)
            self.assertEqual(run.call_count, 1)
            if expected is subprocess.TimeoutExpired: self.assertEqual(caught.exception.timeout, 120)
            else: self.assertEqual(caught.exception.returncode, 65)
            self.assertNotIn('private', str(printed.call_args_list))
            report = json.loads((output / 'video-fixture/result.json').read_text())
            self.assertEqual(report['failureClass'], expected.__name__)
            self.assertEqual(report['stages'][-1]['exitCode'], result.returncode)
            self.assertEqual(report['stages'][-1]['commandEvidenceWriteErrorClass'], 'OSError')

    def test_final_report_enospc_also_preserves_actual_timeout(self):
        with patch.object(seed.subprocess, 'run', side_effect=self.run_command), \
             patch.object(seed, 'run_bounded', return_value=diag.Result(-9, True, 120)), \
             patch.object(seed, 'collect_failure'), \
             patch.object(Path, 'write_text', side_effect=OSError(28, 'private final report path')), \
             patch('builtins.print') as printed:
            with self.assertRaises(subprocess.TimeoutExpired): seed.seed_video_fixture(ID, self.output)
        self.assertNotIn('private final report path', str(printed.call_args_list))

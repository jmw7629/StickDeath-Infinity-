"""Exercise the real Python harness with mocked subprocesses; no native runtime claim."""
import importlib.util, json, os, pathlib, subprocess, sys, tempfile, unittest
from unittest.mock import patch
ROOT = pathlib.Path(__file__).resolve().parents[2] / 'scripts/native-smoke'
sys.path.insert(0, str(ROOT))
import seed_image_fixture as seed
import run_recorded_test as rec
ID = '00000000-0000-4000-8000-000000000001'

class Harness(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.out = self.root / 'evidence'
        self.out.mkdir()
        self.calls = []
        self.env = patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'RUNNER_TEMP': str(self.root)})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def inventory(self, state='Booted', available=True):
        return {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [{'udid': ID, 'name': 'fixture', 'state': state, 'isAvailable': available}]}}

    def test_direct_seed_preserves_fixture_and_explicit_addmedia(self):
        with patch.object(seed.subprocess, 'run') as run:
            seed.seed_verified_fixture(ID, self.out)
        a = run.call_args
        self.assertEqual(a.args[0][:4], ['xcrun', 'simctl', 'addmedia', ID])
        self.assertEqual(a.kwargs, {'check': True, 'timeout': 60})
        report = json.loads((self.out / 'image-fixture.json').read_text())
        self.assertEqual(report['sha256'], '1f8b75bc39c94c7f4a27bbd4192bdb3dc3f57766b01991dba7f9a6bd6ac93614')
        with patch.object(seed.subprocess, 'run') as run:
            with self.assertRaises(FileExistsError):
                seed.seed_verified_fixture(ID, self.out)
            run.assert_not_called()

    def test_environment_uuid_and_output_guards(self):
        with patch.object(seed.subprocess, 'run') as run:
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}):
                with self.assertRaises(ValueError):
                    seed.seed_verified_fixture(ID, self.out)
            with self.assertRaises(ValueError):
                seed.seed_verified_fixture('booted', self.out)
            with self.assertRaises(ValueError):
                seed.seed_verified_fixture(ID, self.root.parent)
            run.assert_not_called()

    def test_standalone_keeps_fresh_booted_identity_gate(self):
        argv = ['seed', '--udid', ID, '--output', str(self.out)]
        with patch.object(sys, 'argv', argv), patch.object(seed.subprocess, 'check_output', return_value=json.dumps(self.inventory(state='Shutdown')).encode()) as check, patch.object(seed.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                seed.main()
            self.assertEqual(check.call_args.args[0], ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'])
            run.assert_not_called()
        with patch.object(sys, 'argv', argv), patch.object(seed.subprocess, 'check_output', return_value=json.dumps(self.inventory()).encode()), patch.object(seed.subprocess, 'run') as run:
            seed.main()
            self.assertEqual(run.call_args.args[0][2], 'addmedia')

    def recording(self, boot_failure=False, available=True):
        calls = self.calls

        def inventory(cmd, **kw):
            calls.append(tuple(cmd))
            return json.dumps(self.inventory(state='Shutdown', available=available)).encode()

        def run(cmd, **kw):
            calls.append(tuple(cmd))
            if boot_failure and cmd[:3] == ['xcrun', 'simctl', 'bootstatus']:
                raise subprocess.CalledProcessError(1, cmd)
            return subprocess.CompletedProcess(cmd, 0, stdout='{}')

        class Child:

            def __init__(self, cmd, **kw):
                calls.append(tuple(cmd))
                self.returncode = None

            def poll(self):
                return self.returncode

            def wait(self, timeout=None):
                self.returncode = 0
                return 0

            def send_signal(self, s):
                self.returncode = 0

            def terminate(self):
                self.returncode = 0

            def kill(self):
                self.returncode = 0
        argv = ['rec', '--udid', ID, '--output', str(self.out), '--', 'xcodebuild', 'test-without-building', '-destination', 'id=' + ID]
        with patch.object(sys, 'argv', argv), patch.object(rec.subprocess, 'check_output', side_effect=inventory), patch.object(rec.subprocess, 'run', side_effect=run), patch.object(rec.subprocess, 'Popen', Child), patch.object(rec.time, 'sleep'), patch.object(rec.signal, 'signal'), patch('builtins.print'):
            return rec.main()

    def test_integrated_path_checks_identity_boots_then_seeds_once(self):
        self.assertEqual(self.recording(), 0)
        calls = self.calls
        self.assertEqual(sum((c[:3] == ('xcrun', 'simctl', 'list') for c in calls)), 1)
        boot = next((i for (i, c) in enumerate(calls) if c[:3] == ('xcrun', 'simctl', 'bootstatus')))
        add = next((i for (i, c) in enumerate(calls) if c[:3] == ('xcrun', 'simctl', 'addmedia')))
        record = next((i for (i, c) in enumerate(calls) if c[:3] == ('xcrun', 'simctl', 'io')))
        self.assertLess(boot, add)
        self.assertLess(add, record)
        self.assertEqual(calls[add][3], ID)

    def test_failed_native_bootstatus_prevents_seeding(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.recording(boot_failure=True)
        self.assertFalse(any((c[:3] == ('xcrun', 'simctl', 'addmedia') for c in self.calls)))
        self.assertFalse((self.out / 'image-fixture.json').exists())

    def test_unavailable_identity_prevents_boot_and_seeding(self):
        with self.assertRaises(ValueError):
            self.recording(available=False)
        self.assertEqual(len(self.calls), 1)
if __name__ == '__main__':
    unittest.main(verbosity=2)

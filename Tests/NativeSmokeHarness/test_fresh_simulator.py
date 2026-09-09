"""Real selector/filesystem checks with mocked commands; no native runtime claim."""
import copy
import json
import os
import pathlib
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2] / 'scripts/native-smoke'
sys.path.insert(0, str(ROOT))
import select_simulator as select
from seed_diagnostics import Result

SHA = 'a' * 40
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-2'
OLD_RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-18-5'


class FreshSimulator(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name).resolve()
        self.output = self.root / 'actions-output'
        self.output.touch()
        self.old_id = str(uuid.uuid4()).upper()
        self.other_id = str(uuid.uuid4()).upper()
        self.new_id = str(uuid.uuid4()).upper()
        self.name = 'SDI-12345678-2'
        self.calls = []
        self.initial = {
            'devicetypes': [{'identifier': select.TYPE, 'name': 'iPhone 16 Pro'}],
            'runtimes': [{'identifier': RUNTIME, 'version': '26.2', 'isAvailable': True},
                         {'identifier': OLD_RUNTIME, 'version': '18.5', 'isAvailable': True}],
            'devices': {RUNTIME: [self.device(self.old_id, 'iPhone 16 Pro')],
                        OLD_RUNTIME: [self.device(self.other_id, 'iPhone 16 Pro')]}}
        self.final = copy.deepcopy(self.initial)
        self.final['devices'][RUNTIME].append(self.device(self.new_id, self.name))
        self.env = patch.dict(os.environ, {
            'GITHUB_ACTIONS': 'true', 'RUNNER_TEMP': str(self.root),
            'GITHUB_RUN_ID': '12345678', 'GITHUB_RUN_ATTEMPT': '2',
            'GITHUB_JOB': 'native-ios-build', 'GITHUB_OUTPUT': str(self.output)})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def device(self, identifier, name):
        return {'udid': identifier, 'name': name, 'state': 'Shutdown',
                'isAvailable': True, 'deviceTypeIdentifier': select.TYPE}

    def result(self, data=b'', **kw):
        return Result(kw.pop('returncode', 0), kw.pop('timed_out', False),
                      kw.pop('elapsed', 0.01), stdout=data,
                      stdout_seen=kw.pop('stdout_seen', len(data)), **kw)

    def command(self, argv, deadline, **kw):
        self.calls.append((argv, deadline, kw))
        if argv == ['git', 'rev-parse', '--verify', 'HEAD']:
            return self.result((SHA + '\n').encode())
        if argv == ['xcrun', 'simctl', 'list', '--json']:
            listed = sum(c[0] == argv for c in self.calls)
            return self.result(json.dumps(self.initial if listed == 1 else self.final).encode())
        if argv == ['xcrun', 'simctl', 'create', self.name, select.TYPE, RUNTIME]:
            return self.result((self.new_id + '\n').encode())
        self.fail('Unexpected command: ' + repr(argv))

    def run_selector(self, command=None):
        with patch.object(select, 'run_bounded', side_effect=command or self.command):
            return select.create_fresh()

    def marker(self):
        return json.loads((self.root / select.MARKER).read_text())

    def evidence(self):
        output = self.root / 'sdi-native-smoke.test'
        output.mkdir()
        return output

    def assert_one_create(self):
        self.assertEqual(sum(c[0][:3] == ['xcrun', 'simctl', 'create'] for c in self.calls), 1)
        self.assertFalse(any(c[0][2:3] in ([action] for action in ('delete', 'erase', 'boot', 'addmedia', 'shutdown')) for c in self.calls))

    def test_one_verified_create_receipt_and_artifact_copy(self):
        self.assertEqual(self.run_selector(), self.new_id)
        self.assert_one_create()
        self.assertEqual(len(self.calls), 4)
        value = self.marker()
        self.assertEqual(value['state'], 'verified')
        self.assertEqual(value['sourceCommit'], SHA)
        self.assertEqual(value['template']['udid'], self.old_id)
        self.assertEqual(value['created'], {'name': self.name, 'runtime': RUNTIME,
                                          'deviceType': select.TYPE, 'udid': self.new_id})
        upload = self.root / select.UPLOAD
        self.assertEqual(json.loads(upload.read_text()), value)
        self.assertEqual(self.output.read_text(), 'simulator_setup_path=' + str(upload) + '\n')
        self.assertEqual(upload.stat().st_mode & 0o777, 0o600)
        evidence = self.evidence()
        select.copy_marker(evidence, self.new_id, SHA)
        self.assertEqual((evidence / 'fresh-simulator.json').read_bytes(), (self.root / select.MARKER).read_bytes())
        with patch.object(select, 'run_bounded') as command:
            with self.assertRaises(FileExistsError):
                select.create_fresh()
            command.assert_not_called()

    def test_create_timeout_preserves_failure_and_never_retries(self):
        def command(argv, deadline, **kw):
            result = self.command(argv, deadline, **kw)
            if argv[2:3] == ['create']:
                return self.result(timed_out=True, returncode=-9)
            return result
        with self.assertRaisesRegex(ValueError, 'create failed'):
            self.run_selector(command)
        self.assert_one_create()
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(self.marker()['state'], 'failed')
        self.assertTrue(self.marker()['createAttempted'])
        self.assertEqual(json.loads((self.root / select.UPLOAD).read_text())['state'], 'failed')
        with patch.object(select, 'run_bounded') as command:
            with self.assertRaises(FileExistsError):
                select.create_fresh()
            command.assert_not_called()

    def test_returned_old_or_malformed_uuid_rejected(self):
        for response in (self.old_id, 'booted', self.new_id.replace('-', ''), self.new_id + '\nextra'):
            with self.subTest(response=response), tempfile.TemporaryDirectory() as tmp:
                with patch.dict(os.environ, {'RUNNER_TEMP': tmp, 'GITHUB_OUTPUT': ''}):
                    self.calls = []
                    def command(argv, deadline, **kw):
                        result = self.command(argv, deadline, **kw)
                        return self.result(response.encode()) if argv[2:3] == ['create'] else result
                    with self.assertRaises(ValueError):
                        self.run_selector(command)
                    self.assert_one_create()
                    self.assertEqual(len(self.calls), 3)

    def test_fresh_inventory_must_match_all_identity_fields(self):
        changes = [('name', 'Unrelated'), ('state', 'Booted'), ('isAvailable', False),
                   ('deviceTypeIdentifier', 'other-type'), ('udid', str(uuid.uuid4()))]
        for field, value in changes:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as tmp:
                with patch.dict(os.environ, {'RUNNER_TEMP': tmp, 'GITHUB_OUTPUT': ''}):
                    self.calls = []
                    final = copy.deepcopy(self.final)
                    final['devices'][RUNTIME][-1][field] = value
                    with patch.object(self, 'final', final), self.assertRaises(ValueError):
                        self.run_selector()
                    self.assert_one_create()
        for variation in ('wrong-runtime', 'runtime-unavailable', 'additional-device'):
            with self.subTest(variation=variation), tempfile.TemporaryDirectory() as tmp:
                with patch.dict(os.environ, {'RUNNER_TEMP': tmp, 'GITHUB_OUTPUT': ''}):
                    self.calls = []
                    final = copy.deepcopy(self.final)
                    if variation == 'wrong-runtime':
                        final['devices'][OLD_RUNTIME].append(final['devices'][RUNTIME].pop())
                    elif variation == 'runtime-unavailable':
                        final['runtimes'][0]['isAvailable'] = False
                    else:
                        final['devices'][RUNTIME].append(self.device(str(uuid.uuid4()), 'extra'))
                    with patch.object(self, 'final', final), self.assertRaises(ValueError):
                        self.run_selector()
                    self.assert_one_create()

    def test_no_installed_template_or_duplicate_name_never_creates(self):
        for variation in ('unavailable', 'missing-type', 'duplicate-name', 'malformed-runtime'):
            with self.subTest(variation=variation), tempfile.TemporaryDirectory() as tmp:
                with patch.dict(os.environ, {'RUNNER_TEMP': tmp, 'GITHUB_OUTPUT': ''}):
                    self.calls = []
                    initial = copy.deepcopy(self.initial)
                    if variation == 'unavailable':
                        for runtime in initial['runtimes']:
                            runtime['isAvailable'] = False
                    elif variation == 'missing-type':
                        initial['devicetypes'] = []
                    elif variation == 'duplicate-name':
                        initial['devices'][RUNTIME].append(self.device(self.new_id, self.name))
                    else:
                        initial['runtimes'].append('invalid')
                    with patch.object(self, 'initial', initial), self.assertRaises(ValueError):
                        self.run_selector()
                    self.assertEqual(len(self.calls), 2)

    def test_ci_run_source_and_runner_directory_guards(self):
        for env in ({'GITHUB_ACTIONS': 'false'}, {'GITHUB_RUN_ID': 'invalid'},
                    {'GITHUB_RUN_ATTEMPT': ''}, {'GITHUB_JOB': 'unsafe/name'}):
            with self.subTest(env=env), patch.dict(os.environ, env), patch.object(select, 'run_bounded') as command:
                with self.assertRaises(ValueError):
                    select.create_fresh()
                command.assert_not_called()
        link = self.root / 'linked-root'
        link.symlink_to(self.root, target_is_directory=True)
        with patch.dict(os.environ, {'RUNNER_TEMP': str(link)}), patch.object(select, 'run_bounded') as command:
            with self.assertRaises(ValueError):
                select.create_fresh()
            command.assert_not_called()
        with patch.object(select, 'run_bounded', return_value=self.result(b'not-a-commit\n')) as command:
            with self.assertRaisesRegex(ValueError, 'source commit'):
                select.create_fresh()
            self.assertEqual(command.call_count, 1)
        self.assertFalse(self.marker()['createAttempted'])

    def test_bounded_command_errors_and_output_flood_reject(self):
        cases = [self.result(b'{}', stdout_seen=select.INVENTORY_CAP + 1),
                 self.result(b'{}', stderr_seen=16385),
                 self.result(b'{}', returncode=1),
                 self.result(b'{}', capture_incomplete=True),
                 self.result(b'{}', reaped=False),
                 self.result(b'{}', spawn_error='OSError')]
        for result in cases:
            with self.subTest(result=result), tempfile.TemporaryDirectory() as tmp:
                with patch.dict(os.environ, {'RUNNER_TEMP': tmp, 'GITHUB_OUTPUT': ''}):
                    self.calls = []
                    def command(argv, deadline, **kw):
                        good = self.command(argv, deadline, **kw)
                        return result if argv[2:3] == ['list'] else good
                    with self.assertRaisesRegex(ValueError, 'initial-inventory failed'):
                        self.run_selector(command)
                    self.assertEqual(len(self.calls), 2)

    def test_total_deadline_prevents_later_command(self):
        clock = [10.0]
        def command(argv, deadline, **kw):
            result = self.command(argv, deadline, **kw)
            self.assertLessEqual(deadline, 110.0)
            clock[0] = 111.0
            return result
        with patch.object(select.time, 'monotonic', side_effect=lambda: clock[0]), self.assertRaisesRegex(ValueError, 'deadline exhausted'):
            self.run_selector(command)
        self.assertEqual(len(self.calls), 1)
        self.assertFalse(self.marker()['createAttempted'])

    def test_command_budget_shrinks_to_global_deadline(self):
        clock = [10.0]
        def command(argv, deadline, **kw):
            result = self.command(argv, deadline, **kw)
            if argv[2:3] == ['create']:
                clock[0] = 105.0
            self.assertLessEqual(kw['stdout_cap'], select.INVENTORY_CAP)
            self.assertEqual(kw['stderr_cap'], 16384)
            return result
        with patch.object(select.time, 'monotonic', side_effect=lambda: clock[0]):
            self.assertEqual(self.run_selector(command), self.new_id)
        self.assertEqual(self.calls[-1][1], 110.0)

    def test_foreign_marker_file_and_symlink_never_read_or_uploaded(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                output = root / 'output'; output.touch()
                foreign = root / 'foreign'; foreign.write_text('PRIVATE-FOREIGN-CONTENT')
                marker = root / select.MARKER
                if symlink:
                    marker.symlink_to(foreign)
                else:
                    marker.write_bytes(foreign.read_bytes())
                with patch.dict(os.environ, {'RUNNER_TEMP': tmp, 'GITHUB_OUTPUT': str(output)}), patch.object(select, 'run_bounded') as command:
                    with self.assertRaises(FileExistsError):
                        select.create_fresh()
                    command.assert_not_called()
                self.assertEqual(marker.read_text(), 'PRIVATE-FOREIGN-CONTENT')
                self.assertEqual(output.read_text(), '')
                self.assertFalse((root / select.UPLOAD).exists())

    def test_foreign_upload_receipt_is_preserved_without_output(self):
        target = self.root / select.UPLOAD
        target.write_text('foreign-receipt')
        with self.assertRaises(FileExistsError):
            self.run_selector()
        self.assert_one_create()
        self.assertEqual(target.read_text(), 'foreign-receipt')
        self.assertEqual(self.output.read_text(), '')
        self.assertEqual(self.marker()['state'], 'verified')

    def test_actions_output_replacement_is_never_written(self):
        original_open = os.open
        def opened(path, flags, *args, **kw):
            if pathlib.Path(path) == self.output and flags & os.O_APPEND:
                self.output.rename(self.root / 'original-actions-output')
                self.output.write_text('foreign-output')
            return original_open(path, flags, *args, **kw)
        with patch.object(select.os, 'open', side_effect=opened), self.assertRaisesRegex(ValueError, 'Actions output file changed'):
            self.run_selector()
        self.assertEqual(self.output.read_text(), 'foreign-output')
        self.assertEqual((self.root / 'original-actions-output').read_text(), '')
        self.assert_one_create()

    def test_actions_output_symlink_is_not_followed(self):
        foreign = self.root / 'foreign-output'; foreign.write_text('foreign')
        self.output.unlink(); self.output.symlink_to(foreign)
        with self.assertRaisesRegex(ValueError, 'Actions output file'):
            self.run_selector()
        self.assertEqual(foreign.read_text(), 'foreign')
        self.assertFalse((self.root / select.UPLOAD).exists())

    def test_marker_replacement_during_create_fails_without_adoption(self):
        def command(argv, deadline, **kw):
            result = self.command(argv, deadline, **kw)
            if argv[2:3] == ['create']:
                (self.root / select.MARKER).rename(self.root / 'original-marker')
                (self.root / select.MARKER).write_text('foreign-marker')
            return result
        with self.assertRaises(ValueError):
            self.run_selector(command)
        self.assert_one_create()
        self.assertEqual((self.root / select.MARKER).read_text(), 'foreign-marker')
        self.assertEqual(self.output.read_text(), '')
        self.assertFalse((self.root / select.UPLOAD).exists())

    def test_receipt_redacts_raw_output_and_private_inventory_fields(self):
        self.initial['devices'][RUNTIME][0]['dataPath'] = '/private/never-persist'
        def command(argv, deadline, **kw):
            result = self.command(argv, deadline, **kw)
            result.stderr = b'private-token=SECRET-CONTENT database code=14'
            result.stderr_seen = len(result.stderr)
            return result
        self.run_selector(command)
        text = (self.root / select.UPLOAD).read_text()
        for forbidden in ('SECRET-CONTENT', '/private/never-persist', 'dataPath'):
            self.assertNotIn(forbidden, text)
        self.assertEqual(self.marker()['steps'][0]['stderr']['numericErrorCodes'], ['14'])

    def test_copy_requires_same_verified_run_source_device(self):
        self.run_selector()
        evidence = self.evidence()
        for device, sha in ((self.old_id, SHA), (self.new_id, 'b' * 40)):
            with self.assertRaises(ValueError):
                select.copy_marker(evidence, device, sha)
        with patch.dict(os.environ, {'GITHUB_RUN_ATTEMPT': '3'}), self.assertRaises(ValueError):
            select.copy_marker(evidence, self.new_id, SHA)
        value = self.marker(); value['state'] = 'failed'
        (self.root / select.MARKER).write_text(json.dumps(value))
        with self.assertRaises(ValueError):
            select.copy_marker(evidence, self.new_id, SHA)
        self.assertFalse((evidence / 'fresh-simulator.json').exists())

    def test_copy_preserves_foreign_output_and_rejects_unsafe_paths(self):
        self.run_selector()
        evidence = self.evidence()
        target = evidence / 'fresh-simulator.json'
        target.write_text('foreign')
        with self.assertRaises(FileExistsError):
            select.copy_marker(evidence, self.new_id, SHA)
        self.assertEqual(target.read_text(), 'foreign')
        with self.assertRaises(ValueError):
            select.copy_marker(self.root, self.new_id, SHA)
        link = self.root / 'sdi-native-smoke.link'; link.symlink_to(evidence, target_is_directory=True)
        with self.assertRaises(ValueError):
            select.copy_marker(link, self.new_id, SHA)
        with tempfile.TemporaryDirectory(prefix='sdi-native-smoke.') as outside:
            with self.assertRaises(ValueError):
                select.copy_marker(outside, self.new_id, SHA)

    def test_copy_rejects_marker_symlink_and_excess_bytes(self):
        self.run_selector()
        evidence = self.evidence()
        marker = self.root / select.MARKER
        marker.rename(self.root / 'original')
        marker.symlink_to(self.root / 'original')
        with self.assertRaises(OSError):
            select.copy_marker(evidence, self.new_id, SHA)
        marker.unlink(); marker.write_bytes(b'x' * (select.MARKER_CAP + 1))
        with self.assertRaises(ValueError):
            select.copy_marker(evidence, self.new_id, SHA)
        self.assertFalse((evidence / 'fresh-simulator.json').exists())

    def test_copy_rejects_directory_replacement_before_creation(self):
        self.run_selector()
        evidence = self.evidence()
        original_open = os.open
        def opened(path, flags, *args, **kw):
            if pathlib.Path(path) == evidence:
                evidence.rename(self.root / 'original-evidence')
                evidence.mkdir()
                (evidence / 'foreign').write_text('foreign')
            return original_open(path, flags, *args, **kw)
        with patch.object(select.os, 'open', side_effect=opened), self.assertRaisesRegex(ValueError, 'Evidence directory changed'):
            select.copy_marker(evidence, self.new_id, SHA)
        self.assertEqual(list(evidence.iterdir()), [evidence / 'foreign'])


if __name__ == '__main__':
    unittest.main(verbosity=2)

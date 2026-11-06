"""Actual production orchestration + real bounded local child I/O; no simulator."""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2] / 'scripts/native-smoke'
sys.path.insert(0, str(ROOT))
import seed_diagnostics as diag
import seed_image_fixture as seed
import run_recorded_test as rec

ID = '00000000-0000-4000-8000-000000000001'


class Diagnostics(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.out = self.root / 'evidence'
        self.out.mkdir()
        self.env = patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'RUNNER_TEMP': str(self.root)})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_success_retains_exact120s_gate_and_original_fixture_without_diagnostics(self):
        with patch.object(seed.time, 'monotonic', return_value=10), patch.object(seed, 'run_bounded', return_value=diag.Result(0, False, 0.1)) as run, patch.object(seed, 'collect_failure') as collect:
            seed.seed_verified_fixture(ID, self.out)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[1], 131)
        self.assertEqual(run.call_args.kwargs['work_deadline'], 130)
        collect.assert_not_called()
        self.assertEqual(hashlib.sha256((self.out/'SDI-generated-image-fixture.png').read_bytes()).hexdigest(), '1f8b75bc39c94c7f4a27bbd4192bdb3dc3f57766b01991dba7f9a6bd6ac93614')
        self.assertTrue((self.out/'image-fixture.json').is_file())

    def test_timeout_and_secondary_failure_preserve_original_timeout120(self):
        with patch.object(seed, 'run_bounded', return_value=diag.Result(-9, True, 120)), patch.object(seed, 'collect_failure', side_effect=RuntimeError('secret credential')) as collect, patch('builtins.print') as printed:
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                seed.seed_verified_fixture(ID, self.out)
        self.assertEqual(caught.exception.timeout, 120)
        self.assertEqual(caught.exception.cmd[:4], ['xcrun','simctl','addmedia',ID])
        collect.assert_called_once()
        self.assertNotIn('secret credential', str(printed.call_args_list))
        self.assertFalse((self.out/'image-fixture.json').exists())

    def test_exit_failure_and_raw_stderr_never_become_false_success_or_secret_report(self):
        raw=b'path=/Users/private secret-token https://private.test admin@example.com Code=123 connection denied'
        result=diag.Result(7,False,0.1,stderr=raw,stderr_seen=len(raw))
        with patch.object(seed,'run_bounded',return_value=result) as run, patch.object(seed,'collect_failure'):
            with self.assertRaises(subprocess.CalledProcessError) as caught: seed.seed_verified_fixture(ID,self.out)
        self.assertEqual(caught.exception.returncode,7);self.assertEqual(run.call_count,1)
        report=(self.out/'image-seed-command.json').read_text()
        for secret in ['secret-token','private.test','admin@','/Users']: self.assertNotIn(secret,report)
        self.assertIn('123',report);self.assertIn('connection',report)
        self.assertFalse((self.out/'image-fixture.json').exists())

    def test_real_timeout_kills_and_reaps_only_its_owned_child(self):
        started=time.monotonic()
        result=diag.run_bounded([sys.executable,'-c','import time;time.sleep(30)'],started+0.35)
        self.assertTrue(result.timed_out);self.assertTrue(result.reaped)
        self.assertLess(time.monotonic()-started,1.5)

    def test_real_stdout_and_stderr_flood_are_drained_with_exact_retained_caps(self):
        program='import os\nfor _ in range(1024):\n os.write(1,b"a"*4096)\n os.write(2,b"b"*4096)'
        result=diag.run_bounded([sys.executable,'-c',program],time.monotonic()+5,stdout_cap=1234,stderr_cap=5678)
        self.assertEqual(result.returncode,0);self.assertFalse(result.timed_out)
        self.assertEqual(len(result.stdout),1234);self.assertEqual(len(result.stderr),5678)
        self.assertEqual(result.stdout_seen,4194304);self.assertEqual(result.stderr_seen,4194304)
        projection=diag.result_projection(result)
        self.assertTrue(projection['stdoutTruncated']);self.assertTrue(projection['stderrTruncated'])

    def test_real_infinite_flood_still_obeys_deadline_and_reaps(self):
        result=diag.run_bounded([sys.executable,'-c','import os\nwhile True: os.write(1,b"x"*4096)'],time.monotonic()+0.35,stdout_cap=256)
        self.assertTrue(result.timed_out);self.assertTrue(result.reaped)
        self.assertEqual(len(result.stdout),256);self.assertGreater(result.stdout_seen,256)

    def test_child_success_with_inherited_pipe_does_not_become_false_timeout(self):
        code='import subprocess,sys\nsubprocess.Popen([sys.executable,"-c","import time;time.sleep(0.4)"])'
        started=time.monotonic()
        result=diag.run_bounded([sys.executable,'-c',code],started+1)
        self.assertEqual(result.returncode,0);self.assertFalse(result.timed_out)
        self.assertTrue(result.capture_incomplete);self.assertTrue(result.reaped)
        self.assertLess(time.monotonic()-started,0.7)

    def test_opted_in_drain_waits_for_delayed_inherited_eof_and_preserves_byte_caps(self):
        descendant='import os,time;time.sleep(0.2);os.write(1,b"a"*5000);os.write(2,b"b"*5000)'
        code='import subprocess,sys\nsubprocess.Popen([sys.executable,"-c",'+repr(descendant)+'])'
        started=time.monotonic()
        result=diag.run_bounded([sys.executable,'-c',code],started+2,
                                stdout_cap=7,stderr_cap=5,post_exit_drain_seconds=1.0)
        self.assertEqual(result.returncode,0);self.assertFalse(result.timed_out)
        self.assertTrue(result.reaped);self.assertFalse(result.capture_incomplete)
        self.assertEqual((result.stdout_seen,result.stderr_seen),(5000,5000))
        self.assertEqual((result.stdout,result.stderr),(b'a'*7,b'b'*5))
        self.assertLess(time.monotonic()-started,1.5)

    def test_opted_in_drain_still_rejects_pipes_open_beyond_one_second(self):
        code='import subprocess,sys\nsubprocess.Popen([sys.executable,"-c","import time;time.sleep(1.4)"])'
        started=time.monotonic()
        result=diag.run_bounded([sys.executable,'-c',code],started+3,post_exit_drain_seconds=1)
        self.assertEqual(result.returncode,0);self.assertFalse(result.timed_out)
        self.assertTrue(result.reaped);self.assertTrue(result.capture_incomplete)
        self.assertGreaterEqual(time.monotonic()-started,1)
        self.assertLess(time.monotonic()-started,1.8)

    def test_opted_in_drain_cannot_extend_the_existing_work_deadline(self):
        code='import subprocess,sys\nsubprocess.Popen([sys.executable,"-c","import time;time.sleep(0.8)"])'
        started=time.monotonic()
        result=diag.run_bounded([sys.executable,'-c',code],started+2,
                                work_deadline=started+0.35,post_exit_drain_seconds=1)
        self.assertEqual(result.returncode,0);self.assertFalse(result.timed_out)
        self.assertTrue(result.reaped);self.assertTrue(result.capture_incomplete)
        self.assertLess(time.monotonic()-started,0.7)

    def test_drain_validation_occurs_before_spawn_and_accepts_only_finite_zero_to_one(self):
        invalid=[-0.001,1.001,float('inf'),float('-inf'),float('nan'),None,'0.2',True]
        for value in invalid:
            with self.subTest(value=value),patch.object(diag.subprocess,'Popen') as child:
                with self.assertRaises(ValueError):
                    diag.run_bounded(['unused'],time.monotonic()+2,post_exit_drain_seconds=value)
                child.assert_not_called()
        for value in (0,1):
            with self.subTest(value=value),patch.object(diag.subprocess,'Popen') as child:
                result=diag.run_bounded(['unused'],time.monotonic()-1,post_exit_drain_seconds=value)
                self.assertTrue(result.timed_out);child.assert_not_called()

    def test_unexpected_seeding_error_still_stops_recorder_and_ui_after_original_boot_gate(self):
        argv=['rec','--udid',ID,'--output',str(self.out),'--','xcodebuild','test-without-building',
              '-destination','id='+ID,'-test-timeouts-enabled','YES',
              '-default-test-execution-time-allowance','300','-maximum-test-execution-time-allowance','360',
              '-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1']
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-26-2':[{'udid':ID,'name':'fixture','state':'Booted','isAvailable':True}]}}
        with patch.object(sys,'argv',argv),patch.object(rec.subprocess,'check_output',return_value=json.dumps(inventory).encode()),patch.object(rec.subprocess,'run',return_value=subprocess.CompletedProcess([],0)) as boot,patch.object(seed,'run_bounded',side_effect=OSError('Unexpected seed I/O')),patch.object(seed,'collect_failure'),patch.object(rec.subprocess,'Popen') as child:
            with self.assertRaises(OSError):rec.main()
            child.assert_not_called()
        self.assertEqual(boot.call_args.args[0],['xcrun','simctl','bootstatus',ID,'-b'])
        self.assertFalse((self.out/'recording-status.json').exists())

    def test_unexpected_capture_error_identity_is_preserved_after_diagnostic_error(self):
        original=OSError('original bounded capture failure')
        with patch.object(seed,'run_bounded',side_effect=original),patch.object(seed,'collect_failure',side_effect=ValueError('foreign path')),patch('builtins.print'):
            with self.assertRaises(OSError) as caught:seed.seed_verified_fixture(ID,self.out)
        self.assertIs(caught.exception,original)

    def test_shared30s_deadline_stops_remaining_commands_without_resets(self):
        clock=[100.0];calls=[]
        def run(command,deadline,**kwargs):
            calls.append((command,deadline));clock[0]=130.0
            return diag.Result(None,True,30)
        evidence=diag.Evidence(ID,self.out)
        try:
            with patch.object(diag.time,'monotonic',side_effect=lambda:clock[0]),patch.object(diag,'run_bounded',side_effect=run):
                report=diag.collect_failure(evidence,ID,'addmedia')
        finally:evidence.close()
        self.assertEqual(len(calls),1);self.assertLessEqual(calls[0][1],129)
        self.assertEqual(report['budgetSeconds'],30);self.assertTrue(report['deadlineExhausted'])
        self.assertEqual(sum('notRun' in s for s in report['steps']),2)

    def test_scoped_commands_structured_redaction_and_actual_generated_png_evidence(self):
        calls=[];png=seed.make_png()
        def run(command,deadline,**kwargs):
            calls.append(command)
            if command[2]=='io':return diag.Result(0,False,0.1,stdout=png,stdout_seen=len(png))
            if 'launchctl' in command:
                data=b'42 0 com.apple.assetsd\n- -9 com.apple.photolibraryd\n99 0 private.app.secret\n'
            else:data=b'{"eventMessage":"secret@example.com /private/photos.jpg SQLite locked timeout Code=13"}\n'
            return diag.Result(0,False,0.1,stdout=data,stdout_seen=len(data))
        evidence=diag.Evidence(ID,self.out)
        try:
            with patch.object(diag,'run_bounded',side_effect=run):report=diag.collect_failure(evidence,ID,'addmedia')
        finally:evidence.close()
        self.assertEqual(len(calls),3)
        for command in calls:self.assertEqual(command[:2],['xcrun','simctl']);self.assertEqual(command[3],ID)
        self.assertEqual(calls[0][2:],[ 'spawn', ID,'launchctl','list'])
        self.assertEqual(calls[2][2:],[ 'io', ID,'screenshot','--type=png','-'])
        self.assertIn('process == "assetsd"',calls[1][-1]);self.assertIn('logType == "error"',calls[1][-1])
        saved=(self.out/'image-seed-diagnostics.json').read_text()
        for secret in ['secret@example','photos.jpg','private.app.secret']:self.assertNotIn(secret,saved)
        self.assertEqual(len(report['steps'][0]['allowlistedServices']),2)
        self.assertEqual((self.out/'image-seed-setup.png').read_bytes(),png)
        self.assertLess(sum(p.stat().st_size for p in self.out.iterdir()),diag.EVIDENCE_BYTES)

    def test_screenshot_flood_or_corrupt_crc_is_never_written_as_valid_png(self):
        original=seed.make_png();bad=bytearray(original);bad[40]^=1
        for number,result in enumerate([diag.Result(0,False,0,stdout=original,stdout_seen=diag.SCREENSHOT_BYTES+1),diag.Result(0,False,0,stdout=bytes(bad),stdout_seen=len(bad))]):
            out=self.root/('screen'+str(number));out.mkdir();evidence=diag.Evidence(ID,out)
            try:
                with patch.object(diag,'run_bounded',return_value=result):report=diag.collect_failure(evidence,ID,'addmedia')
            finally:evidence.close()
            self.assertFalse((out/'image-seed-setup.png').exists());self.assertIn('unavailable',report['steps'][2]['screenshot'])

    def test_foreign_paths_symlinks_and_preexisting_files_are_preserved(self):
        outside=self.root/'outside';outside.mkdir();link=self.root/'link';link.symlink_to(outside,target_is_directory=True)
        with self.assertRaises(ValueError):diag.Evidence(ID,link)
        with self.assertRaises(ValueError):diag.Evidence(ID,self.root)
        evidence=diag.Evidence(ID,self.out)
        try:
            target=self.out/'image-seed-diagnostics.json';target.write_text('foreign')
            with self.assertRaises(FileExistsError):evidence.json(target.name,{'new':True})
            self.assertEqual(target.read_text(),'foreign')
            (self.out/'image-seed-setup.png').symlink_to(outside/'protected')
            with self.assertRaises(FileExistsError):evidence.write('image-seed-setup.png',b'x')
            self.assertFalse((outside/'protected').exists())
        finally:evidence.close()

    def test_directory_replacement_prevents_any_diagnostic_command_or_foreign_write(self):
        evidence=diag.Evidence(ID,self.out);moved=self.root/'moved';self.out.rename(moved);self.out.mkdir()
        try:
            with patch.object(diag,'run_bounded') as run:
                with self.assertRaises(ValueError):diag.collect_failure(evidence,ID,'addmedia')
                run.assert_not_called()
            self.assertEqual(list(self.out.iterdir()),[]);self.assertEqual(list(moved.iterdir()),[])
        finally:evidence.close()

    def test_mismatched_or_generic_simulator_target_never_runs_diagnostics(self):
        evidence=diag.Evidence(ID,self.out)
        try:
            for target in ['booted','00000000-0000-4000-8000-000000000002']:
                with patch.object(diag,'run_bounded') as run:
                    with self.assertRaises(ValueError):diag.collect_failure(evidence,target,'addmedia')
                    run.assert_not_called()
        finally:evidence.close()

    def test_total_evidence_budget_and_filename_allowlist_apply_before_write(self):
        evidence=diag.Evidence(ID,self.out)
        try:
            with self.assertRaises(ValueError):evidence.write('../foreign',b'x')
            with self.assertRaises(ValueError):evidence.write('image-seed-setup.png',b'x'*(diag.EVIDENCE_BYTES+1))
            evidence.written=diag.EVIDENCE_BYTES
            with self.assertRaises(ValueError):evidence.json('image-seed-diagnostics.json',{'x':1})
            self.assertEqual(list(self.out.iterdir()),[])
        finally:evidence.close()

    def test_expired_deadline_never_spawns_and_spawn_failure_is_factual(self):
        with patch.object(diag.subprocess,'Popen') as child:
            result=diag.run_bounded(['unused'],time.monotonic()-1);self.assertTrue(result.timed_out);child.assert_not_called()
        result=diag.run_bounded(['/definitely-not-a-real-sdi-command'],time.monotonic()+1)
        self.assertEqual(result.spawn_error,'FileNotFoundError');self.assertIsNone(result.returncode)


class EncoderDiagnostics(unittest.TestCase):
    """Real redaction and bounded transport with mocked simulator output only."""
    LEGACY = ('MP4 encoding failed stage=publication codec=h264 writerStatus=3'
              ' domain=POSIX code=13 underlyingDomain=none underlyingCode=0')
    SUFFIX = ' publicationSubstage=34 fileRole=2 systemError=13 identityMatch=1'

    def event(self, message, **fields):
        return (json.dumps({'subsystem': rec._ENCODER_SUBSYSTEM,
                            'category': rec._ENCODER_CATEGORY,
                            'eventMessage': message, **fields}) + '\n').encode()

    def test_legacy_and_new_records_survive_together(self):
        messages = [self.LEGACY, self.LEGACY + self.SUFFIX]
        self.assertEqual(rec.movie_encoder_records(b''.join(map(self.event, messages))),
                         (messages, False))

    def test_every_public_numeric_stage_role_and_identity_accepts(self):
        for stage in (0, *range(10, 16), *range(20, 26), *range(30, 35)):
            for role in range(3):
                for identity in (-1, 0, 1):
                    for errno in (0, 1, 2147483647):
                        message = (self.LEGACY + f' publicationSubstage={stage} fileRole={role}'
                                   f' systemError={errno} identityMatch={identity}')
                        with self.subTest(stage=stage, role=role, identity=identity, errno=errno):
                            self.assertEqual(rec.movie_encoder_records(self.event(message)), ([message], False))

    def test_invalid_numeric_values_reject_whole_record(self):
        good = self.LEGACY + self.SUFFIX
        values = {'publicationSubstage': [-1, *range(1, 10), *range(16, 20),
                                         *range(26, 30), 35, 100, '034', '+34', '٣٤'],
                  'fileRole': [-1, 3, 10, '02', '+2'],
                  'systemError': [-1, 2147483648, 9999999999, 10000000000, '013', '+13', '١٣'],
                  'identityMatch': [-2, 2, '01', '+1', '-0']}
        originals = {'publicationSubstage': '34', 'fileRole': '2', 'systemError': '13', 'identityMatch': '1'}
        for field, invalid in values.items():
            for value in invalid:
                message = good.replace(f'{field}={originals[field]}', f'{field}={value}')
                with self.subTest(field=field, value=value):
                    self.assertEqual(rec.movie_encoder_records(self.event(message)), ([], False))

    def test_partial_reordered_unknown_or_private_fields_reject(self):
        for suffix in (self.SUFFIX.split(' identityMatch=')[0],
                       self.SUFFIX.replace(' fileRole=2', ''),
                       self.SUFFIX.replace('fileRole=2 systemError=13', 'systemError=13 fileRole=2'),
                       self.SUFFIX + ' fileRole=2', self.SUFFIX + ' path=/private/movie.mp4',
                       ' token=secret-token', self.SUFFIX + ' token=secret-token',
                       self.SUFFIX + ' ', self.SUFFIX + '\nsecret-token',
                       self.SUFFIX.replace('systemError=13', 'systemError=<private>')):
            with self.subTest(suffix=suffix):
                self.assertEqual(rec.movie_encoder_records(self.event(self.LEGACY + suffix)), ([], False))

    def test_existing_prefix_domains_and_numeric_constraints_stay_strict(self):
        for old, new in (('MP4 encoding failed ', 'prefix MP4 encoding failed '),
                         ('stage=publication', 'stage=unknown'), ('codec=h264', 'codec=av1'),
                         ('writerStatus=3', 'writerStatus=5'), ('domain=POSIX', 'domain=secret-token'),
                         ('underlyingDomain=none', 'underlyingDomain=/private'),
                         ('code=13', 'code=' + '1' * 20), ('underlyingCode=0', 'underlyingCode=+1')):
            for suffix in ('', self.SUFFIX):
                with self.subTest(old=old, suffix=suffix):
                    self.assertEqual(rec.movie_encoder_records(self.event(self.LEGACY.replace(old, new) + suffix)),
                                     ([], False))

    def test_only_scoped_complete_json_events_survive(self):
        raw = (b'not-json secret-token\n[]\n' + self.event(self.LEGACY, subsystem='private.app')
               + self.event(self.LEGACY, category='other') + self.event(None)
               + self.event(self.LEGACY + self.SUFFIX) + self.event(self.LEGACY)[:-1])
        self.assertEqual(rec.movie_encoder_records(raw), ([self.LEGACY + self.SUFFIX], True))

    def test_record_and_byte_caps_stay_exact(self):
        line = self.event(self.LEGACY + self.SUFFIX)
        self.assertEqual(rec.movie_encoder_records(line * 32), ([self.LEGACY + self.SUFFIX] * 32, False))
        self.assertEqual(rec.movie_encoder_records(line * 33), ([self.LEGACY + self.SUFFIX] * 32, True))
        cap = 64 * 1024
        # One valid record exactly at the retained boundary; another is never read.
        raw = b' ' * (cap - len(line) - 1) + b'\n' + line
        self.assertEqual(rec.movie_encoder_records(raw), ([self.LEGACY + self.SUFFIX], False))
        self.assertEqual(rec.movie_encoder_records(raw + line), ([self.LEGACY + self.SUFFIX], True))
        self.assertEqual(rec.movie_encoder_records(b' ' * (cap - 1) + line), ([], True))

    def test_transport_keeps_eight_second_budget_and_only_redacted_records(self):
        safe = self.LEGACY + self.SUFFIX
        raw = self.event(safe) + self.event(safe + ' path=/private secret-token')
        result = diag.Result(0, False, 0.1, stdout=raw, stdout_seen=len(raw))
        with tempfile.TemporaryDirectory() as directory:
            out = pathlib.Path(directory)
            with patch.object(rec.time, 'monotonic', return_value=100), patch.object(rec, 'run_bounded', return_value=result) as run:
                self.assertIsNone(rec.record_movie_encoder_failure(ID, out, 123))
            run.assert_called_once()
            command, deadline = run.call_args.args
            self.assertEqual(deadline, 108)
            self.assertEqual(run.call_args.kwargs, {'stdout_cap': 64 * 1024, 'stderr_cap': 0})
            self.assertEqual(command[:4], ['xcrun', 'simctl', 'spawn', ID])
            self.assertEqual(command[4:10], ['log', 'show', '--start', '@123', '--style', 'ndjson'])
            self.assertIn('subsystem == "' + rec._ENCODER_SUBSYSTEM + '"', command[-1])
            self.assertIn('category == "StudioMovieEncoder"', command[-1])
            self.assertIn('logType == "error"', command[-1])
            report = json.loads((out / 'studio-movie-encoder-failures.json').read_text())
            self.assertEqual(report, {'complete': True, 'truncated': False, 'records': [safe]})

    def test_incomplete_transport_and_secondary_errors_never_become_success(self):
        raw = self.event(self.LEGACY)
        for result in (diag.Result(7, False, 0, stdout=raw, stdout_seen=len(raw)),
                       diag.Result(-9, True, 8, stdout=raw, stdout_seen=len(raw)),
                       diag.Result(0, False, 0, stdout=raw, stdout_seen=len(raw) + 1)):
            with tempfile.TemporaryDirectory() as directory:
                out = pathlib.Path(directory)
                with patch.object(rec, 'run_bounded', return_value=result):
                    self.assertIsNone(rec.record_movie_encoder_failure(ID, out, 123))
                report = json.loads((out / 'studio-movie-encoder-failures.json').read_text())
                self.assertFalse(report['complete'])
        with tempfile.TemporaryDirectory() as directory:
            out = pathlib.Path(directory)
            with patch.object(rec, 'run_bounded', side_effect=OSError('secret-token')):
                self.assertIsNone(rec.record_movie_encoder_failure(ID, out, 123))
            self.assertEqual(list(out.iterdir()), [])
            target = out / 'studio-movie-encoder-failures.json'
            target.write_text('existing evidence')
            with patch.object(rec, 'run_bounded', return_value=diag.Result(0, False, 0, stdout=raw)):
                self.assertIsNone(rec.record_movie_encoder_failure(ID, out, 123))
            self.assertEqual(target.read_text(), 'existing evidence')


if __name__=='__main__':unittest.main(verbosity=2)

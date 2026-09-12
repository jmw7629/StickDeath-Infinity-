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

    def test_success_retains_exact60s_gate_and_original_fixture_without_diagnostics(self):
        with patch.object(seed.time, 'monotonic', return_value=10), patch.object(seed, 'run_bounded', return_value=diag.Result(0, False, 0.1)) as run, patch.object(seed, 'collect_failure') as collect:
            seed.seed_verified_fixture(ID, self.out)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[1], 71)
        self.assertEqual(run.call_args.kwargs['work_deadline'], 70)
        collect.assert_not_called()
        self.assertEqual(hashlib.sha256((self.out/'SDI-generated-image-fixture.png').read_bytes()).hexdigest(), '1f8b75bc39c94c7f4a27bbd4192bdb3dc3f57766b01991dba7f9a6bd6ac93614')
        self.assertTrue((self.out/'image-fixture.json').is_file())

    def test_timeout_and_secondary_failure_preserve_original_timeout60(self):
        with patch.object(seed, 'run_bounded', return_value=diag.Result(-9, True, 60)), patch.object(seed, 'collect_failure', side_effect=RuntimeError('secret credential')) as collect, patch('builtins.print') as printed:
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                seed.seed_verified_fixture(ID, self.out)
        self.assertEqual(caught.exception.timeout, 60)
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

    def test_failed_seeding_stops_recorder_and_ui_process_after_original_boot_gate(self):
        argv=['rec','--udid',ID,'--output',str(self.out),'--','xcodebuild','test-without-building','-destination','id='+ID]
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-26-2':[{'udid':ID,'name':'fixture','state':'Booted','isAvailable':True}]}}
        with patch.object(sys,'argv',argv),patch.object(rec.subprocess,'check_output',return_value=json.dumps(inventory).encode()),patch.object(rec.subprocess,'run',return_value=subprocess.CompletedProcess([],0)) as boot,patch.object(seed,'run_bounded',return_value=diag.Result(-9,True,60)),patch.object(seed,'collect_failure'),patch.object(rec.subprocess,'Popen') as child:
            with self.assertRaises(subprocess.TimeoutExpired):rec.main()
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


if __name__=='__main__':unittest.main(verbosity=2)

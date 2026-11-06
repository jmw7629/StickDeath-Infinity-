import copy
import contextlib
import io
import json
import os
import plistlib
import tempfile
import time
from unittest import mock
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/native-smoke'))
import journey_receipt as journey  # noqa: E402
import test_budget  # noqa: E402
import run_journey_ci as runner
import prepare_offline_run as offline
import select_simulator as selector
from seed_diagnostics import Result

SHA = 'a' * 40
BINDING = {'sourceCommit': SHA, 'runID': '7', 'runAttempt': '1'}
INVENTORY = journey.suite_inventory()
UI_SOURCE = (ROOT / journey.SUITES['ui'][0]).read_text()
UI_COMMAND = ['xcodebuild', 'test-without-building', journey.selector('ui'),
              '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
              '-maximum-test-execution-time-allowance', '420', '-parallel-testing-enabled', 'NO',
              '-maximum-concurrent-test-simulator-destinations', '1']


def tree(cls, names, result='Passed', bundle='UI test bundle'):
    cases = [{'nodeType': 'Test Case', 'nodeIdentifier': f'{cls}/{n}()', 'result': result, 'children': []} for n in names]
    return {'devices': [{}], 'testPlanConfigurations': [{}],
            'testNodes': [{'nodeType': 'Test Plan', 'children': [{'nodeType': bundle, 'children': [
                {'nodeType': 'Test Suite', 'children': cases}]}]}]}


def summary(count):
    return {'result': 'Passed', 'passedTests': count, 'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0}


def passing(key):
    cls = journey.SUITES[key][1]
    names = INVENTORY[key]
    return journey.evaluate(key, names, 0, tree(cls, names, bundle='UI test bundle' if key == 'ui' else 'Unit test bundle'), summary(len(names)))


def receipts():
    return [journey.receipt(BINDING, 'iphone', [passing('ui'), passing('service')]),
            journey.receipt(BINDING, 'ipad', [passing('ui')])]


class JourneyReceiptTests(unittest.TestCase):
    def test_inventory_is_separate_from_the_pinned_smoke_suite(self):
        self.assertGreaterEqual(len(INVENTORY['ui']), 1)
        self.assertGreaterEqual(len(INVENTORY['service']), 1)
        smoke = (ROOT / 'Tests/NativeUI/StudioSmokeUITests.swift').read_text()
        # The smoke budget still parses exactly one class from its own file.
        self.assertEqual(test_budget.build_test_budget(smoke, ['xcodebuild', 'test-without-building', '-test-timeouts-enabled', 'YES',
            '-default-test-execution-time-allowance', '300', '-maximum-test-execution-time-allowance', '360',
            '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1'])['testCount'], test_budget.MAXIMUM_CASES)
        self.assertFalse(set(INVENTORY['ui']) & set(test_budget.EXTENDED_CASE_SECONDS))
        self.assertEqual(journey.selector('ui'), '-only-testing:StickDeathInfinityUITests/JourneyUITests')
        self.assertEqual(journey.selector('service'), '-only-testing:StickDeathInfinityAuthTests/ServiceJourneyTests')

    def test_audio_only_budget_preserves_other_journeys_and_service_limits(self):
        self.assertEqual(journey.ui_test_budget(UI_SOURCE, UI_COMMAND), 1740)
        self.assertEqual(journey.PER_CASE_SECONDS, 180)
        self.assertEqual(journey.EXTENDED_CASE_SECONDS,
                         {'testAdaptiveAudioWorkspaceKeepsCanvasAndControlsReachable': 300,
                          'testMirrorMenuChoicesAccessibilityAndOlderSystemFallback': 420})
        self.assertEqual(journey.service_timeout_seconds(6), 660)
        self.assertEqual(journey.service_timeout_seconds(13), 1080)
        self.assertEqual(len(INVENTORY['service']), 13)
        self.assertEqual(journey.service_timeout_seconds(len(INVENTORY['service'])), 1080)
        self.assertEqual(journey.SERVICE_CASE_SECONDS, 60)

    def test_mirror_allowance_is_exact_and_cannot_extend_another_journey(self):
        mirror = 'testMirrorMenuChoicesAccessibilityAndOlderSystemFallback'
        self.assertEqual(journey.MAXIMUM_CASE_SECONDS, 420)
        changed_sources = [
            UI_SOURCE.replace(mirror, 'testDifferentMirrorJourney'),
            UI_SOURCE.replace('executionTimeAllowance = 180', 'executionTimeAllowance = 420', 1),
            UI_SOURCE.replace('executionTimeAllowance = 420',
                              'executionTimeAllowance = 420\n        executionTimeAllowance = 420'),
        ]
        for value in ('0', '180', '300', '419', '421', '600', 'Double.infinity', '420 + 1',
                      'TimeInterval.greatestFiniteMagnitude'):
            changed_sources.append(UI_SOURCE.replace('executionTimeAllowance = 420', 'executionTimeAllowance = ' + value))
        for index, source in enumerate(changed_sources):
            with self.subTest(case=index), self.assertRaises(ValueError):
                journey.ui_test_budget(source, UI_COMMAND)

    def test_other_names_missing_or_unbounded_allowances_reject(self):
        other = 'testAdaptiveStudioCanvasToolbarAndFrameTimelineInBothOrientations'
        changed_sources = [
            UI_SOURCE.replace(other + '() throws {\n        executionTimeAllowance = 180',
                              other + '() throws {\n        executionTimeAllowance = 300'),
            UI_SOURCE.replace('testAdaptiveAudioWorkspaceKeepsCanvasAndControlsReachable', 'testDifferentAudioJourney'),
            UI_SOURCE.replace('executionTimeAllowance = 180\n', '', 1),
            UI_SOURCE.replace('executionTimeAllowance = 300', 'executionTimeAllowance = 300\n        executionTimeAllowance = 600'),
        ]
        for value in ('0', '301', '600', 'Double.infinity', '180 + 120', 'TimeInterval.greatestFiniteMagnitude'):
            changed_sources.append(UI_SOURCE.replace('executionTimeAllowance = 300', 'executionTimeAllowance = ' + value))
        for index, source in enumerate(changed_sources):
            with self.subTest(case=index), self.assertRaises(ValueError):
                journey.ui_test_budget(source, UI_COMMAND)

    def test_ui_budget_rejects_case_filters_retries_or_changed_command_bounds(self):
        for extra in ('-only-testing:StickDeathInfinityUITests/JourneyUITests/testAdaptiveAudioWorkspaceKeepsCanvasAndControlsReachable',
                      '-skip-testing:StickDeathInfinityUITests/JourneyUITests', '-test-iterations',
                      '-retry-tests-on-failure', '-run-tests-until-failure', '-maximum-test-iterations=2',
                      journey.selector('ui'), '-maximum-test-execution-time-allowance=0'):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                journey.ui_test_budget(UI_SOURCE, UI_COMMAND + [extra])
        for flag, values in (('-test-timeouts-enabled', ('NO',)),
                             ('-default-test-execution-time-allowance', ('0', '300')),
                             ('-maximum-test-execution-time-allowance', ('0', '300', '301', '419', '421', '600'))):
            for value in values:
                changed = UI_COMMAND.copy(); changed[changed.index(flag) + 1] = value
                with self.subTest(flag=flag, value=value), self.assertRaises(ValueError):
                    journey.ui_test_budget(UI_SOURCE, changed)

    def test_complete_passing_receipts_aggregate(self):
        result = journey.aggregate(receipts(), BINDING, INVENTORY, {'native-ios-journeys': 'success'})
        self.assertTrue(result['passed'])
        self.assertEqual(result['devices'], ['ipad', 'iphone'])
        self.assertEqual(result['passedJourneyCases'], 2 * len(INVENTORY['ui']) + len(INVENTORY['service']))

    def test_missing_failed_stale_or_foreign_receipts_reject(self):
        values = receipts()
        cases = [values[:1], values + [values[1]], []]
        failed = copy.deepcopy(values); failed[0]['passed'] = False; cases.append(failed)
        foreign = copy.deepcopy(values); foreign[1]['sourceCommit'] = 'b' * 40; cases.append(foreign)
        retried = copy.deepcopy(values); retried[1]['runAttempt'] = '2'; cases.append(retried)
        stale = copy.deepcopy(values); stale[1]['suites'][0]['expected'] = INVENTORY['ui'][:-1]; cases.append(stale)
        missing = copy.deepcopy(values); missing[0]['suites'] = missing[0]['suites'][:1]; cases.append(missing)
        for index, value in enumerate(cases):
            with self.subTest(case=index), self.assertRaises(ValueError):
                journey.aggregate(value, BINDING, INVENTORY, {'native-ios-journeys': 'success'})
        for state in ('failure', 'skipped', 'cancelled'):
            with self.subTest(state=state), self.assertRaises(ValueError):
                journey.aggregate(receipts(), BINDING, INVENTORY, {'native-ios-journeys': state})

    def test_evaluate_requires_every_case_once_and_passing(self):
        names = INVENTORY['ui']
        bad = [
            journey.evaluate('ui', names, 0, tree('JourneyUITests', names[:-1]), summary(len(names) - 1)),
            journey.evaluate('ui', names, 0, tree('JourneyUITests', names, result='Failed'), summary(len(names))),
            journey.evaluate('ui', names, 0, tree('StudioSmokeUITests', names), summary(len(names))),
            journey.evaluate('ui', names, 65, tree('JourneyUITests', names), summary(len(names))),
            journey.evaluate('ui', names, 0, tree('JourneyUITests', names), dict(summary(len(names)), skippedTests=1)),
            journey.evaluate('ui', names, 0, {}, {}),
        ]
        for index, value in enumerate(bad):
            with self.subTest(case=index):
                self.assertFalse(value['passed']); self.assertTrue(value['errors'])
        self.assertFalse(journey.receipt(BINDING, 'iphone', [passing('ui')])['passed'], 'phone must also run service journeys')

    def test_workflow_job_ceilings_and_aggregate_gate(self):
        workflow = (ROOT / '.github/workflows/spatter-client-verify.yml').read_text()
        job = workflow.split('  native-ios-journeys:', 1)[1]
        aggregate = workflow.split('  native-ios-build:', 1)[1].split('  native-ios-journeys:', 1)[0]
        self.assertIn('needs: [native-app-compile]', job)
        self.assertIn('      max-parallel: 1', job)
        self.assertIn('journey_receipt.py aggregate', aggregate)
        self.assertIn('native-journey-receipt-$SDI_EXPECTED_HEAD-$GITHUB_RUN_ATTEMPT-*', aggregate)
        ui = journey.ui_timeout_seconds(INVENTORY['ui'])
        service = journey.service_timeout_seconds(len(INVENTORY['service']))
        for device, minutes in (('iphone', -(-(25 * 60 + ui + service) // 60)), ('ipad', -(-(25 * 60 + ui) // 60))):
            self.assertIn(f'          - device: {device}\n            timeout: {minutes}\n', job)
        auth = (ROOT / 'scripts/native-smoke/run_auth_ci.py').read_text()
        self.assertIn('-only-testing:StickDeathInfinityAuthTests/AuthStateTests', auth)

    def test_test_files_are_registered_in_their_targets(self):
        pbx = (ROOT / 'StickDeathInfinity.xcodeproj/project.pbxproj').read_text()
        self.assertEqual(pbx.count('JourneyUITests.swift in Sources'), 2)
        self.assertEqual(pbx.count('ServiceJourneyTests.swift in Sources'), 2)
        self.assertIn('path = Tests/AuthState/ServiceJourneyTests.swift; sourceTree = SOURCE_ROOT;', pbx)

    def test_required_native_builds_keep_the_toolchain_and_package_lock(self):
        workflow = (ROOT / '.github/workflows/spatter-client-verify.yml').read_text()
        shards = workflow.split('  native-ios-shards:', 1)[1].split('  native-ios-build:', 1)[0]
        journeys = workflow.split('  native-ios-journeys:', 1)[1]
        command = 'python3 scripts/native-smoke/prepare_locked_build.py'
        for job in (shards, journeys):
            self.assertEqual(job.count(command), 1)
            self.assertLess(job.index(command), job.index('select_simulator.py'))
        for script in ('prepare_locked_build.py', 'run_smoke_ci.sh', 'run_journey_ci.py', 'run_auth_ci.py'):
            source = (ROOT / 'scripts/native-smoke' / script).read_text()
            with self.subTest(script=script):
                for part in ('sdi-native-build', 'SourcePackages', '-clonedSourcePackagesDirPath',
                             '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile'):
                    self.assertIn(part, source)
        setup = (ROOT / 'scripts/native-smoke/prepare_locked_build.py').read_text()
        self.assertIn('["git", "diff", "--quiet", "HEAD", "--"]', setup)
        self.assertIn('"--name-status", "--no-renames", "HEAD", "--"', setup)
        self.assertIn('clean_checkout("after the locked native build")', setup)
        self.assertIn('os.environ["GITHUB_ENV"]', setup)
        self.assertIn('DEVELOPER_DIR=', setup)



class OwnedPreinstallTests(unittest.TestCase):
    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();products=root/"sdi-native-build/Build/Products"
            app=products/"Debug-iphonesimulator/StickDeathInfinity.app"
            host=products/"Debug-iphonesimulator/Runner.app";(host/"PlugIns/Tests.xctest").mkdir(parents=True)
            app.mkdir(parents=True)
            (app/"Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"com.willisbmb.StickDeathInfinity",
                                                         **{key:"" for key in offline.PUBLIC_SETTINGS}}))
            profile=products/"Original.xctestrun"
            profile.write_bytes(plistlib.dumps({"StickDeathInfinityUITests":{
                "TestBundlePath":"__TESTHOST__/PlugIns/Tests.xctest",
                "TestHostPath":"__TESTROOT__/Debug-iphonesimulator/Runner.app",
                "UITargetAppPath":"__TESTROOT__/Debug-iphonesimulator/StickDeathInfinity.app"}}))
            evidence=root/"sdi-native-smoke.journey.mock";evidence.mkdir()
            udid="11111111-1111-4111-8111-111111111111";runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-2"
            marker={"version":1,"state":"verified","sourceCommit":SHA,
                "run":{"runID":"7","runAttempt":"1","job":"journeys"},
                "created":{"udid":udid,"runtime":runtime,"name":"SDI-7-1","deviceType":selector.TYPE}}
            with mock.patch.dict(os.environ,{"GITHUB_ACTIONS":"true","GITHUB_RUN_ID":"7","GITHUB_RUN_ATTEMPT":"1",
                                             "GITHUB_JOB":"journeys","RUNNER_TEMP":str(root)},clear=True):
                (root/selector.MARKER).write_text(json.dumps(marker));selector.copy_marker(evidence,udid,SHA)
                yield root,app,profile,evidence,udid,runtime,marker

    def simulate(self,f,*,failure=False,revoke=False,remaining=1740):
        root,app,profile,evidence,udid,runtime,marker=f
        calls=[];state={"value":"Shutdown"}
        def bounded(argv,deadline,stdout_cap,stderr_cap):
            calls.append((argv,deadline));data=b"";code=0
            self.assertEqual(argv[:2],["xcrun","simctl"]);self.assertNotIn("launch",argv)
            if argv[2]=="list":
                data=json.dumps({"devices":{runtime:[{"udid":udid,"name":"SDI-7-1","deviceTypeIdentifier":selector.TYPE,
                    "isAvailable":True,"state":state["value"]}]},"runtimes":[],"devicetypes":[]}).encode()
            else:
                self.assertEqual(argv[3],udid)
                if argv[2]=="boot":state["value"]="Booted"
                if argv[2]=="shutdown":state["value"]="Shutdown"
                if argv[2]=="install":
                    if failure:code=17
                    if revoke:(root/selector.MARKER).write_text(json.dumps(dict(marker,run={"runID":"8"})))
            return Result(code,False,0.01,stdout=data,stdout_seen=len(data))
        deadline=time.monotonic()+remaining
        with mock.patch.object(runner,"run_bounded",side_effect=bounded),contextlib.redirect_stdout(io.StringIO()):
            result=runner.preinstall_owned_app(profile,evidence,udid,SHA,deadline)
        self.assertTrue(all(end<=deadline for _,end in calls))
        return result,calls,state

    def test_owned_install_is_once_and_does_not_launch_or_seed_target(self):
        with self.fixture() as f:
            result,calls,state=self.simulate(f)
            self.assertTrue(result["passed"]);self.assertEqual(result["installAttempts"],1)
            self.assertEqual(result["targetAppPrelaunches"],0)
            self.assertEqual([c[0][2] for c in calls],["list","boot","bootstatus","install"])
            self.assertEqual(calls[-1][0],["xcrun","simctl","install",f[4],str(f[1])])
            self.assertEqual((result["setupMaximumSeconds"],result["workMaximumSeconds"],result["cleanupReserveSeconds"]),(240,180,60))

    def test_invalid_configuration_or_product_path_never_contacts_simulator(self):
        for invalid in ("configured","redirected"):
            with self.subTest(invalid=invalid),self.fixture() as f:
                if invalid=="configured":
                    (f[1]/"Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"com.willisbmb.StickDeathInfinity","SUPABASE_URL":"https://configured.invalid"}))
                else:
                    value=plistlib.loads(f[2].read_bytes());value["StickDeathInfinityUITests"]["UITargetAppPath"]="/outside/Other.app"
                    f[2].write_bytes(plistlib.dumps(value))
                result,calls,state=self.simulate(f)
                self.assertFalse(result["passed"]);self.assertEqual(calls,[])

    def test_foreign_marker_or_insufficient_phase_budget_never_boots(self):
        for invalid in ("foreign","budget"):
            with self.subTest(invalid=invalid),self.fixture() as f:
                if invalid=="foreign":(f[0]/selector.MARKER).write_text(json.dumps(dict(f[6],run={"runID":"8"})))
                result,calls,state=self.simulate(f,remaining=30 if invalid=="budget" else 1740)
                self.assertFalse(result["passed"]);self.assertEqual(calls,[])
                self.assertEqual(result["installAttempts"],0)

    def test_failed_install_records_actual_exit_and_owned_shutdown_without_retry(self):
        with self.fixture() as f:
            result,calls,state=self.simulate(f,failure=True)
            self.assertFalse(result["passed"]);self.assertEqual(result["installAttempts"],1)
            self.assertEqual([c[0][2] for c in calls],["list","boot","bootstatus","install","list","shutdown"])
            install=next(item for item in result["steps"] if item["stage"]=="install")
            self.assertEqual(install["returnCode"],17);self.assertIs(install["timedOut"],False)
            self.assertTrue((f[3]/"preinstall/install.stdout").exists());self.assertEqual(state["value"],"Shutdown")

    def test_revoked_ownership_after_failed_install_preserves_foreign_device(self):
        with self.fixture() as f:
            result,calls,state=self.simulate(f,failure=True,revoke=True)
            self.assertFalse(result["passed"]);self.assertEqual(result["installAttempts"],1)
            self.assertNotIn("shutdown",[c[0][2] for c in calls])
            self.assertEqual(result["cleanup"]["state"],"unavailable-preserve-devices")

    def test_successful_install_with_revoked_lease_cannot_pass_or_shutdown_foreign_device(self):
        with self.fixture() as f:
            result,calls,state=self.simulate(f,revoke=True)
            self.assertFalse(result["passed"]);self.assertEqual(result["installAttempts"],1)
            install=next(item for item in result["steps"] if item["stage"]=="install")
            self.assertEqual(install["returnCode"],0);self.assertIs(install["timedOut"],False)
            self.assertEqual([c[0][2] for c in calls],["list","boot","bootstatus","install"])
            self.assertNotIn("shutdown",[c[0][2] for c in calls])
            self.assertEqual(result["cleanup"]["state"],"unavailable-preserve-devices")

    def test_shared_preflight_metadata_and_actual_product_resolution_remain_compatible(self):
        with self.fixture() as f:
            destination=f[2].with_name("Prepared.xctestrun")
            metadata=offline.prepare(f[2],destination,SHA)
            self.assertEqual(metadata,{"sourceCommit":SHA,"appBundleIdentifier":"com.willisbmb.StickDeathInfinity",
                "emptyPublicSettings":list(offline.PUBLIC_SETTINGS),"networkRequestsObserved":None,
                "networkMeasurementStatus":"Not measured by this UI preflight"})
            self.assertEqual(offline.validated_app(destination),f[1])

if __name__ == '__main__':
    unittest.main()

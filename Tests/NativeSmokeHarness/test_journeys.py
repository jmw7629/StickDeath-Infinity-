import copy
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/native-smoke'))
import journey_receipt as journey  # noqa: E402
import test_budget  # noqa: E402

SHA = 'a' * 40
BINDING = {'sourceCommit': SHA, 'runID': '7', 'runAttempt': '1'}
INVENTORY = journey.suite_inventory()
UI_SOURCE = (ROOT / journey.SUITES['ui'][0]).read_text()
UI_COMMAND = ['xcodebuild', 'test-without-building', journey.selector('ui'),
              '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
              '-maximum-test-execution-time-allowance', '300', '-parallel-testing-enabled', 'NO',
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
        self.assertEqual(journey.ui_test_budget(UI_SOURCE, UI_COMMAND), 1320)
        self.assertEqual(journey.PER_CASE_SECONDS, 180)
        self.assertEqual(journey.EXTENDED_CASE_SECONDS,
                         {'testAdaptiveAudioWorkspaceKeepsCanvasAndControlsReachable': 300})
        self.assertEqual(journey.service_timeout_seconds(len(INVENTORY['service'])), 660)
        self.assertEqual(journey.SERVICE_CASE_SECONDS, 60)

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
                             ('-maximum-test-execution-time-allowance', ('0', '301', '600'))):
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


if __name__ == '__main__':
    unittest.main()

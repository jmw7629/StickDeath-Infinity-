"""Real saved XCTest schema + synthetic orchestration failures, no iOS run."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/native-smoke'))
import shard_receipt as receipt
from test_budget import build_shard_budget, build_test_budget
SOURCE = (ROOT / 'Tests/NativeUI/StudioSmokeUITests.swift').read_text()
TREE = json.loads((Path(__file__).parent / 'Fixtures/xcresult-passed-tree.json').read_text())
BINDING = receipt.identity('1' * 40, '1234', '1')
DEPENDENCIES = {k: 'success' for k in ('source-security', 'spatter-production-tests', 'native-production-tests', 'native-ios-shards')}


def summary(count):
    return dict(passedTests=count, failedTests=0, skippedTests=0, totalTestCount=count, expectedFailures=0, result='Passed')


def gates(index):
    return dict({k: 'success' for k in receipt.COMMON_GATES}, **{k: 'success' if index == 0 else 'skipped' for k in receipt.OWNER_GATES})


def synthetic_tree(names):
    tree = copy.deepcopy(TREE)
    suite = tree['testNodes'][0]['children'][0]['children'][0]
    template = suite['children'][0]
    suite['children'] = []
    for name in names:
        node = copy.deepcopy(template)
        node.update(name=name+'()', nodeIdentifier='StudioSmokeUITests/'+name+'()', nodeIdentifierURL=receipt.PREFIX+name)
        suite['children'].append(node)
    return tree


def collected(index):
    budget, _ = build_shard_budget(SOURCE, receipt.COMMAND, index)
    with tempfile.TemporaryDirectory() as directory:
        p = Path(directory)
        for name, value in {
            'ui-test-budget.json': dict(budget, sourceCommit=BINDING['sourceCommit']),
            'source-and-config.json': {'sourceCommit': BINDING['sourceCommit']},
            'test-tree.json': synthetic_tree(budget['testNames']),
            'test-summary.json': summary(budget['testCount'])}.items():
            (p / name).write_text(json.dumps(value))
        return receipt.collect(SOURCE, p, index, BINDING, gates(index))


class NativeSharding(unittest.TestCase):
    def test_real_xcresult_schema_including_runtime_warning(self):
        cases = receipt.actual_tests(TREE)
        self.assertEqual(cases, [{'name':'testMixedDrawingImageMoveDeleteUndoAndColdReopen','result':'Passed'}])
        receipt.validate_execution(cases, summary(1), [cases[0]['name']])

    def test_actual_inventory_partition_and_command_ownership(self):
        full = build_test_budget(SOURCE, receipt.COMMAND)
        names = []
        for index, count, seconds, longcases in ((0,51,9900,7),(1,51,9660,3)):
            b, command = build_shard_budget(SOURCE, receipt.COMMAND, index)
            self.assertEqual((b['testCount'],b['suiteSeconds'],len(b['extendedCases'])),(count,seconds,longcases))
            self.assertEqual(b['testNames'],sorted(full['testNames'])[index::2])
            self.assertEqual(command[:len(receipt.COMMAND)],receipt.COMMAND)
            self.assertEqual(command[len(receipt.COMMAND):], ['-only-testing:StickDeathInfinityUITests/StudioSmokeUITests/'+n for n in b['testNames']])
            names += b['testNames']
        self.assertEqual(sorted(names), sorted(full['testNames']))
        self.assertEqual(len(set(names)),len(names))
        # Non-semantic source order cannot change assignment, but the source hash changes.
        changed = SOURCE.replace('func testFrameContextDuplicateUndoRedo(', 'func TEMP(').replace('func testEditableTextUndoRedo(', 'func testFrameContextDuplicateUndoRedo(').replace('func TEMP(', 'func testEditableTextUndoRedo(')
        self.assertEqual(build_shard_budget(changed,receipt.COMMAND,0)[0]['testNames'],build_shard_budget(SOURCE,receipt.COMMAND,0)[0]['testNames'])

    def test_invalid_partition_and_caller_filters_fail_closed(self):
        for index,count in ((-1,2),(2,2),(True,2),(0,1),(0,3)):
            with self.assertRaises(ValueError): build_shard_budget(SOURCE,receipt.COMMAND,index,count)
        for extra in ('-only-testing:Other/testA','-skip-testing:Other/testA','-test-iterations=2'):
            with self.assertRaises(ValueError): build_shard_budget(SOURCE,receipt.COMMAND+[extra],0)
        with self.assertRaises(ValueError): build_shard_budget('class StudioSmokeUITests: XCTestCase {\nfunc testOne() {}\n}',receipt.COMMAND,0)

    def test_collector_and_aggregate_actual_ids_not_counts(self):
        values = [collected(0),collected(1)]
        self.assertTrue(all(r['passed'] for r in values))
        self.assertEqual(receipt.aggregate(SOURCE,values,BINDING,DEPENDENCIES)['actualPassedTests'],102)
        for mutation in ('wrongID','duplicate','skipped','failed','unknown','summary','source','attempt','run','digest','assigned','auth','upload','errors'):
            v=copy.deepcopy(values)
            r=v[0]
            if mutation=='wrongID': r['actualTests'][0]['name']='testAbsent'
            elif mutation=='duplicate': r['actualTests'][0]=r['actualTests'][1]
            elif mutation in ('skipped','failed','unknown'): r['actualTests'][0]['result']=mutation.title()
            elif mutation=='summary': r['summary']['skippedTests']=1
            elif mutation=='source': r['sourceCommit']='2'*40
            elif mutation=='attempt': r['runAttempt']='2'
            elif mutation=='run': r['runID']='9'
            elif mutation=='digest': r['sourceSHA256']='0'*64
            elif mutation=='assigned': r['assignedTestNames']=v[1]['assignedTestNames']
            elif mutation=='auth': v[1]['gates']['native-auth']='success'
            elif mutation=='upload': r['gates']['smoke-upload']='failure'
            else: r['errors']=['missing evidence']
            with self.subTest(mutation=mutation),self.assertRaises(ValueError): receipt.aggregate(SOURCE,v,BINDING,DEPENDENCIES)
        for v in ([], values[:1], [values[0],values[0]]):
            with self.assertRaises(ValueError): receipt.aggregate(SOURCE,v,BINDING,DEPENDENCIES)
        for dependency in DEPENDENCIES:
            for state in ('failure','skipped','cancelled'):
                d=dict(DEPENDENCIES,**{dependency:state})
                with self.subTest(dependency=dependency,state=state),self.assertRaises(ValueError):
                    receipt.aggregate(SOURCE,values,BINDING,d)

    def test_tree_duplicate_retry_target_and_missing_evidence(self):
        for mutate in ('device','config','target','identifier','retry'):
            t=copy.deepcopy(TREE); node=t['testNodes'][0]['children'][0]['children'][0]['children'][0]
            if mutate=='device': t['devices']*=2
            elif mutate=='config': t['testPlanConfigurations']*=2
            elif mutate=='target': node['nodeIdentifierURL']=node['nodeIdentifierURL'].replace('StickDeathInfinityUITests','OtherTests')
            elif mutate=='identifier': node['nodeIdentifier']='StudioSmokeUITests/testWrong()'
            else: node['children'].append(dict(node,children=[]))
            with self.subTest(mutation=mutate),self.assertRaises(ValueError): receipt.actual_tests(t)
        with tempfile.TemporaryDirectory() as d:
            value=receipt.collect(SOURCE,Path(d),0,BINDING,gates(0))
            self.assertFalse(value['passed']); self.assertTrue(value['errors'])

    def test_workflow_matrix_aggregate_and_single_owner_gates(self):
        workflow=(ROOT/'.github/workflows/spatter-client-verify.yml').read_text()
        shards=workflow.split('  native-ios-shards:',1)[1].split('  native-ios-build:',1)[0]
        aggregate=workflow.split('  native-ios-build:',1)[1]
        self.assertIn("if: ${{ needs.native-production-tests.result == 'success' }}",shards)
        self.assertNotIn('if: ${{ always() }}',shards.split('    steps:',1)[0])
        self.assertIn('      fail-fast: false',shards)
        self.assertIn('      max-parallel: 1',shards)
        self.assertEqual(shards.count('          - shard:'),2)
        self.assertIn('needs: [source-security, spatter-production-tests, native-production-tests, native-ios-shards]',aggregate)
        self.assertIn('if: ${{ always() }}',aggregate)
        self.assertIn('SDI_NATIVE_SHARD_INDEX: ${{ matrix.shard }}',shards)
        for gate in ('native-review-rules','native-review-app','native-review-upload','native-auth'):
            step=shards.split('        id: '+gate+'\n',1)[1].split('      - ',1)[0]
            self.assertIn('matrix.shard == 0',step)
        self.assertIn('native-shard-receipt-${{ github.event.pull_request.head.sha || github.sha }}-${{ github.run_attempt }}-${{ matrix.shard }}',shards)
        self.assertIn('gh run download "$GITHUB_RUN_ID"',aggregate)
        self.assertIn('SDI_DEPENDENCY_RESULTS: ${{ toJSON(needs) }}',aggregate)
        shell=(ROOT/'scripts/native-smoke/run_smoke_ci.sh').read_text()
        self.assertIn('xcresulttool get test-results tests',shell)
        self.assertIn('exit "$sdi_test_status"',shell)


if __name__ == '__main__': unittest.main()

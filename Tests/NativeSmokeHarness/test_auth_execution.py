"""Check exact auth coverage without launching iOS or declaring native acceptance."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sdi_auth_ci", ROOT / "scripts/native-smoke/run_auth_ci.py")
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)
SOURCE = (ROOT / "Tests/AuthState/AuthStateTests.swift").read_text()
EXPECTED = auth.auth_test_names(SOURCE)


def summary(count):
    return dict(result="Passed", expectedFailures=0, totalTestCount=count,
                passedTests=count, failedTests=0, skippedTests=0)


def tree(names):
    cases = [dict(nodeType="Test Case", nodeIdentifier="AuthStateTests/" + name + "()",
                  nodeIdentifierURL="test://com.apple.xcode/StickDeathInfinity/StickDeathInfinityAuthTests/AuthStateTests/" + name,
                  result="Passed", children=[]) for name in names]
    return dict(devices=[{}], testPlanConfigurations=[{}], testNodes=[dict(nodeType="Test Plan", children=[
        dict(nodeType="Unit test bundle", children=[dict(nodeType="Test Suite", children=cases)])])])


def cases(value):
    return value["testNodes"][0]["children"][0]["children"][0]["children"]


class AuthExecutionTests(unittest.TestCase):
    def test_current_source_inventory_and_complete_execution(self):
        self.assertEqual(len(EXPECTED), 25)
        self.assertIn("testProfileEditRequiresConfirmedOwnedRowAndPreservesPriorProfileOnError", EXPECTED)
        auth.validate_auth_execution(tree(EXPECTED), summary(25), EXPECTED)

    def test_inventory_is_derived_from_source_not_a_minimum_count(self):
        source = "class AuthStateTests: XCTestCase {\n    func testOnlyCase() {}\n}"
        expected = auth.auth_test_names(source)
        self.assertEqual(expected, ["testOnlyCase"])
        auth.validate_auth_execution(tree(expected), summary(1), expected)

    def test_missing_or_extra_test_cannot_be_hidden_by_forged_counts(self):
        for names in (EXPECTED[:-1], EXPECTED + ["testUnexpectedCase"], EXPECTED[:22]):
            with self.subTest(count=len(names)), self.assertRaises(ValueError):
                auth.validate_auth_execution(tree(names), summary(25), EXPECTED)

    def test_equal_count_different_inventory_is_rejected(self):
        with self.assertRaises(ValueError):
            auth.validate_auth_execution(tree(EXPECTED[:-1] + ["testSubstitutedCase"]), summary(25), EXPECTED)

    def test_duplicate_execution_is_rejected(self):
        with self.assertRaises(ValueError):
            auth.validate_auth_execution(tree(EXPECTED[:-1] + [EXPECTED[0]]), summary(25), EXPECTED)

    def test_failed_skipped_and_unknown_case_results_are_rejected(self):
        for result in ("Failed", "Skipped", "Expected Failure", None):
            value = tree(EXPECTED)
            cases(value)[0]["result"] = result
            with self.subTest(result=result), self.assertRaises(ValueError):
                auth.validate_auth_execution(value, summary(25), EXPECTED)

    def test_nonpassing_or_forged_summary_is_rejected(self):
        for key, value in (("result", "Failed"), ("expectedFailures", 1), ("totalTestCount", 24),
                           ("passedTests", 22), ("failedTests", 1), ("skippedTests", 1)):
            status = summary(25)
            status[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                auth.validate_auth_execution(tree(EXPECTED), status, EXPECTED)

    def test_other_target_class_or_conflicting_identifier_is_rejected(self):
        for key, value in (("nodeIdentifier", "ServiceJourneyTests/" + EXPECTED[0] + "()"),
                           ("nodeIdentifierURL", "test://com.apple.xcode/Other/OtherTests/AuthStateTests/" + EXPECTED[0]),
                           ("nodeIdentifierURL", "test://com.apple.xcode/StickDeathInfinity/StickDeathInfinityAuthTests/AuthStateTests/testDifferent")):
            value_tree = tree(EXPECTED)
            cases(value_tree)[0][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                auth.validate_auth_execution(value_tree, summary(25), EXPECTED)

    def test_multiple_devices_or_configurations_are_rejected(self):
        for key in ("devices", "testPlanConfigurations"):
            value = tree(EXPECTED)
            value[key].append({})
            with self.subTest(key=key), self.assertRaises(ValueError):
                auth.validate_auth_execution(value, summary(25), EXPECTED)

    def test_nested_case_or_missing_tree_is_rejected(self):
        value = tree(EXPECTED)
        cases(value)[0]["children"] = [copy.deepcopy(cases(value)[1])]
        for invalid in (value, dict(devices=[{}], testPlanConfigurations=[{}], testNodes=[])):
            with self.assertRaises(ValueError):
                auth.validate_auth_execution(invalid, summary(25), EXPECTED)

    def test_missing_wrong_or_duplicate_source_inventory_is_rejected(self):
        for source in ("class AuthStateTests: XCTestCase {}", SOURCE.replace("class AuthStateTests", "class OtherTests"),
                       SOURCE + "\nfunc " + EXPECTED[0] + "() {}\n"):
            with self.assertRaises(ValueError):
                auth.auth_test_names(source)


if __name__ == "__main__":
    unittest.main()

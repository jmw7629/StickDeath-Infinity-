"""Exercise actual budget validation without launching or claiming an iOS run."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sdi_test_budget", ROOT / "scripts/native-smoke/test_budget.py")
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)
COMMAND = ["xcodebuild", "test-without-building", "-test-timeouts-enabled", "YES",
           "-default-test-execution-time-allowance", "180", "-maximum-test-execution-time-allowance", "180",
           "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1"]


def fixture(count):
    return "final class StudioSmokeUITests: XCTestCase {\n" + "\n".join(
        "    func testCase%d() throws {}" % i for i in range(count)) + "\n}"


class NativeSuiteBudget(unittest.TestCase):
    def test_all_checked_in_native_cases_are_preserved(self):
        source = (ROOT / "Tests/NativeUI/StudioSmokeUITests.swift").read_text()
        value = budget.build_test_budget(source, COMMAND)
        self.assertIn("testFrameContextIdentityDuplicateUndoReorderAndColdReopen", value["testNames"])
        self.assertIn("testImageCanvasDragUndoAndColdReopen", value["testNames"])
        self.assertEqual(value["suiteSeconds"], value["testCount"] * 180 + 300)
        self.assertEqual((value["retries"], value["parallelSimulators"]), (0, 1))

    def test_per_case_capacity_is_available_and_global_bound_stays_finite(self):
        for count in (1, 49, 50, 60):
            value = budget.build_test_budget(fixture(count), COMMAND)
            self.assertEqual(value["suiteSeconds"], count * 180 + 300)
            self.assertLessEqual(value["suiteSeconds"] + 25 * 60, 210 * 60)
        self.assertEqual(budget.build_test_budget(fixture(50), COMMAND)["suiteSeconds"], 9300)

    def test_empty_excess_duplicate_or_additional_suites_reject(self):
        for source in (fixture(0), fixture(61), fixture(2).replace("testCase1", "testCase0"),
                       fixture(1) + "\nclass AnotherSuite: XCTestCase {}"):
            with self.subTest(source=source[:60]), self.assertRaises(ValueError):
                budget.build_test_budget(source, COMMAND)

    def test_retries_and_filtered_cases_reject(self):
        for extra in ("-only-testing:Suite/testA", "-skip-testing:Suite/testA", "-test-iterations",
                      "-retry-tests-on-failure", "-run-tests-until-failure", "-maximum-test-iterations=2"):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                budget.build_test_budget(fixture(2), COMMAND + [extra])

    def test_timeouts_and_single_simulator_cannot_be_disabled_or_duplicated(self):
        for flag in ("-test-timeouts-enabled", "-default-test-execution-time-allowance",
                     "-maximum-test-execution-time-allowance", "-parallel-testing-enabled",
                     "-maximum-concurrent-test-simulator-destinations"):
            index = COMMAND.index(flag)
            variants = [COMMAND[:index] + COMMAND[index + 2:], COMMAND + [flag, COMMAND[index + 1]],
                        COMMAND[:index + 1] + ["invalid"] + COMMAND[index + 2:]]
            for command in variants:
                with self.subTest(flag=flag, command=command), self.assertRaises(ValueError):
                    budget.build_test_budget(fixture(2), command)

    def test_inventory_digest_changes_with_source(self):
        before = budget.build_test_budget(fixture(2), COMMAND)
        after = budget.build_test_budget(fixture(2) + "\n// a source change", COMMAND)
        self.assertEqual(before["testNames"], after["testNames"])
        self.assertNotEqual(before["sourceSHA256"], after["sourceSHA256"])


if __name__ == "__main__":
    unittest.main()

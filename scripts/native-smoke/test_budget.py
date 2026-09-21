"""Bound the complete native suite without dropping cases or enabling retries."""
import hashlib
import re

PER_CASE_SECONDS = 180
MAXIMUM_CASES = 60
SUITE_OVERHEAD_SECONDS = 300


def build_test_budget(source: str, command: list[str]) -> dict:
    classes = re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", source)
    names = re.findall(r"^\s*func\s+(test\w+)\s*\(", source, re.MULTILINE)
    if classes != ["StudioSmokeUITests"] or not 1 <= len(names) <= MAXIMUM_CASES:
        raise ValueError("Expected one native suite with 1...60 cases; split a larger suite explicitly")
    if len(names) != len(set(names)):
        raise ValueError("Duplicate native test names cannot define a complete inventory")
    for prefix in ("-only-testing", "-skip-testing", "-test-iterations", "-retry-tests-on-failure",
                   "-run-tests-until-failure", "-maximum-test-iterations"):
        if any(arg == prefix or arg.startswith(prefix + ":") or arg.startswith(prefix + "=") for arg in command):
            raise ValueError("Native verification cannot filter or retry cases")
    required = {"-test-timeouts-enabled": "YES",
                "-default-test-execution-time-allowance": str(PER_CASE_SECONDS),
                "-maximum-test-execution-time-allowance": str(PER_CASE_SECONDS),
                "-parallel-testing-enabled": "NO",
                "-maximum-concurrent-test-simulator-destinations": "1"}
    for flag, value in required.items():
        if command.count(flag) != 1:
            raise ValueError("Native verification requires one explicit " + flag)
        index = command.index(flag)
        if index + 1 == len(command) or command[index + 1] != value:
            raise ValueError("Native verification must preserve " + flag + " " + value)
    return {"testNames": names, "testCount": len(names), "perCaseSeconds": PER_CASE_SECONDS,
            "suiteOverheadSeconds": SUITE_OVERHEAD_SECONDS,
            "suiteSeconds": len(names) * PER_CASE_SECONDS + SUITE_OVERHEAD_SECONDS,
            "maximumCases": MAXIMUM_CASES, "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(),
            "retries": 0, "parallelSimulators": 1}

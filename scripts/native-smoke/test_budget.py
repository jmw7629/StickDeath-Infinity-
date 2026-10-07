"""Bound the complete native suite without dropping cases or enabling retries."""
import hashlib
import re

PER_CASE_SECONDS = 180
MAXIMUM_CASE_SECONDS = 240
EXTENDED_CASE_SECONDS = {
    "testBucketFillPopupUndoSaveReopenAndPNG": 240,
    "testImagePlacementCancelApplyUndoAndColdReopen": 240,
    "testImageQuarterTurnsUndoAndColdReopen": 240,
}
# Includes editable tween/easing/undo/cold-reopen coverage. Adding a
# journey changes the total inventory budget, never another case's allowance.
MAXIMUM_CASES = 74
SUITE_OVERHEAD_SECONDS = 300


def build_test_budget(source: str, command: list[str]) -> dict:
    classes = re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", source)
    names = re.findall(r"^\s*func\s+(test\w+)\s*\(", source, re.MULTILINE)
    if classes != ["StudioSmokeUITests"] or not 1 <= len(names) <= MAXIMUM_CASES:
        raise ValueError(f"Expected one native suite with 1...{MAXIMUM_CASES} cases; split a larger suite explicitly")
    if len(names) != len(set(names)):
        raise ValueError("Duplicate native test names cannot define a complete inventory")
    for prefix in ("-only-testing", "-skip-testing", "-test-iterations", "-retry-tests-on-failure",
                   "-run-tests-until-failure", "-maximum-test-iterations"):
        if any(arg == prefix or arg.startswith(prefix + ":") or arg.startswith(prefix + "=") for arg in command):
            raise ValueError("Native verification cannot filter or retry cases")
    required = {"-test-timeouts-enabled": "YES",
                "-default-test-execution-time-allowance": str(PER_CASE_SECONDS),
                "-maximum-test-execution-time-allowance": str(MAXIMUM_CASE_SECONDS),
                "-parallel-testing-enabled": "NO",
                "-maximum-concurrent-test-simulator-destinations": "1"}
    for flag, value in required.items():
        if command.count(flag) != 1:
            raise ValueError("Native verification requires one explicit " + flag)
        index = command.index(flag)
        if index + 1 == len(command) or command[index + 1] != value:
            raise ValueError("Native verification must preserve " + flag + " " + value)
    # Only the explicitly measured long journeys may opt into the longer ceiling.
    # Preserve all cases, assertions and the 180s default for every other case.
    declared = re.findall(r"executionTimeAllowance\s*=\s*([0-9]+)", source)
    extended = {name: seconds for name, seconds in EXTENDED_CASE_SECONDS.items() if name in names}
    if len(declared) != len(extended):
        raise ValueError("Unexpected or missing per-case native time allowance")
    for name, seconds in extended.items():
        header = r"func\s+" + re.escape(name) + r"\s*\(\)\s*throws\s*\{\s*(?://[^\n]*\n\s*)*executionTimeAllowance\s*=\s*" + str(seconds) + r"\b"
        if not re.search(header, source):
            raise ValueError("Missing explicit measured allowance for " + name)
    return {"testNames": names, "testCount": len(names), "perCaseSeconds": PER_CASE_SECONDS,
            "maximumCaseSeconds": MAXIMUM_CASE_SECONDS, "extendedCases": extended,
            "suiteOverheadSeconds": SUITE_OVERHEAD_SECONDS,
            "suiteSeconds": sum(extended.get(name, PER_CASE_SECONDS) for name in names) + SUITE_OVERHEAD_SECONDS,
            "maximumCases": MAXIMUM_CASES, "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(),
            "retries": 0, "parallelSimulators": 1}

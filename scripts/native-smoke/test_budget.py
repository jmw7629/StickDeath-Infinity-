"""Bound the complete native suite without dropping cases or enabling retries."""
import hashlib
import re

PER_CASE_SECONDS = 180
MAXIMUM_CASE_SECONDS = 240
EXTENDED_CASE_SECONDS = {
    "testImageDrawingOrderUndoAndColdReopen": 240,
    "testActiveLayerImageMarqueeDeleteUndoAndColdReopen": 240,
    "testSpatterSelectedAudioPlacementUndoAndColdReopen": 240,

    "testSelectedImageAlphaFillUndoAndColdReopen": 240,
    "testImageWandRegionCopyDeletePasteUndoAndColdReopen": 240,
    "testMixedArtworkCopyCutPasteUndoAndColdReopen": 240,
    "testMixedDrawingImageMoveDeleteUndoAndColdReopen": 240,
    "testBucketFillPopupUndoSaveReopenAndPNG": 240,
    "testImagePlacementCancelApplyUndoAndColdReopen": 240,
    "testImageQuarterTurnsUndoAndColdReopen": 240,
}
# Includes real rendered-MP4 Files save/re-export/cold-readback coverage. Adding a
# journey changes the total inventory budget, never another case's allowance.
MAXIMUM_CASES = 102
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
    # Only the explicitly bounded long journeys may opt into the longer ceiling.
    # Preserve all cases, assertions and the 180s default for every other case.
    declared = re.findall(r"executionTimeAllowance\s*=\s*([0-9]+)", source)
    extended = {name: seconds for name, seconds in EXTENDED_CASE_SECONDS.items() if name in names}
    if len(declared) != len(extended):
        raise ValueError("Unexpected or missing per-case native time allowance")
    for name, seconds in extended.items():
        header = r"func\s+" + re.escape(name) + r"\s*\(\)\s*throws\s*\{\s*(?://[^\n]*\n\s*)*executionTimeAllowance\s*=\s*" + str(seconds) + r"\b"
        if not re.search(header, source):
            raise ValueError("Missing explicit bounded allowance for " + name)
    return {"testNames": names, "testCount": len(names), "perCaseSeconds": PER_CASE_SECONDS,
            "maximumCaseSeconds": MAXIMUM_CASE_SECONDS, "extendedCases": extended,
            "suiteOverheadSeconds": SUITE_OVERHEAD_SECONDS,
            "suiteSeconds": sum(extended.get(name, PER_CASE_SECONDS) for name in names) + SUITE_OVERHEAD_SECONDS,
            "maximumCases": MAXIMUM_CASES, "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(),
            "retries": 0, "parallelSimulators": 1}


# Only this function owns selectors. The unsharded validator still rejects all
# caller-supplied filters before constructing the deterministic partition.
def build_shard_budget(source: str, command: list[str], index: int, count: int = 2) -> tuple[dict, list[str]]:
    if type(index) is not int or count != 2 or type(count) is not int or index not in (0, 1):
        raise ValueError("Native UI requires exactly two shards, numbered zero and one")
    full = build_test_budget(source, command)
    if full["testCount"] != MAXIMUM_CASES:
        raise ValueError("Sharded CI requires the complete reviewed inventory")
    names = sorted(full["testNames"])
    assigned = names[index::count]
    value = dict(full, fullTestNames=names, fullTestCount=len(names),
                 testNames=assigned, testCount=len(assigned), shardIndex=index, shardCount=count,
                 suiteSeconds=sum(EXTENDED_CASE_SECONDS.get(n, PER_CASE_SECONDS) for n in assigned) + SUITE_OVERHEAD_SECONDS)
    value["extendedCases"] = {n: EXTENDED_CASE_SECONDS[n] for n in assigned if n in EXTENDED_CASE_SECONDS}
    value["assignmentSHA256"] = hashlib.sha256("\n".join(assigned).encode()).hexdigest()
    selectors = ["-only-testing:StickDeathInfinityUITests/StudioSmokeUITests/" + n for n in assigned]
    return value, command + selectors

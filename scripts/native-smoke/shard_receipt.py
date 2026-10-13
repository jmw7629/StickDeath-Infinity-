"""Fail-closed XCTest shard coverage and aggregate gate; no simulator operations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from test_budget import build_shard_budget

COMMAND = ["xcodebuild", "test-without-building", "-test-timeouts-enabled", "YES",
           "-default-test-execution-time-allowance", "180", "-maximum-test-execution-time-allowance", "240",
           "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1"]
COMMON_GATES = ("build", "native-smoke", "setup-upload", "smoke-upload")
OWNER_GATES = ("native-review-rules", "native-review-app", "native-review-upload", "native-auth", "auth-upload")
PREFIX = "test://com.apple.xcode/StickDeathInfinity/StickDeathInfinityUITests/StudioSmokeUITests/"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def actual_tests(tree):
    """Use XCTest's actual case identifiers, not display counts or log markers.

    Runtime warnings may be children of passed cases. Other test descendants,
    repeated configurations/devices and unknown node kinds fail closed.
    """
    if len(tree.get("devices", [])) != 1 or len(tree.get("testPlanConfigurations", [])) != 1:
        raise ValueError("Exactly one device and test-plan configuration are required")
    cases = []
    def walk(node, inside_case=False):
        kind = node.get("nodeType")
        if kind == "Test Case":
            if inside_case:
                raise ValueError("Repeated or nested case execution is unsupported")
            url = node.get("nodeIdentifierURL", "")
            name = url.removeprefix(PREFIX)
            if not url.startswith(PREFIX) or not re.fullmatch(r"test\w+", name):
                raise ValueError("Unexpected actual test target/class/identifier")
            if node.get("nodeIdentifier") != "StudioSmokeUITests/" + name + "()":
                raise ValueError("Conflicting XCTest case identifiers")
            cases.append({"name": name, "result": node.get("result")})
            inside_case = True
        elif kind not in ("Test Plan", "UI test bundle", "Test Suite", "Runtime Warning", "Failure Message"):
            raise ValueError("Unknown XCTest tree node: " + str(kind))
        elif inside_case and kind not in ("Runtime Warning", "Failure Message"):
            raise ValueError("Unexpected case execution descendants")
        for child in node.get("children", []):
            walk(child, inside_case)
    nodes = tree.get("testNodes")
    if not isinstance(nodes, list) or not nodes:
        raise ValueError("Missing actual XCTest nodes")
    for node in nodes:
        walk(node)
    if not cases:
        raise ValueError("Missing actual XCTest cases")
    return cases


def validate_execution(cases, summary, assigned):
    names = [c["name"] for c in cases]
    if len(names) != len(set(names)) or sorted(names) != sorted(assigned):
        raise ValueError("Actual XCTest IDs differ from the exact assigned inventory")
    if any(c["result"] != "Passed" for c in cases):
        raise ValueError("Every assigned XCTest must pass; failed/skipped/unknown cases remain red")
    if summary.get("result") != "Passed" or summary.get("expectedFailures") != 0 or summary.get("totalTestCount") != len(assigned):
        raise ValueError("Original XCTest summary is not a complete ordinary pass")
    if (summary.get("passedTests"), summary.get("failedTests"), summary.get("skippedTests")) != (len(assigned), 0, 0):
        raise ValueError("Original summary disagrees with complete passing execution")


def validate_gates(gates, index):
    for key in COMMON_GATES + (OWNER_GATES if index == 0 else ()):
        if gates.get(key) != "success":
            raise ValueError("Mandatory native gate did not succeed: " + key)
    if index == 1 and any(gates.get(k) != "skipped" for k in OWNER_GATES):
        raise ValueError("Auth/app packaging must execute only on shard zero")


def identity(commit, run_id, attempt):
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or not re.fullmatch(r"[1-9][0-9]*", run_id) or not re.fullmatch(r"[1-9][0-9]*", attempt):
        raise ValueError("Exact source/run/attempt identity is required")
    return {"sourceCommit": commit, "runID": run_id, "runAttempt": attempt}


def collect(source, evidence, index, binding, gates):
    budget, _ = build_shard_budget(source, COMMAND, index)
    receipt = dict(binding, version=1, shardIndex=index, shardCount=2,
                   sourceSHA256=budget["sourceSHA256"], assignmentSHA256=budget["assignmentSHA256"],
                   fullTestNames=budget["fullTestNames"], assignedTestNames=budget["testNames"],
                   gates=gates, passed=False, errors=[])
    try:
        recorded = json.loads((evidence / "ui-test-budget.json").read_text())
        if recorded != dict(budget, sourceCommit=binding["sourceCommit"]):
            raise ValueError("Recorded runner assignment/source differs from expected shard")
        if json.loads((evidence / "source-and-config.json").read_text()).get("sourceCommit") != binding["sourceCommit"]:
            raise ValueError("Prepared app source mismatch")
        tree_path, summary_path = evidence / "test-tree.json", evidence / "test-summary.json"
        receipt["treeSHA256"], receipt["summarySHA256"] = digest(tree_path), digest(summary_path)
        receipt["actualTests"] = actual_tests(json.loads(tree_path.read_text()))
        receipt["summary"] = json.loads(summary_path.read_text())
        validate_execution(receipt["actualTests"], receipt["summary"], budget["testNames"])
        validate_gates(gates, index)
        receipt["passed"] = True
    except (OSError, ValueError, KeyError, TypeError) as error:
        receipt["errors"].append(str(error))
    return receipt


def aggregate(source, receipts, binding, dependency_results):
    if set(dependency_results) != {"source-security", "spatter-production-tests", "native-production-tests", "native-ios-shards"} or any(v != "success" for v in dependency_results.values()):
        raise ValueError("A mandatory prerequisite/shard job did not succeed")
    if len(receipts) != 2 or sorted(r.get("shardIndex", -1) for r in receipts) != [0, 1]:
        raise ValueError("Exactly one receipt per native shard is required")
    union = []
    for receipt in receipts:
        index = receipt["shardIndex"]
        expected, _ = build_shard_budget(source, COMMAND, index)
        if any(receipt.get(k) != v for k, v in binding.items()):
            raise ValueError("Shard source/run/attempt mismatch")
        if receipt.get("version") != 1 or receipt.get("shardCount") != 2 or receipt.get("passed") is not True or receipt.get("errors") != []:
            raise ValueError("Incomplete/failed shard receipt")
        for key, value in (("sourceSHA256", expected["sourceSHA256"]), ("assignmentSHA256", expected["assignmentSHA256"]),
                           ("fullTestNames", expected["fullTestNames"]), ("assignedTestNames", expected["testNames"])):
            if receipt.get(key) != value:
                raise ValueError("Shard inventory/digest mismatch: " + key)
        for key in ("treeSHA256", "summarySHA256"):
            if not re.fullmatch(r"[0-9a-f]{64}", receipt.get(key, "")):
                raise ValueError("Missing original XCTest evidence digest")
        validate_execution(receipt["actualTests"], receipt["summary"], expected["testNames"])
        validate_gates(receipt["gates"], index)
        union += [c["name"] for c in receipt["actualTests"]]
    if len(union) != len(set(union)) or sorted(union) != expected["fullTestNames"]:
        raise ValueError("Shard execution union is incomplete or overlaps")
    return dict(binding, passed=True, actualPassedTests=len(union), failedTests=0, skippedTests=0,
                sourceSHA256=expected["sourceSHA256"], actualTestNames=sorted(union))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("collect", "aggregate"))
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--index", type=int)
    args = parser.parse_args()
    binding = identity(args.commit, os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"])
    if args.output.exists():
        raise ValueError("Never overwrite an existing native coverage receipt")
    if args.mode == "collect":
        steps = json.loads(os.environ["SDI_STEP_RESULTS"])
        gates = {k: steps.get(k, {}).get("outcome", "missing") for k in COMMON_GATES + OWNER_GATES}
        result = collect(args.source.read_text(), args.input, args.index, binding, gates)
    else:
        paths = list(args.input.rglob("receipt.json"))
        if any(p.stat().st_size > 1024 * 1024 for p in paths):
            raise ValueError("Unexpected oversized shard receipt")
        results = json.loads(os.environ["SDI_DEPENDENCY_RESULTS"])
        result = aggregate(args.source.read_text(), [json.loads(p.read_text()) for p in paths], binding,
                           {k: v["result"] for k, v in results.items()})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())

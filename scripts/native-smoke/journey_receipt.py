#!/usr/bin/env python3
"""Fail-closed receipts for the native journey job (#264, #265, #273).

The journey job runs two suites outside the sharded smoke inventory:

* ``JourneyUITests`` (Tests/NativeUI/JourneyUITests.swift) on one fresh phone
  and one fresh iPad, against the same offline build the shards use;
* ``ServiceJourneyTests`` (Tests/AuthState/ServiceJourneyTests.swift), hosted
  unit tests over a local URLProtocol fixture, on the phone only.

Expected cases come from the checked-in sources, actual cases from XCTest's
own result tree. Every expected case must run exactly once and pass; nothing
is counted from logs. This module never touches a simulator. The sharded smoke
receipts (shard_receipt.py) are unaffected: the shards select only
StudioSmokeUITests cases by explicit identifier.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SUITES = {
    "ui": ("Tests/NativeUI/JourneyUITests.swift", "JourneyUITests", "StickDeathInfinityUITests"),
    "service": ("Tests/AuthState/ServiceJourneyTests.swift", "ServiceJourneyTests", "StickDeathInfinityAuthTests"),
}
# Which suites each simulator family must run. Hosted service journeys do not
# depend on screen size, so they run once, on the phone.
DEVICE_SUITES = {"iphone": ("ui", "service"), "ipad": ("ui",)}
PER_CASE_SECONDS = 180
MAXIMUM_CASE_SECONDS = 240
SERVICE_CASE_SECONDS = 60
SUITE_OVERHEAD_SECONDS = 300
MAXIMUM_CASES = 20


def expected_names(source, cls):
    classes = re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", source)
    names = re.findall(r"^\s*func\s+(test\w+)\s*\(", source, re.MULTILINE)
    if classes != [cls] or not 1 <= len(names) <= MAXIMUM_CASES or len(names) != len(set(names)):
        raise ValueError(f"Expected one {cls} suite with 1...{MAXIMUM_CASES} uniquely named cases")
    return sorted(names)


def suite_inventory(root=ROOT):
    return {key: expected_names((root / path).read_text(), cls) for key, (path, cls, _target) in SUITES.items()}


def ui_timeout_seconds(count):
    return count * PER_CASE_SECONDS + SUITE_OVERHEAD_SECONDS


def service_timeout_seconds(count):
    return count * SERVICE_CASE_SECONDS + SUITE_OVERHEAD_SECONDS


def selector(key):
    _path, cls, target = SUITES[key]
    return f"-only-testing:{target}/{cls}"


def actual_cases(tree, key):
    """Case names from XCTest's tree. One device and configuration; no repeats."""
    _path, cls, _target = SUITES[key]
    if len(tree.get("devices", [])) != 1 or len(tree.get("testPlanConfigurations", [])) != 1:
        raise ValueError("Exactly one device and test-plan configuration are required")
    cases = []

    def walk(node, inside):
        kind = node.get("nodeType")
        if kind == "Test Case":
            if inside:
                raise ValueError("Repeated or nested case execution is unsupported")
            identifier = node.get("nodeIdentifier", "")
            match = re.fullmatch(re.escape(cls) + r"/(test\w+)\(\)", identifier)
            if not match:
                raise ValueError("Unexpected test class or identifier: " + identifier)
            cases.append({"name": match.group(1), "result": node.get("result")})
            inside = True
        elif kind not in ("Test Plan", "UI test bundle", "Unit test bundle", "Test Suite", "Runtime Warning",
                          "Failure Message", "Attachment", "Repetition", "Arguments"):
            raise ValueError("Unknown XCTest tree node: " + str(kind))
        elif inside and kind not in ("Runtime Warning", "Failure Message", "Attachment"):
            raise ValueError("Unexpected case execution descendants")
        for child in node.get("children", []):
            walk(child, inside)

    nodes = tree.get("testNodes")
    if not isinstance(nodes, list) or not nodes:
        raise ValueError("Missing actual XCTest nodes")
    for node in nodes:
        walk(node, False)
    return cases


def evaluate(key, expected, exit_code, tree, summary):
    """One suite's outcome. Any error leaves it failed with the reason recorded."""
    result = {"suite": key, "expected": expected, "exitCode": exit_code, "passed": False, "errors": []}
    try:
        cases = actual_cases(tree, key)
        result["actual"] = cases
        names = [c["name"] for c in cases]
        if len(names) != len(set(names)) or sorted(names) != expected:
            raise ValueError("Actual XCTest cases differ from the checked-in suite")
        if any(c["result"] != "Passed" for c in cases):
            raise ValueError("Every journey case must pass; failed, skipped or unknown cases stay red")
        counts = (summary.get("passedTests"), summary.get("failedTests"), summary.get("skippedTests", 0))
        if summary.get("result") != "Passed" or counts != (len(expected), 0, 0) or summary.get("expectedFailures", 0) != 0:
            raise ValueError("XCTest summary is not a complete ordinary pass")
        if exit_code != 0:
            raise ValueError("xcodebuild exited with " + str(exit_code))
        result["passed"] = True
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        result["errors"].append(str(error))
    return result


def identity(commit, run_id, attempt):
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or not re.fullmatch(r"[1-9][0-9]*", run_id) or not re.fullmatch(r"[1-9][0-9]*", attempt):
        raise ValueError("Exact source/run/attempt identity is required")
    return {"sourceCommit": commit, "runID": run_id, "runAttempt": attempt}


def receipt(binding, device, suites):
    if device not in DEVICE_SUITES:
        raise ValueError("Unknown simulator family")
    keys = sorted(s["suite"] for s in suites)
    passed = keys == sorted(DEVICE_SUITES[device]) and all(s["passed"] for s in suites)
    return dict(binding, version=1, device=device, suites=suites, passed=passed)


def aggregate(receipts, binding, inventory, dependency_results):
    if dependency_results.get("native-ios-journeys") != "success":
        raise ValueError("The native journey job did not succeed")
    devices = sorted(r.get("device", "") for r in receipts)
    if devices != sorted(DEVICE_SUITES):
        raise ValueError("Exactly one journey receipt per simulator family is required")
    total = 0
    for value in receipts:
        if any(value.get(k) != v for k, v in binding.items()) or value.get("version") != 1 or value.get("passed") is not True:
            raise ValueError("Journey receipt is failed or belongs to another source/run/attempt")
        suites = {s.get("suite"): s for s in value.get("suites", [])}
        if sorted(suites) != sorted(DEVICE_SUITES[value["device"]]):
            raise ValueError("Journey receipt suites differ from the required set")
        for key, suite in suites.items():
            names = sorted(c.get("name") for c in suite.get("actual", []) if c.get("result") == "Passed")
            if suite.get("passed") is not True or suite.get("errors") != [] or suite.get("expected") != inventory[key] or names != inventory[key]:
                raise ValueError("Journey suite incomplete or stale: " + value["device"] + "/" + key)
            total += len(names)
    return dict(binding, passed=True, devices=devices, passedJourneyCases=total)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("aggregate",))
    parser.add_argument("--commit", required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binding = identity(args.commit, os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"])
    if args.output.exists():
        raise ValueError("Never overwrite an existing journey receipt")
    paths = list(args.input.rglob("receipt.json")) if args.input.is_dir() else []
    if any(p.stat().st_size > 1024 * 1024 for p in paths):
        raise ValueError("Unexpected oversized journey receipt")
    dependencies = {k: v["result"] for k, v in json.loads(os.environ["SDI_DEPENDENCY_RESULTS"]).items()}
    try:
        result = aggregate([json.loads(p.read_text()) for p in paths], binding, suite_inventory(), dependencies)
    except ValueError as error:
        result = dict(binding, passed=False, errors=[str(error)])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())

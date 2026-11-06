#!/usr/bin/env python3
"""Run the real auth service tests on the already-owned CI simulator."""
import json
import hashlib
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time


def auth_test_names(source):
    classes = re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", source)
    names = re.findall(r"^\s*func\s+(test\w+)\s*\(", source, re.MULTILINE)
    if classes != ["AuthStateTests"] or not names or len(names) != len(set(names)):
        raise ValueError("Expected one AuthStateTests suite with unique source test names")
    return sorted(names)


def validate_auth_execution(tree, summary, expected):
    """Require each exact source case once; counts alone cannot prove coverage."""
    if len(tree.get("devices", [])) != 1 or len(tree.get("testPlanConfigurations", [])) != 1:
        raise ValueError("Auth execution requires one device and test-plan configuration")
    cases = []

    def walk(node, inside_case=False):
        kind = node.get("nodeType")
        if kind == "Test Case":
            if inside_case:
                raise ValueError("Nested auth case execution is unsupported")
            match = re.fullmatch(r"AuthStateTests/(test\w+)\(\)", node.get("nodeIdentifier", ""))
            if not match:
                raise ValueError("Unexpected actual auth target/class/test identifier")
            name = match[1]
            url = node.get("nodeIdentifierURL", "")
            if not url.startswith("test://com.apple.xcode/") or not url.endswith(
                    "/StickDeathInfinityAuthTests/AuthStateTests/" + name):
                raise ValueError("Actual auth case URL differs from its target/class/identifier")
            cases.append((name, node.get("result")))
            inside_case = True
        elif kind not in ("Test Plan", "Unit test bundle", "Test Suite", "Runtime Warning", "Failure Message"):
            raise ValueError("Unknown auth XCTest tree node: " + str(kind))
        elif inside_case and kind not in ("Runtime Warning", "Failure Message"):
            raise ValueError("Unexpected auth case execution descendants")
        for child in node.get("children", []):
            walk(child, inside_case)

    nodes = tree.get("testNodes")
    if not isinstance(nodes, list) or not nodes:
        raise ValueError("Missing actual auth XCTest nodes")
    for node in nodes:
        walk(node)
    names = [name for name, _ in cases]
    if len(names) != len(set(names)) or sorted(names) != expected:
        raise ValueError("Actual auth XCTest IDs differ from the exact source inventory")
    if any(result != "Passed" for _, result in cases):
        raise ValueError("Every source auth test must pass without skips or unknown results")
    if (summary.get("result"), summary.get("expectedFailures"), summary.get("totalTestCount"),
            summary.get("passedTests"), summary.get("failedTests"), summary.get("skippedTests")) != (
            "Passed", 0, len(expected), len(expected), 0, 0):
        raise ValueError("Auth summary disagrees with complete passing source execution")


def run(command, log, timeout):
    with log.open("xb") as output:
        child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        try:
            return child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            return 124


def main():
    assert os.environ.get("GITHUB_ACTIONS") == "true", "Approved CI runner required"
    temporary = Path(os.environ["RUNNER_TEMP"])
    udid = os.environ["SDI_SMOKE_SIMULATOR_UDID"]
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], check=True)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    source = (Path(__file__).resolve().parents[2] / "Tests/AuthState/AuthStateTests.swift").read_text()
    expected = auth_test_names(source)
    # The shared ownership validator accepts only isolated native-smoke paths.
    # Keep auth evidence distinct without bypassing that path/marker contract.
    evidence = Path(tempfile.mkdtemp(prefix="sdi-native-smoke.auth.", dir=temporary))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"artifact_path={evidence}\n")
    subprocess.run(["python3", str(Path(__file__).with_name("select_simulator.py")),
                    "--copy-marker", str(evidence), "--expected-udid", udid,
                    "--source", commit], check=True)
    derived = temporary / "sdi-native-build"
    packages = derived / "SourcePackages"
    assert (packages / "checkouts").is_dir(), "Reuse existing package cache"
    result = evidence / "AuthState.xcresult"
    command = ["xcodebuild", "test", "-project", "StickDeathInfinity.xcodeproj",
               "-scheme", "StickDeathInfinityAuthTests", "-configuration", "Debug",
               # The bundle also hosts ServiceJourneyTests, which the separate
               # native-ios-journeys job runs; require this exact source suite.
               "-only-testing:StickDeathInfinityAuthTests/AuthStateTests",
               "-destination", f"platform=iOS Simulator,id={udid}",
               "-derivedDataPath", str(derived), "-clonedSourcePackagesDirPath", str(packages),
               "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
               "-skipPackageUpdates", "-jobs", "2",
               "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
               "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "30",
               "-maximum-test-execution-time-allowance", "60", "-resultBundlePath", str(result),
               "CODE_SIGNING_ALLOWED=NO", "SPATTER_BACKEND_URL=", "SUPABASE_URL=",
               "SUPABASE_PUBLISHABLE_KEY=", "SUPABASE_ANON_KEY=", "LIVEKIT_WS_URL=",
               "SDI_OAUTH_PROVIDERS=", "SDI_MICROSOFT_TENANT="]
    start = time.monotonic()
    code = run(command, evidence / "auth-tests.log", 900)
    receipt = {"source": commit, "exitCode": code, "seconds": time.monotonic() - start,
               "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(),
               "expectedTestNames": expected,
               "runtimeVerified": False}
    try:
        exported = run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)],
                       evidence / "summary.json", 60)
        exported_tree = run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result)],
                            evidence / "test-tree.json", 60)
        if code == 0 and exported == 0 and exported_tree == 0:
            summary = json.loads((evidence / "summary.json").read_text())
            tree = json.loads((evidence / "test-tree.json").read_text())
            validate_auth_execution(tree, summary, expected)
            receipt["runtimeVerified"] = True
    except (OSError, ValueError, TypeError, KeyError) as error:
        receipt["verificationError"] = str(error)[:400]
    finally:
        (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return code if code else (0 if receipt["runtimeVerified"] else 3)


if __name__ == "__main__":
    raise SystemExit(main())

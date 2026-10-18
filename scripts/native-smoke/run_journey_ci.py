#!/usr/bin/env python3
"""Run the native journey suites on the already-owned CI simulator (#264, #265).

Phone and iPad both run JourneyUITests against the offline smoke build
(empty public settings, verified by prepare_offline_run.py). The phone also
runs the hosted ServiceJourneyTests over a local URLProtocol fixture. The
receipt names the exact source, run and attempt; journey_receipt.py
aggregates both families in the native-ios-build gate.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import journey_receipt  # noqa: E402
from prepare_offline_run import prepare  # noqa: E402

EMPTY_SETTINGS = ["CODE_SIGNING_ALLOWED=NO", "SPATTER_BACKEND_URL=", "SUPABASE_URL=", "SUPABASE_PUBLISHABLE_KEY=",
                  "SUPABASE_ANON_KEY=", "LIVEKIT_WS_URL=", "SDI_OAUTH_PROVIDERS=", "SDI_MICROSOFT_TENANT="]


def run(command, log, timeout):
    """Bounded child in its own process group; SIGINT first so xcresult can finalize."""
    with log.open("xb") as output:
        child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            for sig, grace in ((signal.SIGINT, 30), (signal.SIGTERM, 10), (signal.SIGKILL, 10)):
                os.killpg(child.pid, sig)
                try:
                    child.wait(timeout=grace)
                    break
                except subprocess.TimeoutExpired:
                    continue
            return 124


def export(result, evidence, stem):
    """Original XCTest tree and summary; missing evidence stays a failure."""
    tree = summary = {}
    for kind, name in (("tests", stem + "-tree.json"), ("summary", stem + "-summary.json")):
        code = run(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", str(result)], evidence / name, 60)
        if code == 0:
            value = json.loads((evidence / name).read_text())
            if kind == "tests":
                tree = value
            else:
                summary = value
    return tree, summary


def main():
    assert os.environ.get("GITHUB_ACTIONS") == "true", "Approved CI runner required"
    temporary = Path(os.environ["RUNNER_TEMP"])
    udid = os.environ["SDI_SMOKE_SIMULATOR_UDID"]
    device = os.environ["SDI_JOURNEY_DEVICE"]
    if device not in journey_receipt.DEVICE_SUITES:
        raise ValueError("Unknown simulator family")
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], check=True)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    binding = journey_receipt.identity(commit, os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"])
    inventory = journey_receipt.suite_inventory()
    # The shared ownership validator accepts only isolated native-smoke paths.
    evidence = Path(tempfile.mkdtemp(prefix="sdi-native-smoke.journey.", dir=temporary))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"artifact_path={evidence}\n")
    subprocess.run(["python3", str(Path(__file__).with_name("select_simulator.py")), "--copy-marker", str(evidence),
                    "--expected-udid", udid, "--source", commit], check=True)
    derived = temporary / "sdi-native-build"
    packages = derived / "SourcePackages"
    assert (packages / "checkouts").is_dir(), "Reuse the successful native build package cache"
    destination = f"platform=iOS Simulator,id={udid}"
    common = ["-derivedDataPath", str(derived), "-clonedSourcePackagesDirPath", str(packages),
              "-disableAutomaticPackageResolution", "-skipPackageUpdates", "-jobs", "2"]
    suites = []

    # UI journeys: same offline preflight as the smoke shards, then only JourneyUITests.
    build = run(["xcodebuild", "build-for-testing", "-project", "StickDeathInfinity.xcodeproj",
                 "-scheme", "StickDeathInfinity", "-configuration", "Debug", "-destination", destination,
                 *common, "-only-testing:StickDeathInfinityUITests", *EMPTY_SETTINGS],
                evidence / "build-for-testing.log", 1500)
    ui_exit = build
    ui_result = evidence / "JourneyUI.xcresult"
    if build == 0:
        profiles = [p for p in (derived / "Build/Products").glob("*.xctestrun") if not p.name.startswith("SDI-")]
        if len(profiles) != 1:
            raise ValueError("Expected one generated xctestrun profile")
        prepared = profiles[0].with_name("SDI-Journey-" + evidence.name.replace(".", "-") + ".xctestrun")
        metadata = prepare(profiles[0], prepared, commit)
        (evidence / "source-and-config.json").write_text(json.dumps(metadata, indent=2) + "\n")
        ui_exit = run(["xcodebuild", "test-without-building", "-xctestrun", str(prepared), "-destination", destination,
                       journey_receipt.selector("ui"), "-resultBundlePath", str(ui_result),
                       "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
                       "-test-timeouts-enabled", "YES",
                       "-default-test-execution-time-allowance", str(journey_receipt.PER_CASE_SECONDS),
                       "-maximum-test-execution-time-allowance", str(journey_receipt.MAXIMUM_CASE_SECONDS)],
                      evidence / "journey-ui.log", journey_receipt.ui_timeout_seconds(len(inventory["ui"])))
    tree, summary = export(ui_result, evidence, "journey-ui") if ui_result.exists() else ({}, {})
    if ui_result.exists():
        run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(ui_result),
             "--output-path", str(evidence / "attachments")], evidence / "attachment-export.log", 120)
    suites.append(journey_receipt.evaluate("ui", inventory["ui"], ui_exit, tree, summary))

    if "service" in journey_receipt.DEVICE_SUITES[device]:
        service_result = evidence / "ServiceJourney.xcresult"
        service_exit = run(["xcodebuild", "test", "-project", "StickDeathInfinity.xcodeproj",
                            "-scheme", "StickDeathInfinityAuthTests", "-configuration", "Debug", "-destination", destination,
                            *common, journey_receipt.selector("service"),
                            "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
                            "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "30",
                            "-maximum-test-execution-time-allowance", str(journey_receipt.SERVICE_CASE_SECONDS),
                            "-resultBundlePath", str(service_result), *EMPTY_SETTINGS],
                           evidence / "service-journeys.log", journey_receipt.service_timeout_seconds(len(inventory["service"])))
        tree, summary = export(service_result, evidence, "service") if service_result.exists() else ({}, {})
        suites.append(journey_receipt.evaluate("service", inventory["service"], service_exit, tree, summary))

    value = journey_receipt.receipt(binding, device, suites)
    (evidence / "receipt.json").write_text(json.dumps(value, indent=2) + "\n")
    compact = temporary / "native-journey-receipt" / "receipt.json"
    compact.parent.mkdir(parents=True, exist_ok=False)
    compact.write_text(json.dumps(value, indent=2) + "\n")
    print(json.dumps({"device": device, "passed": value["passed"],
                      "suites": {s["suite"]: s["passed"] for s in suites}}))
    return 0 if value["passed"] else 3


if __name__ == "__main__":
    raise SystemExit(main())

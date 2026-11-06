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
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import journey_receipt  # noqa: E402
import select_simulator  # noqa: E402
from seed_diagnostics import run_bounded, result_projection  # noqa: E402
from prepare_offline_run import prepare, validated_app  # noqa: E402

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



def preinstall_owned_app(profile, evidence, udid, commit, ui_deadline):
    """Separate install/bootstrap setup; never start the target app process."""
    folder = evidence / "preinstall"
    folder.mkdir(mode=0o700)
    started = time.monotonic()
    deadline = min(ui_deadline, started + 240)
    work_deadline = deadline - 60
    report = {"sourceCommit": commit, "simulatorUDID": udid, "passed": False,
              "setupMaximumSeconds": 240, "workMaximumSeconds": 180,
              "cleanupReserveSeconds": 60, "steps": [], "installAttempts": 0,
              "targetAppPrelaunches": 0, "automaticRetries": 0,
              "cleanup": "not-needed"}
    owned_confirmed = False

    def lease(stage):
        # Reuse the descriptor-bound existing validator before each action.
        checkpoint = evidence / ("sdi-native-smoke.preinstall-" + stage)
        checkpoint.mkdir(mode=0o700)
        select_simulator.copy_marker(checkpoint, udid, commit)
        data = (checkpoint / "fresh-simulator.json").read_bytes()
        if data != (evidence / "fresh-simulator.json").read_bytes():
            raise ValueError("Fresh Simulator ownership changed; preserve devices")
        return json.loads(data)["created"]

    def command(stage, argv, seconds, *, cleanup=False, cap=16 * 1024):
        limit = deadline if cleanup else work_deadline
        end = min(limit, time.monotonic() + seconds)
        result = run_bounded(argv, end, stdout_cap=cap, stderr_cap=16 * 1024)
        step = {"stage": stage, "argv": argv, **result_projection(result)}
        report["steps"].append(step)
        for name, data in (("stdout", result.stdout), ("stderr", result.stderr)):
            (folder / (stage + "." + name)).write_bytes(data)
        if (result.returncode != 0 or result.timed_out or result.spawn_error
                or not result.reaped or result.capture_incomplete
                or result.stdout_seen > cap or result.stderr_seen > 16 * 1024):
            raise RuntimeError("Bounded preinstall " + stage + " failed; no retry")
        return result.stdout

    def state(stage, *, cleanup=False):
        created = lease(stage)
        raw = command(stage, ["xcrun", "simctl", "list", "--json"], 30,
                      cleanup=cleanup, cap=select_simulator.INVENTORY_CAP)
        _, devices, _ = select_simulator.inventory(raw)
        found = [(runtime, device) for runtime, device in devices
                 if device["udid"].upper() == udid.upper()]
        if len(found) != 1:
            raise ValueError("Owned fresh Simulator is absent or ambiguous")
        runtime, device = found[0]
        if (runtime != created["runtime"] or device.get("name") != created["name"]
                or device.get("deviceTypeIdentifier") != created["deviceType"]
                or device.get("isAvailable") is not True
                or device.get("state") not in ("Shutdown", "Booted")):
            raise ValueError("Fresh Simulator identity/state changed")
        return device["state"]

    try:
        app = validated_app(profile)
        products = (Path(os.environ["RUNNER_TEMP"]) / "sdi-native-build/Build/Products").resolve(strict=True)
        if profile.parent.resolve() != products or not app.is_relative_to(products):
            raise ValueError("Preinstall must use this locked build's actual products")
        report["appBundleIdentifier"] = "com.willisbmb.StickDeathInfinity"
        report["offlineBuiltAppValidated"] = True
        if time.monotonic() >= work_deadline:
            raise TimeoutError("Existing UI budget cannot admit preinstall setup")
        initial = state("owned-before-boot")
        owned_confirmed = True
        if initial == "Shutdown":
            lease("before-boot")
            command("boot", ["xcrun", "simctl", "boot", udid], 30)
        lease("before-readiness")
        command("bootstatus", ["xcrun", "simctl", "bootstatus", udid, "-b"], 90)
        lease("before-install")
        report["installAttempts"] += 1
        command("install", ["xcrun", "simctl", "install", udid, str(app)], 60)
        lease("after-install")
        report.update(passed=True, installAcknowledged=True,
                      cleanup="Existing ephemeral CI teardown after journeys; no erase/delete")
    except Exception as error:
        report.update(errorClass=type(error).__name__, error=str(error)[:1000])
        if owned_confirmed:
            try:
                current = state("owned-before-failed-setup-cleanup", cleanup=True)
                if current == "Booted":
                    lease("before-failed-setup-shutdown")
                    command("owned-shutdown", ["xcrun", "simctl", "shutdown", udid],
                            30, cleanup=True)
                    report["cleanup"] = "Verified owned fresh Simulator shutdown after setup failure"
                else:
                    report["cleanup"] = "Verified owned fresh Simulator already shutdown"
            except Exception as cleanup_error:
                report["cleanup"] = {"state": "unavailable-preserve-devices",
                                     "errorClass": type(cleanup_error).__name__,
                                     "error": str(cleanup_error)[:1000]}
        else:
            report["cleanup"] = "No verified-owned boot action; preserve devices"
    finally:
        report["elapsedSeconds"] = time.monotonic() - started
        (folder / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"preinstallPassed": report["passed"],
                          "errorClass": report.get("errorClass"),
                          "steps": [{"stage": item["stage"], "returnCode": item["returnCode"],
                                     "timedOut": item["timedOut"]} for item in report["steps"]]}),
              flush=True)
    return report


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
              "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
              "-skipPackageUpdates", "-jobs", "2"]
    suites = []
    preinstall = None
    setup_failed = False

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
        ui_command = ["xcodebuild", "test-without-building", "-xctestrun", str(prepared), "-destination", destination,
                       journey_receipt.selector("ui"), "-resultBundlePath", str(ui_result),
                       "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
                       "-test-timeouts-enabled", "YES",
                       "-default-test-execution-time-allowance", str(journey_receipt.PER_CASE_SECONDS),
                       "-maximum-test-execution-time-allowance", str(journey_receipt.MAXIMUM_CASE_SECONDS)]
        ui_timeout = journey_receipt.ui_test_budget((journey_receipt.ROOT / journey_receipt.SUITES["ui"][0]).read_text(), ui_command)
        # Charge explicit boot/install setup to the existing300s UI overhead;
        # neither the suite's total allowance nor any case/job ceiling grows.
        ui_deadline = time.monotonic() + ui_timeout
        preinstall = preinstall_owned_app(prepared, evidence, udid, commit, ui_deadline)
        setup_failed = not preinstall["passed"]
        remaining = ui_deadline - time.monotonic()
        if setup_failed or remaining <= 0:
            ui_exit = 78  # Setup failure; xcodebuild UI command was not invoked.
            setup_failed = True
        else:
            ui_exit = run(ui_command, evidence / "journey-ui.log", remaining)
    tree, summary = export(ui_result, evidence, "journey-ui") if ui_result.exists() else ({}, {})
    if ui_result.exists():
        run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(ui_result),
             "--output-path", str(evidence / "attachments")], evidence / "attachment-export.log", 120)
    suites.append(journey_receipt.evaluate("ui", inventory["ui"], ui_exit, tree, summary))

    if "service" in journey_receipt.DEVICE_SUITES[device]:
        service_result = evidence / "ServiceJourney.xcresult"
        service_exit = 78 if setup_failed else run(["xcodebuild", "test", "-project", "StickDeathInfinity.xcodeproj",
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
    value["preinstallSetup"] = preinstall or {"passed": False, "state": "not-attempted-build-failed"}
    value["UICommandNotRunAfterSetupFailure"] = setup_failed
    (evidence / "receipt.json").write_text(json.dumps(value, indent=2) + "\n")
    compact = temporary / "native-journey-receipt" / "receipt.json"
    compact.parent.mkdir(parents=True, exist_ok=False)
    compact.write_text(json.dumps(value, indent=2) + "\n")
    print(json.dumps({"device": device, "passed": value["passed"],
                      "suites": {s["suite"]: s["passed"] for s in suites}}))
    return 0 if value["passed"] else 3


if __name__ == "__main__":
    raise SystemExit(main())

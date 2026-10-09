#!/usr/bin/env python3
"""Run a bounded UI-test command with a recording of the selected CI simulator."""
import argparse
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

from seed_image_fixture import seed_verified_fixture, wait_for_command_readiness
from seed_video_fixture import seed_video_fixture
from test_budget import build_test_budget, build_shard_budget


# Whole-file pin covers test bodies AND shared helpers. Unreviewed source changes
# retain both mandatory fixtures rather than silently omitting a new dependency.
FIXTURE_SOURCE_SHA256 = "c999dca250f6134c037b609073532719bc957dee68604e92094e60fe614241d6"
PHOTO_FIXTURE_CASE = "testPhotoImportUndoPersistenceAndRealPNGExport"
VIDEO_FIXTURE_CASE = "testRotoscopePhotosActualPlayheadUndoAndColdReopen"


def fixture_requirements(source: str, budget: dict, sharded: bool) -> dict:
    if not sharded or hashlib.sha256(source.encode()).hexdigest() != FIXTURE_SOURCE_SHA256:
        return {"image": True, "video": True, "reason": "all-tests-or-unreviewed-source"}
    assigned = set(budget["testNames"])
    inventory = set(budget["fullTestNames"])
    if not assigned or not assigned <= inventory or not {PHOTO_FIXTURE_CASE, VIDEO_FIXTURE_CASE} <= inventory:
        raise ValueError("Fixture plan requires complete validated test assignment")
    return {"image": PHOTO_FIXTURE_CASE in assigned, "video": VIDEO_FIXTURE_CASE in assigned,
            "reason": "reviewed-exact-source-assignment"}


def stop_owned_process(process: subprocess.Popen, grace_seconds: float = 30) -> int:
    """Finalize only a child retained by this invocation; never use a saved PID."""
    if process.poll() is not None:
        return process.wait()
    process.send_signal(signal.SIGINT)
    try:
        return process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            return process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            return process.wait(timeout=10)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--shard-index", type=int, default=os.environ.get("SDI_NATIVE_SHARD_INDEX"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise ValueError("Recording is scoped to the approved ephemeral CI runner")
    output = args.output.resolve()
    runner_temp = pathlib.Path(os.environ["RUNNER_TEMP"]).resolve()
    if not output.is_relative_to(runner_temp) or not output.is_dir():
        raise ValueError("Recording output must be an existing isolated runner-temp directory")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if command[:2] != ["xcodebuild", "test-without-building"]:
        raise ValueError("Only the prepared xcodebuild UI test command is supported")
    if not any("id=" + args.udid in part for part in command):
        raise ValueError("The recorded simulator must match the test destination")

    # Cases retain a hard 180s default; only reviewed named journeys allow 240s.
    # Budget the complete inventory or its explicit deterministic shard
    # from the exact checked-in inventory, so a growing suite cannot be cut
    # off by an unrelated smaller fixed deadline. No retries or caller-supplied filtering.
    source = pathlib.Path(__file__).resolve().parents[2] / "Tests/NativeUI/StudioSmokeUITests.swift"
    if args.shard_index is None:
        budget = build_test_budget(source.read_text(), command)
    else:
        budget, command = build_shard_budget(source.read_text(), command, args.shard_index)
        prepared = json.loads((output / "source-and-config.json").read_text())
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        if prepared.get("sourceCommit") != commit:
            raise ValueError("Prepared build source must match the shard checkout")
        budget["sourceCommit"] = commit
    (output / "ui-test-budget.json").write_text(json.dumps(budget, indent=2) + "\n")
    test_timeout_seconds = budget["suiteSeconds"]
    requirements = fixture_requirements(source.read_text(), budget, args.shard_index is not None)
    (output / "fixture-requirements.json").write_text(json.dumps(requirements, indent=2) + "\n")

    inventory = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], timeout=30))
    selected = [d for runtime, devices in inventory["devices"].items() if ".iOS-" in runtime
                for d in devices if d["udid"] == args.udid and d.get("isAvailable")]
    if len(selected) != 1:
        raise ValueError("Expected one available iOS simulator with the explicit destination ID")
    if selected[0]["state"] != "Booted":
        subprocess.run(["xcrun", "simctl", "boot", args.udid], check=True, timeout=60)
    subprocess.run(["xcrun", "simctl", "bootstatus", args.udid, "-b"], check=True, timeout=120)
    # Identity was validated above and the explicit target's native bootstatus
    # just succeeded. Re-enumerating every simulator here can stall CoreSimulator.
    # Keep the actual addmedia success and its own timeout as the seeding gate.
    fixture_error = None
    try:
        if requirements["image"] or requirements["video"]:
            wait_for_command_readiness(args.udid, output)
        if requirements["image"]:
            seed_verified_fixture(args.udid, output)
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        # The isolated target/boot/offline-app gates already passed. A Photos
        # fixture failure must still fail this job, but need not suppress the
        # unrelated drawing, persistence, toolbar and export UI evidence.
        # Run every test, including Photos; never skip or retry the failed seed.
        fixture_error = type(error).__name__
        print(json.dumps({"photoFixtureSeeded": False, "failureClass": fixture_error,
                          "mandatoryGateStillFailed": True, "allUITestsWillRun": args.shard_index is None,
                          "allAssignedUITestsWillRun": True, "shardIndex": args.shard_index}), flush=True)

    # This new journey uses the real video-only Photos picker. Setup never
    # injects a project or bypasses the app's actual import commands.
    video_fixture_error = 'imageSetupFailed' if fixture_error else None
    if requirements["video"] and fixture_error is None:
        try:
            seed_video_fixture(args.udid, output)
        except (subprocess.SubprocessError, OSError, ValueError) as error:
            video_fixture_error = type(error).__name__
            print(json.dumps({"videoFixtureSeeded": False, "failureClass": video_fixture_error,
                              "mandatoryGateStillFailed": True, "allUITestsWillRun": args.shard_index is None,
                          "allAssignedUITestsWillRun": True, "shardIndex": args.shard_index}), flush=True)

    video = output / "simulator.mp4"
    if video.exists():
        raise ValueError("Do not overwrite a previous recording")
    recording_error = None
    recording_exit = None
    test_exit = 125
    test_process_exit = None
    def interrupted(_signal: int, _frame: object) -> None:
        raise KeyboardInterrupt("CI recording interrupted")
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    with (output / "recording.log").open("wb") as record_log, (output / "ui-tests.log").open("wb") as test_log:
        recorder = subprocess.Popen(
            ["xcrun", "simctl", "io", args.udid, "recordVideo", "--codec=h264", str(video)],
            stdout=record_log, stderr=subprocess.STDOUT)
        test_process = None
        try:
            time.sleep(1)
            if recorder.poll() is not None:
                recording_error = "Recorder exited before UI tests started"
            try:
                test_process = subprocess.Popen(command, stdout=test_log, stderr=subprocess.STDOUT)
                test_exit = test_process.wait(timeout=test_timeout_seconds)
            except subprocess.TimeoutExpired:
                test_exit = 124
        finally:
            # SIGINT gives xcodebuild a bounded chance to finalize xcresult.
            # subprocess.run(timeout=...) killed it immediately, leaving the
            # observed b3ca09f result bundle unreadable after the suite deadline.
            if test_process is not None:
                test_process_exit = stop_owned_process(test_process)
            # This handle refers only to the child started immediately above.
            # Popen retains/waits its child; no remembered or externally supplied PID.
            if recorder.poll() is None:
                recorder.send_signal(signal.SIGINT)
            try:
                recording_exit = recorder.wait(timeout=30)
            except subprocess.TimeoutExpired:
                recording_error = "Owned recorder did not finalize after SIGINT"
                recorder.terminate()
                try:
                    recording_exit = recorder.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    recorder.kill()
                    recording_exit = recorder.wait(timeout=10)

    verifier = output / "verify-recording"
    try:
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(pathlib.Path(__file__).with_name("VerifyRecording.swift")),
                        "-o", str(verifier)], check=True, timeout=60, capture_output=True)
        validation = subprocess.run([str(verifier), str(video)], check=True, timeout=30, capture_output=True, text=True)
        (output / "recording-validation.json").write_text(validation.stdout)
    except (subprocess.SubprocessError, OSError):
        recording_error = recording_error or "Recording is absent, unreadable or has no valid video frames/duration"
    report = {"simulatorUDID": args.udid, "simulatorName": selected[0]["name"],
              "uiTestExitCode": test_exit, "recordingExitCode": recording_exit,
              "recordingError": recording_error, "uiProcessExitCode": test_process_exit,
              "uiSuiteTimeoutSeconds": test_timeout_seconds,
              "photoFixtureSeeded": (fixture_error is None) if requirements["image"] else None,
              "photoFixtureStatus": ("passed" if fixture_error is None else "failed") if requirements["image"] else "not_required",
              "photoFixtureFailureClass": fixture_error,
              "videoFixtureSeeded": (video_fixture_error is None) if requirements["video"] else None,
              "videoFixtureStatus": ("passed" if video_fixture_error is None else "failed") if requirements["video"] else "not_required",
              "videoFixtureFailureClass": video_fixture_error,
              "fixtureRequirements": requirements}
    (output / "recording-status.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    if test_exit != 0:
        return test_exit if test_exit > 0 else 1
    if recording_error:
        return 3
    return 4 if fixture_error or video_fixture_error else 0


if __name__ == "__main__":
    sys.exit(main())

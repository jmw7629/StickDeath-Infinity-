"""Run the verbatim production UIKit popup helper in one fresh CI Simulator app.

All three original cases and numeric layout assertions remain mandatory.
This is a test-only app; it contains no SDI account, provider or project code.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = "com.willisbmb.sdi-popup-layout-gate"
CASES = (("short controls", 0, 360), ("long library", 30, 360),
         ("compact landscape", 0, 88))
PREFIX = "STUDIO_POPUP_LAYOUT_RESULT="


def validate_report(stdout, identity):
    lines = [line[len(PREFIX):] for line in stdout.decode("utf-8").splitlines()
             if line.startswith(PREFIX)]
    if len(lines) != 1 or len(lines[0]) > 16 * 1024:
        raise ValueError("Exactly one bounded measured UIKit result required")
    report = json.loads(lines[0])
    if (type(report.get("version")) is not int or report["version"] != 1
            or type(report.get("passed")) is not int or report["passed"] != 3
            or "failure" in report):
        raise ValueError("Every actual UIKit layout case must pass")
    if any(report.get(key) != value for key, value in identity.items()):
        raise ValueError("Actual app result has a different source/helper/nonce")
    actual = report.get("cases")
    if not isinstance(actual, list) or len(actual) != 3:
        raise ValueError("All three original cases are required")
    for result, (name, rows, bound) in zip(actual, CASES):
        if (type(result.get("rows")) is not int or type(result.get("width")) is not int
                or type(result.get("caseBudgetSeconds")) is not int
                or type(result.get("bound")) not in (int, float)):
            raise ValueError("Original numeric case parameters required")
        if (result.get("name"), result.get("rows"), result.get("width"),
                result.get("bound"), result.get("caseBudgetSeconds")) != (name, rows, 236, bound, 1):
            raise ValueError("Original case identity or geometry changed")
        if result.get("passed") is not True:
            raise ValueError("A hosted layout case failed")
        values = [result.get(key) for key in ("content", "viewport", "fitting", "measurementSeconds")]
        if any(type(value) not in (int, float) or not math.isfinite(value) for value in values):
            raise ValueError("Real finite measured dimensions required")
        content, viewport, fitting, seconds = values
        expected = min(content, bound)
        if not (content > 0 and viewport > 0 and seconds >= 1
                and abs(viewport - expected) < 0.5 and abs(fitting - expected) < 0.5):
            raise ValueError("Actual measured geometry violates the original oracle")
    return report



def emit_failure(stage, error, projection=None, stdout=b"", stderr=b""):
    """Retain exact bounded child output in Actions logs, including failure facts."""
    facts = {"failureStage": stage, "errorClass": type(error).__name__,
             "error": str(error)[:1000], "lastCommand": projection,
             "retainedStdoutBytes": len(stdout), "retainedStderrBytes": len(stderr)}
    print("STUDIO_POPUP_LAYOUT_FAILURE=" + json.dumps(facts, sort_keys=True),
          file=sys.stderr, flush=True)
    for name, data in (("stdout", stdout), ("stderr", stderr)):
        if data:
            # All callers pass buffers already capped by the existing bounded runner.
            sys.stderr.buffer.write(("BEGIN bounded " + name + "\n").encode())
            sys.stderr.buffer.write(data)
            sys.stderr.buffer.write(("\nEND bounded " + name + "\n").encode())
            sys.stderr.buffer.flush()



def configure_toolchain(command, requested_swiftc="swiftc", applications=Path("/Applications")):
    """Use the native app gate's installed Xcode26 selection, never PATH swiftc."""
    # The surrounding probe restores inherited values; no workflow/host change.
    os.environ.pop("SDKROOT", None)
    xcode = command("xcode-version", ["xcodebuild", "-version"], 10, 4096).decode()
    supported = r"Xcode (?:2[6-9]|[3-9][0-9])(?:\.|\s)"
    if not re.search(supported, xcode):
        choices = []
        for app in applications.glob("Xcode_26*.app"):
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            version = tuple(int(x) for x in re.findall(r"\d+", info["CFBundleShortVersionString"]))
            choices.append((version, app))
        if not choices:
            raise ValueError("Xcode26 is required for the UIKit layout probe")
        os.environ["DEVELOPER_DIR"] = str(max(choices, key=lambda x: x[0])[1] / "Contents/Developer")
        xcode = command("selected-xcode-version", ["xcodebuild", "-version"], 10, 4096).decode()
    if not re.search(supported, xcode):
        raise ValueError("Selected toolchain is not Xcode26 or newer")
    developer = os.environ.get("DEVELOPER_DIR") or command(
        "selected-developer-directory", ["xcode-select", "-p"], 10, 4096).decode().strip()
    if not Path(developer).is_absolute():
        raise ValueError("Selected developer directory must be absolute")
    developer = Path(developer).resolve(strict=True)
    os.environ["DEVELOPER_DIR"] = str(developer)
    selected_swiftc = Path(command("selected-swiftc", ["xcrun", "--find", "swiftc"],
                                  30, 4096).decode().strip())
    if not selected_swiftc.is_absolute():
        raise ValueError("Selected swiftc must be absolute")
    swiftc = selected_swiftc.resolve(strict=True)
    if not swiftc.is_file() or not swiftc.is_relative_to(developer):
        raise ValueError("swiftc must belong to the selected Xcode toolchain")
    if requested_swiftc != "swiftc" and Path(requested_swiftc).resolve(strict=True) != swiftc:
        raise ValueError("Explicit swiftc differs from the selected Xcode toolchain")
    # swiftc may be a swift-driver symlink. Preserve its selected basename for
    # driver-mode dispatch while validating the resolved target above.
    return {"version": xcode.strip(), "developerDirectory": str(developer), "swiftc": str(selected_swiftc)}


def prepare_fresh_simulator(command, selector, deadline):
    """One cold read-only readiness check; failure never reaches creation."""
    # The first cold inventory timed out at59s. One180s read still shares the
    # unchanged900s overall deadline; no second attempt or runtime fallback.
    raw = command("coresimulator-readiness", ["xcrun", "simctl", "list", "--json"],
                  180, cap=selector.INVENTORY_CAP)
    selector.inventory(raw)
    # The unchanged creator has its own100s bound. Admit it only if its complete
    # budget fits inside this probe's900s limit with the original cleanup reserve.
    if time.monotonic() + selector.TOTAL_SECONDS > deadline - 60:
        raise ValueError("Insufficient overall budget for fresh Simulator setup")
    return selector.create_fresh("iphone")


def creator_failure_diagnostic(root, selector, run, source):
    """Read facts only; a failed marker never grants device/cleanup authority."""
    marker = root / selector.MARKER
    fd = os.open(marker, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or before.st_uid != os.getuid() or before.st_size > selector.MARKER_CAP):
            raise ValueError("Unsafe creator diagnostic marker")
        data = os.read(fd, selector.MARKER_CAP + 1)
        after = os.fstat(fd)
        current = marker.lstat()
    finally:
        os.close(fd)
    def identity(info):
        return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    if len(data) > selector.MARKER_CAP or identity(before) != identity(after) or identity(before) != identity(current):
        raise ValueError("Creator diagnostic marker changed while reading")
    value = json.loads(data)
    if value.get("version") != 1 or value.get("run") != run or value.get("sourceCommit") not in (None, source):
        raise ValueError("Creator diagnostic belongs to another source/run")
    return {"diagnosticOnlyNoDeviceAuthority": True, "markerSHA256": hashlib.sha256(data).hexdigest(),
            "markerBytes": len(data), "creator": value}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--sdk")
    parser.add_argument("--output-directory", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    # Reuse the existing CI-only creator and its descriptor-bound ownership marker.
    sys.path.insert(0, str(ROOT / "scripts/native-smoke"))
    import select_simulator
    from seed_diagnostics import run_bounded, result_projection
    temporary, run_identity = select_simulator.context()
    if platform.system() != "Darwin" or platform.machine() not in ("arm64", "x86_64"):
        raise ValueError("Installed Apple Simulator toolchain required")
    if any(key.startswith("SIMCTL_CHILD_") for key in os.environ):
        raise ValueError("Do not inherit injected Simulator application settings")
    output = Path(args.output_directory)
    if not output.is_absolute() or output == temporary or not output.parent.resolve().is_relative_to(temporary):
        raise ValueError("Use a new private directory inside this CI runner's temporary root")
    if output.parent.resolve() != output.parent or output.exists() or output.is_symlink():
        raise ValueError("Existing or redirected output is not replayable")
    output.mkdir(mode=0o700)
    os.environ["TMPDIR"] = str(output) + "/"
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    os.chdir(ROOT)
    started = time.monotonic()
    deadline = started + 900
    result = {"state": "FAIL", "SDKPlatform": "iphonesimulator", "caseBudgetSeconds": 1,
              "compileBudgetSeconds": 240, "appRunBudgetSeconds": 30, "overallBudgetSeconds": 900,
              "automaticRetries": 0, "steps": [], "cleanup": "not-created"}
    owned = None
    marker_bytes = None
    marker_metadata = None
    boot_attempted = False
    failure = None
    last_command = None
    last_stdout = last_stderr = b""
    emitted_command = None
    setup_started = False
    inherited_toolchain = {key: os.environ.get(key) for key in ("SDKROOT", "DEVELOPER_DIR")}

    def save():
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")

    def command(name, argv, seconds, cap=256 * 1024, cleanup=False):
        nonlocal last_command, last_stdout, last_stderr, emitted_command
        limit = deadline if cleanup else deadline - 60
        last_command = {"stage": name, "argv": argv, "resultAvailable": False}
        last_stdout = last_stderr = b""
        bounded = run_bounded(argv, min(limit, time.monotonic() + seconds),
                              stdout_cap=cap, stderr_cap=cap)
        projection = {"stage": name, "argv": argv, **result_projection(bounded)}
        last_command = projection
        last_stdout, last_stderr = bounded.stdout, bounded.stderr
        failed = (bounded.returncode != 0 or bounded.timed_out or bounded.spawn_error
                  or not bounded.reaped or bounded.capture_incomplete
                  or bounded.stdout_seen > cap or bounded.stderr_seen > cap)
        if failed:
            emit_failure(name, RuntimeError("Bounded command failed; no retry"),
                         projection, last_stdout, last_stderr)
            emitted_command = name
        (output / (name + ".stdout")).write_bytes(bounded.stdout)
        (output / (name + ".stderr")).write_bytes(bounded.stderr)
        result["steps"].append(projection)
        save()
        if failed:
            raise RuntimeError("Bounded " + name + " failed; no retry")
        return bounded.stdout

    def owned_marker():
        # Revalidate the exact marker originally checked by copy_marker before
        # any device action, including cleanup. Never operate on a changed lease.
        marker = temporary / select_simulator.MARKER
        fd = os.open(marker, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            before = os.fstat(fd)
            data = os.read(fd, select_simulator.MARKER_CAP + 1)
            after = os.fstat(fd)
            current = marker.lstat()
        finally:
            os.close(fd)
        metadata = (before.st_dev, before.st_ino, before.st_size,
                    before.st_mtime_ns, before.st_ctime_ns)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or metadata != marker_metadata or data != marker_bytes
                or metadata != (after.st_dev, after.st_ino, after.st_size,
                                after.st_mtime_ns, after.st_ctime_ns)
                or (current.st_dev, current.st_ino) != metadata[:2]):
            raise ValueError("Owned Simulator marker changed; preserve foreign devices")
        value = json.loads(data)
        if (value.get("state") != "verified" or value.get("run") != run_identity
                or value.get("sourceCommit") != result["sourceCommit"]
                or value.get("created", {}).get("udid") != owned):
            raise ValueError("Simulator no longer belongs to this exact source/run")
        return value

    def owned_device(stage, cleanup=False):
        marker = owned_marker()
        # Work inventory shares the original900s pool and60s cleanup reserve;
        # cleanup keeps its original30s command cap. No second inventory attempt.
        raw = command(stage, ["xcrun", "simctl", "list", "--json"], 30 if cleanup else 180,
                      cap=2 * 1024 * 1024, cleanup=cleanup)
        _, devices, _ = select_simulator.inventory(raw)
        matches = [(runtime, device) for runtime, device in devices
                   if device["udid"].upper() == owned]
        created = marker["created"]
        if len(matches) != 1:
            raise ValueError("Owned Simulator identity is absent or ambiguous")
        runtime, device = matches[0]
        if (runtime != created["runtime"] or device.get("name") != created["name"]
                or device.get("deviceTypeIdentifier") != created["deviceType"]
                or device.get("isAvailable") is not True):
            raise ValueError("Owned Simulator identity differs from the verified creator")
        return device["state"]

    try:
        result["toolchain"] = configure_toolchain(command, args.swiftc)
        commit = command("source", ["git", "rev-parse", "--verify", "HEAD"], 5, 128).decode().strip()
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ValueError("Exact source commit required")
        command("source-clean", ["git", "diff", "--exit-code", "HEAD", "--"], 10)
        panel = ROOT / "StickDeathInfinity/Views/Studio/Panels/ToolSettingsPanel.swift"
        harness = Path(__file__).with_name("Harness.swift")
        panel_bytes, harness_bytes = panel.read_bytes(), harness.read_bytes()
        source = panel_bytes.decode()
        start_marker = "private struct ToolSettingsContentHeight:"
        end_marker = "\nprivate enum StudioImagePlacementField:"
        if source.count(start_marker) != 1 or source.count(end_marker) != 1:
            raise ValueError("Production popup helper boundary is ambiguous")
        helper = source[source.index(start_marker):source.index(end_marker, source.index(start_marker))]
        identity = {"nonce": uuid.uuid4().hex, "sourceCommit": commit,
                    "productionFileSHA256": hashlib.sha256(panel_bytes).hexdigest(),
                    "productionHelperSHA256": hashlib.sha256(helper.encode()).hexdigest(),
                    "harnessSHA256": hashlib.sha256(harness_bytes).hexdigest()}
        result.update(identity)
        selected_sdk = command("simulator-sdk", ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], 30, 4096).decode().strip()
        sdk = Path(selected_sdk).resolve(strict=True)
        if args.sdk and Path(args.sdk).resolve(strict=True) != sdk:
            raise ValueError("An explicit SDK must be the selected iOS Simulator SDK")
        app = output / "PopupLayoutGate.app"
        app.mkdir(mode=0o700)
        unit = output / "ActualPopupLayout.swift"
        unit.write_bytes(harness_bytes + b"\n" + helper.encode())
        info = {"CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": "PopupLayoutGate",
                "CFBundleName": "PopupLayoutGate", "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1", "CFBundleShortVersionString": "1",
                "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "MinimumOSVersion": "17.0",
                "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1],
                "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False,
                    "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [
                        {"UISceneConfigurationName": "PopupLayout"}]}},
                **{"SDIPopup_" + key: value for key, value in identity.items()}}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        command("compile", [result["toolchain"]["swiftc"], "-swift-version", "5", "-parse-as-library",
                "-module-name", "SDIPopupLayoutGate", "-module-cache-path", str(output / "module-cache"),
                "-sdk", str(sdk), "-target", platform.machine() + "-apple-ios17.0-simulator",
                "-framework", "UIKit", "-framework", "SwiftUI", "-Xlinker", "-rpath",
                "-Xlinker", "/usr/lib/swift", str(unit), "-o", str(app / "PopupLayoutGate")],
                240, cap=4 * 1024 * 1024)
        # This existing API rejects local Macs, existing reservations, duplicate
        # creation, unavailable SDK runtimes and devices owned by another run.
        setup_started = True
        owned = prepare_fresh_simulator(command, select_simulator, deadline)
        evidence = output / "sdi-native-smoke.popup-layout"
        evidence.mkdir(mode=0o700)
        select_simulator.copy_marker(evidence, owned, commit)
        marker = temporary / select_simulator.MARKER
        fd = os.open(marker, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            st = os.fstat(fd)
            marker_bytes = os.read(fd, select_simulator.MARKER_CAP + 1)
        finally:
            os.close(fd)
        marker_metadata = (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        if marker_bytes != (evidence / "fresh-simulator.json").read_bytes():
            raise ValueError("Owned marker changed after verification")
        result["simulatorUDID"] = owned
        if owned_device("owned-before-boot") != "Shutdown":
            raise ValueError("The newly owned Simulator is already in use")
        boot_attempted = True
        command("boot", ["xcrun", "simctl", "boot", owned], 30)
        owned_marker()
        command("bootstatus", ["xcrun", "simctl", "bootstatus", owned, "-b"], 180)
        if owned_device("owned-before-install") != "Booted":
            raise ValueError("Owned Simulator did not reach Booted")
        command("install", ["xcrun", "simctl", "install", owned, str(app)], 60)
        owned_marker()
        stdout = command("run", ["xcrun", "simctl", "launch", "--console", owned, BUNDLE_ID], 30)
        report = validate_report(stdout, identity)
        if panel.read_bytes() != panel_bytes or harness.read_bytes() != harness_bytes:
            raise ValueError("Production helper/harness changed during verification")
        result["measuredResult"] = report
        result["sourcePostmatched"] = True
        result["state"] = "MEASURED_PASS_PENDING_OWNED_CLEANUP"
    except BaseException as error:
        failure = error
        result["state"] = "FAIL"
        result["errorClass"] = type(error).__name__
        result["error"] = str(error)[:1000]
        if setup_started and owned is None:
            try:
                diagnostic = creator_failure_diagnostic(temporary, select_simulator, run_identity,
                                                        result.get("sourceCommit"))
            except BaseException as marker_error:
                diagnostic = {"state": "unavailable", "errorClass": type(marker_error).__name__,
                              "error": str(marker_error)[:1000], "diagnosticOnlyNoDeviceAuthority": True}
            result["creatorFailureDiagnostic"] = diagnostic
            print("STUDIO_POPUP_CREATOR_DIAGNOSTIC=" + json.dumps(diagnostic, sort_keys=True),
                  file=sys.stderr, flush=True)
        already_emitted = last_command and emitted_command == last_command["stage"]
        emit_failure("verification", error, last_command,
                     b"" if already_emitted else last_stdout,
                     b"" if already_emitted else last_stderr)
        if last_command:
            emitted_command = last_command["stage"]
    finally:
        # Only the verified fresh CI device may be stopped. Do not erase/delete
        # it, enumerate local user devices for cleanup, or touch production apps.
        if owned and marker_bytes is not None and boot_attempted:
            try:
                state = owned_device("owned-before-cleanup", cleanup=True)
                if state == "Booted":
                    owned_marker()
                    command("shutdown", ["xcrun", "simctl", "shutdown", owned], 30, cleanup=True)
                    result["cleanup"] = "verified-owned-device-shutdown"
                elif state == "Shutdown":
                    result["cleanup"] = "verified-owned-device-already-shutdown"
                else:
                    raise ValueError("Ambiguous owned state; no cleanup mutation")
            except BaseException as error:
                result["cleanup"] = {"state": "FAIL", "errorClass": type(error).__name__,
                                     "error": str(error)[:1000]}
                result["state"] = "FAIL"
                already_emitted = last_command and emitted_command == last_command["stage"]
                emit_failure("owned-cleanup", error, last_command,
                             b"" if already_emitted else last_stdout,
                             b"" if already_emitted else last_stderr)
                if failure is None:
                    failure = error
        if failure is None and result.get("sourcePostmatched") and result.get("measuredResult"):
            result["state"] = "PASS"
        result["elapsedSeconds"] = time.monotonic() - started
        try:
            save()
        except BaseException as error:
            # A failed evidence write must not replace the original command facts.
            emit_failure("result-persistence", error, last_command)
            if failure is None:
                failure = error
        finally:
            for key, value in inherited_toolchain.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
    if failure is not None:
        raise SystemExit("UIKit popup layout failed: " + type(failure).__name__
                         + ": " + str(failure)[:1000])
    print(json.dumps(result["measuredResult"], sort_keys=True), flush=True)
    print("STUDIO_POPUP_LAYOUT=PASS 3/3 actual hosted UIKit cases", flush=True)


if __name__ == "__main__":
    main()

"""Prepare one source-pinned, Simulator-only Files location; never seed media.

The recorder calls provision_files_fixture only after its existing offline-app,
destination and boot gates. The CLI prepares an app only, for manual review.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import time
import uuid


BUNDLE_ID = "com.willisbmb.sdi-export-fixture"
EXECUTABLE = "SDIExportFilesFixture"
READY_MARKER = b"SDI export fixture ready\n"
SOURCE_PINS = {
    "main.m": "dd83a35a8a660a050fca93145af674b79bbdacae1a5b338031e0c38ffb07b22c",
    "Info.plist": "2c76ffc87da955095081097272df5c9c34f9171df1a58d98c2bee3c1484a5607",
}


def isolated_output(output: Path) -> Path:
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    if output.is_symlink() or not output.is_dir():
        raise ValueError("Files fixture requires an existing private runner-temp evidence directory")
    resolved = output.resolve(strict=True)
    if resolved == runner_temp or not resolved.is_relative_to(runner_temp):
        raise ValueError("Files fixture output must be below RUNNER_TEMP")
    return resolved


def tool_output(arguments: list[str]) -> str:
    # Only fixed Xcode SDK discovery commands use this small textual channel.
    result = subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=15)
    if len(result.stdout) > 4096 or len(result.stderr) > 4096:
        raise ValueError("Unexpected Xcode discovery output size")
    return result.stdout.strip()


def prepare_files_fixture(output: Path) -> tuple[Path, dict]:
    output = isolated_output(output)
    source = Path(__file__).resolve().parents[2] / "Tests/NativeSupport/ExportFilesFixture"
    inputs = {}
    for name, expected in SOURCE_PINS.items():
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("Use only the checked-in Files fixture sources")
        data = path.read_bytes()
        if len(data) > 16384 or hashlib.sha256(data).hexdigest() != expected:
            raise ValueError("Files fixture source pin mismatch: " + name)
        inputs[name] = data
    info = plistlib.loads(inputs["Info.plist"])
    if (info["CFBundleIdentifier"] != BUNDLE_ID or info["CFBundleExecutable"] != EXECUTABLE
            or info["CFBundleSupportedPlatforms"] != ["iPhoneSimulator"]):
        raise ValueError("Files fixture must remain the separate Simulator-only app")
    architecture = platform.machine()
    if architecture not in ("arm64", "x86_64"):
        raise ValueError("Unsupported Simulator host architecture")
    compiler = Path(tool_output(["xcrun", "--sdk", "iphonesimulator", "--find", "clang"]))
    sdk = Path(tool_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]))
    sdk_version = tool_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
    if (not compiler.is_absolute() or not compiler.is_file() or not sdk.is_absolute()
            or not sdk.is_dir() or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", sdk_version)
            or int(sdk_version.split(".")[0]) < 18):
        raise ValueError("Expected the installed current iOS Simulator SDK and clang")
    folder = output / "files-provider-fixture"
    folder.mkdir(mode=0o700, exist_ok=False)
    app = folder / "SDIExportFilesFixture.app"
    app.mkdir(mode=0o700)
    (app / "Info.plist").write_bytes(inputs["Info.plist"])
    pinned_source = folder / "main.m"
    pinned_source.write_bytes(inputs["main.m"])
    temporary = folder / "tmp"
    temporary.mkdir(mode=0o700)
    environment = dict(os.environ, TMPDIR=str(temporary))
    command = [str(compiler), "-fobjc-arc", "-fno-modules", "-target",
               architecture + "-apple-ios18.0-simulator", "-isysroot", str(sdk),
               "-framework", "UIKit", "-framework", "Foundation", str(pinned_source),
               "-o", str(app / EXECUTABLE)]
    report = {"status": "preparing", "sourceSHA256": SOURCE_PINS,
              "bundleIdentifier": BUNDLE_ID, "architecture": architecture,
              "sdkVersion": sdk_version, "compileTimeoutSeconds": 60,
              "attempts": 1, "route": "Separate app's own Documents/Exports; no exported media seeded"}
    try:
        # Fixed tiny local inputs, no project build/package resolution/signing.
        # Preserve the raw compiler exit and log; never retry the compilation.
        with (folder / "compile.log").open("xb") as log:
            result = subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=60)
        report["compileExitCode"] = result.returncode
        result.check_returncode()
        binary = (app / EXECUTABLE).read_bytes()
        if not 0 < len(binary) <= 5 * 1024 * 1024:
            raise ValueError("Unexpected Files fixture executable size")
        report.update(status="prepared", binaryBytes=len(binary), binarySHA256=hashlib.sha256(binary).hexdigest())
        return app, report
    except Exception as error:
        report.update(status="failed", failureClass=type(error).__name__)
        raise
    finally:
        with (folder / "prepare-result.json").open("x") as stream:
            json.dump(report, stream, indent=2)
            stream.write("\n")


def provision_files_fixture(udid: str, output: Path) -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true" or str(uuid.UUID(udid)).lower() != udid.lower():
        raise ValueError("Use only the caller-validated explicit CI Simulator")
    output = isolated_output(output)
    app, prepared = prepare_files_fixture(output)
    folder = app.parent
    report = {**prepared, "simulatorUDID": udid, "status": "provisioning",
              "installAttempts": 1, "launchAttempts": 1}
    try:
        # Only the exact destination already owned/booted by the recorder.
        # No terminate, uninstall, reset, provider injection, or other-device operation.
        for stage, arguments in [
            ("install", ["xcrun", "simctl", "install", udid, str(app)]),
            ("launch", ["xcrun", "simctl", "launch", udid, BUNDLE_ID]),
        ]:
            with (folder / (stage + ".log")).open("xb") as log:
                result = subprocess.run(arguments, stdout=log, stderr=subprocess.STDOUT, timeout=30)
            report[stage + "ExitCode"] = result.returncode
            result.check_returncode()
        container = Path(tool_output(["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"]))
        if not container.is_absolute() or not container.is_dir():
            raise ValueError("Expected the installed fixture's own data container")
        marker = container / "Documents/.sdi-export-fixture-ready"
        deadline = time.monotonic() + 10
        while True:
            if marker.is_file() and not marker.is_symlink() and marker.stat().st_size == len(READY_MARKER):
                if marker.read_bytes() == READY_MARKER:
                    break
            if time.monotonic() >= deadline:
                raise TimeoutError("The fixture did not report its own Documents/Exports ready")
            time.sleep(0.1)
        report.update(status="ready", markerSHA256=hashlib.sha256(READY_MARKER).hexdigest(),
                      mediaSeeded=False, sourceProjectDataAccessed=False)
    except Exception as error:
        report.update(status="failed", failureClass=type(error).__name__)
        raise
    finally:
        with (folder / "provision-result.json").open("x") as stream:
            json.dump(report, stream, indent=2)
            stream.write("\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Prepare only; does not contact or mutate a Simulator")
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    app, report = prepare_files_fixture(arguments.output)
    print(json.dumps({"app": str(app), **report}))

#!/usr/bin/env python3
"""Package the completed CI Simulator compile for optional review."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time

from seed_diagnostics import result_projection, run_bounded

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "com.willisbmb.StickDeathInfinity"
APP_NAME = "StickDeathInfinity"
MAXIMUM_ARCHIVE_BYTES = 512 * 1024 * 1024
# Match the capture inventory, but require absent or blank values for export.
OFFLINE_SETTINGS = (
    "SPATTER_BACKEND_URL", "SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY", "LIVEKIT_WS_URL",
    "SDI_UPLOAD_SERVICE_URL", "SDI_RENDER_PREVIEW_URL", "SDI_PUBLISHING_CONSENT_VERSION", "SDI_PUBLISHING_TERMS_URL",
    "SDI_OAUTH_PROVIDERS", "SDI_MICROSOFT_TENANT", "SDI_STOREKIT_PLAN_4_99_PRODUCT_ID",
    "SDI_STOREKIT_PLAN_9_99_PRODUCT_ID", "SDI_STOREKIT_PLAN_19_99_PRODUCT_ID",
    "SDI_STOREKIT_PLAN_4_99_ANNUAL_PRODUCT_ID", "SDI_STOREKIT_PLAN_9_99_ANNUAL_PRODUCT_ID",
    "SDI_STOREKIT_CREDITS_SMALL_PRODUCT_ID", "SDI_STOREKIT_CREDITS_LARGE_PRODUCT_ID",
    "SDI_BILLING_ANNUAL_OWNER_CONFIGURED",
)


def read_regular(path, limit):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Expected a regular CI input")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("CI input exceeds its byte bound")
    return data


def sha_file(path, limit=None):
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            size += len(block)
            if limit is not None and size > limit:
                raise ValueError("Archive grew beyond its verified byte bound")
            digest.update(block)
    if limit is not None and size != limit:
        raise ValueError("Archive changed size during verification")
    return digest.hexdigest()


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], timeout=10)


def require_source(commit, tree, hashes):
    if (git("rev-parse", "HEAD").decode().strip() != commit or
            git("rev-parse", "HEAD^{tree}").decode().strip() != tree or
            git("status", "--porcelain=v1")):
        raise ValueError("Review checkout does not match the completed build")
    names = git("ls-files", "-z").decode().split("\0")
    expected = {name for name in names if name.startswith(
        ("StickDeathInfinity/", "StickDeathInfinity.xcodeproj/", "Tests/NativeAuth/"))}
    if set(hashes) != expected or any(sha_file(ROOT / name) != hashes[name] for name in expected):
        raise ValueError("Native inputs differ from the build inventory")


def require_unconfigured(info, environment):
    for key in OFFLINE_SETTINGS:
        for source, name in ((info, key), (environment, key), (environment, "SIMCTL_CHILD_" + key)):
            if name in source:
                value = source[name]
                if not isinstance(value, str) or value.strip():
                    raise ValueError("Review packaging requires absent or blank configuration")


def prepare(report):
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise ValueError("Compile review packaging requires the hosted CI runner")
    cutoff = os.environ["SDI_REVIEW_PACKAGE_START_CUTOFF_NS"]
    if not re.fullmatch(r"[0-9]{1,24}", cutoff):
        raise ValueError("Invalid optional review window")
    if time.monotonic_ns() >= int(cutoff):
        report.update(status="skipped", stage="optional-window")
        return
    commit = os.environ["SDI_EXPECTED_HEAD"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("An exact source commit is required")
    runner = Path(os.environ["RUNNER_TEMP"])
    runner_root = runner.resolve(strict=True)
    evidence = runner / "sdi-native-compile-evidence"
    build = runner / "sdi-native-compile"
    output = runner / "sdi-native-compile-review-app"
    app = build / f"DerivedData/Build/Products/Debug-iphonesimulator/{APP_NAME}.app"
    for path in (evidence, app):
        if not path.is_dir() or path.resolve(strict=True) != runner_root / path.relative_to(runner):
            raise ValueError("Compile product or evidence escaped runner scratch")
    receipt_data = read_regular(evidence / "receipt.json", 64 * 1024)
    inputs_data = read_regular(evidence / "input-sha256.json", 4 * 1024 * 1024)
    argv_data = read_regular(evidence / "argv.json", 16 * 1024)
    receipt, inputs, argv = map(json.loads, (receipt_data, inputs_data, argv_data))
    tree = receipt["sourceTree"]
    if (receipt["sourceCommit"] != commit or not re.fullmatch(r"[0-9a-f]{40}", tree) or
            receipt["status"] != "passed" or receipt["buildExitCode"] != 0 or receipt.get("timeout") or
            receipt["nativeInputsPostflightMatched"] is not True or not inputs or
            len(inputs) != receipt["nativeInputCount"] or
            argv != ["xcodebuild", "-project", "StickDeathInfinity.xcodeproj", "-scheme", APP_NAME,
                     "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
                     "-derivedDataPath", str(build / "DerivedData"), "-clonedSourcePackagesDirPath", str(build / "Packages"),
                     "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
                     "-jobs", "2", "CODE_SIGNING_ALLOWED=NO"] +
                    [key + "=" for key in OFFLINE_SETTINGS] + ["build"]):
        raise ValueError("A completed unsigned Simulator build is required")
    require_source(commit, tree, inputs)
    info_data = read_regular(app / "Info.plist", 1024 * 1024)
    info = plistlib.loads(info_data)
    if (info.get("CFBundleIdentifier"), info.get("CFBundleExecutable"), info.get("CFBundlePackageType")) != (
            BUNDLE, APP_NAME, "APPL"):
        raise ValueError("Unexpected compile product identity")
    require_unconfigured(info, os.environ)
    report.update(sourceCommit=commit, sourceTree=tree, stage="bounded-packager")
    command = [sys.executable, str(ROOT / "scripts/native-review/package_simulator_app.py"),
               "--app", str(app), "--output", str(output), "--commit", commit, "--ci-compile-product"]
    started = time.monotonic()
    result = run_bounded(command, started + 124, stdout_cap=4096, stderr_cap=4096,
                         work_deadline=started + 123)
    report["command"] = result_projection(result)
    if result.returncode != 0 or result.timed_out or not result.reaped:
        raise RuntimeError("The native review packager did not finish successfully")

    report["stage"] = "package-provenance"
    if output.resolve(strict=True) != runner_root / output.relative_to(runner):
        raise ValueError("Review output escaped runner scratch")
    manifest_data = read_regular(output / "manifest.json", 4 * 1024 * 1024)
    manifest = json.loads(manifest_data)
    archive = output / "StickDeathInfinity-simulator.zip"
    binaries = receipt["appBinariesSHA256"]
    size = manifest["archiveBytes"]
    architectures = manifest["architectures"]
    if (manifest["sourceCommit"] != commit or manifest["appBundleIdentifier"] != BUNDLE or
            manifest["fileHashes"].get("Info.plist") != hashlib.sha256(info_data).hexdigest() or
            APP_NAME not in binaries or any(manifest["fileHashes"].get(name) != digest for name, digest in binaries.items()) or
            not isinstance(architectures, list) or not architectures or not set(architectures) <= {"arm64", "x86_64"} or
            archive.is_symlink() or not archive.is_file() or not 0 < size <= MAXIMUM_ARCHIVE_BYTES or
            archive.stat().st_size != size or sha_file(archive, size) != manifest["archiveSHA256"]):
        raise ValueError("Review package differs from the compiled app")
    require_source(commit, tree, inputs)
    if (read_regular(evidence / "receipt.json", 64 * 1024) != receipt_data or
            read_regular(evidence / "input-sha256.json", 4 * 1024 * 1024) != inputs_data or
            read_regular(evidence / "argv.json", 16 * 1024) != argv_data):
        raise ValueError("Compile evidence changed during review packaging")
    binding = {"sourceCommit": commit, "sourceTree": tree,
               "compileReceiptSHA256": hashlib.sha256(receipt_data).hexdigest(),
               "compileArgvSHA256": hashlib.sha256(argv_data).hexdigest(),
               "compileInputManifestSHA256": hashlib.sha256(inputs_data).hexdigest(),
               "packageManifestSHA256": hashlib.sha256(manifest_data).hexdigest(),
               "archiveSHA256": manifest["archiveSHA256"], "nativeInputsPostflightMatched": True,
               "offlineConfiguration": {"status": "unconfigured", "checkedSettings": list(OFFLINE_SETTINGS),
                                        "environmentChecked": True, "networkTrafficMeasured": False}}
    with (output / "compile-provenance.json").open("x") as stream:
        stream.write(json.dumps(binding, indent=2) + "\n")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as stream:
        stream.write("review_app_ready=true\n")
    report.update(status="prepared", archiveBytes=size, architectures=architectures,
                  archiveSHA256=manifest["archiveSHA256"])


if __name__ == "__main__":
    report = {"status": "unavailable", "stage": "compile-product-preflight"}
    try:
        prepare(report)
    except Exception as error:
        report["reasonType"] = type(error).__name__
    print(json.dumps({"nativeReviewPackage": report}), flush=True)
    raise SystemExit(1 if report["status"] == "unavailable" else 0)

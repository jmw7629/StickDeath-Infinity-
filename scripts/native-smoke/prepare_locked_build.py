#!/usr/bin/env python3
"""Prepare the checked-in Simulator app for the required native CI jobs."""

import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


# Match the existing compile/capture offline settings for every locked build.
LIBRARY_OFFLINE_SETTINGS = (
    "SPATTER_BACKEND_URL", "SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY", "LIVEKIT_WS_URL",
    "SDI_UPLOAD_SERVICE_URL", "SDI_RENDER_PREVIEW_URL", "SDI_PUBLISHING_CONSENT_VERSION", "SDI_PUBLISHING_TERMS_URL",
    "SDI_OAUTH_PROVIDERS", "SDI_MICROSOFT_TENANT", "SDI_STOREKIT_PLAN_4_99_PRODUCT_ID",
    "SDI_STOREKIT_PLAN_9_99_PRODUCT_ID", "SDI_STOREKIT_PLAN_19_99_PRODUCT_ID",
    "SDI_STOREKIT_PLAN_4_99_ANNUAL_PRODUCT_ID", "SDI_STOREKIT_PLAN_9_99_ANNUAL_PRODUCT_ID",
    "SDI_STOREKIT_CREDITS_SMALL_PRODUCT_ID", "SDI_STOREKIT_CREDITS_LARGE_PRODUCT_ID",
    "SDI_BILLING_ANNUAL_OWNER_CONFIGURED",
)


def xcode_version(environment):
    return subprocess.check_output(["xcodebuild", "-version"], env=environment, text=True, timeout=30).strip()


def supports_locked_build(version):
    match = re.search(r"^Xcode (\d+)(?:\.|\s|$)", version, re.MULTILINE)
    return match is not None and int(match[1]) >= 26


def developer_directory(environment):
    # Match build_app_ci.py: keep Xcode 26+ when selected, otherwise use the
    # highest installed Xcode 26 app. Never switch the host's global selection.
    if supports_locked_build(xcode_version(environment)):
        path = environment.get("DEVELOPER_DIR") or subprocess.check_output(
            ["xcode-select", "--print-path"], env=environment, text=True, timeout=30).strip()
        developer = Path(path)
        if developer.suffix == ".app":
            developer = developer / "Contents/Developer"
    else:
        choices = []
        for app in Path("/Applications").glob("Xcode_26*.app"):
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            version = tuple(int(x) for x in re.findall(r"\d+", info["CFBundleShortVersionString"]))
            choices.append((version, app))
        if not choices:
            raise RuntimeError("Xcode 26 is required for native CI")
        developer = max(choices)[1] / "Contents/Developer"
    if not developer.is_absolute() or not developer.is_dir() or any(c in str(developer) for c in "\r\n"):
        raise RuntimeError("Expected an installed absolute Xcode developer directory")
    return developer


def clean_checkout(phase):
    result = subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], timeout=30)
    if result.returncode == 1:
        print(f"Tracked checkout changes {phase}. Preserve the changed paths and fail.", file=sys.stderr, flush=True)
        subprocess.run(["git", "--no-pager", "diff", "--name-status", "--no-renames", "HEAD", "--"],
                       check=True, timeout=30)
        return False
    result.check_returncode()
    return True


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Approved CI runner required")
    if not clean_checkout("before the locked native build"):
        return 2

    environment = dict(os.environ)
    environment["DEVELOPER_DIR"] = str(developer_directory(environment))
    version = xcode_version(environment)
    if not supports_locked_build(version):
        raise RuntimeError("Selected native CI Xcode is older than 26")
    print(version, flush=True)

    derived = Path(os.environ["RUNNER_TEMP"]) / "sdi-native-build"
    packages = derived / "SourcePackages"
    result = subprocess.run([
        "xcodebuild", "-project", "StickDeathInfinity.xcodeproj", "-scheme", "StickDeathInfinity",
        "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", str(derived), "-clonedSourcePackagesDirPath", str(packages),
        "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
        "-jobs", "2", "CODE_SIGNING_ALLOWED=NO",
        *[key + "=" for key in LIBRARY_OFFLINE_SETTINGS], "build",
    ], env=environment)
    if not clean_checkout("after the locked native build"):
        return result.returncode or 2
    if result.returncode:
        return result.returncode

    # Subsequent xcrun, Simulator selection and XCTest steps use this toolchain.
    with Path(os.environ["GITHUB_ENV"]).open("a") as output:
        output.write(f"DEVELOPER_DIR={environment['DEVELOPER_DIR']}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Run the real auth service tests on the already-owned CI simulator."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


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
               "-destination", f"platform=iOS Simulator,id={udid}",
               "-derivedDataPath", str(derived), "-clonedSourcePackagesDirPath", str(packages),
               "-disableAutomaticPackageResolution", "-skipPackageUpdates", "-jobs", "2",
               "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
               "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "30",
               "-maximum-test-execution-time-allowance", "60", "-resultBundlePath", str(result),
               "CODE_SIGNING_ALLOWED=NO", "SPATTER_BACKEND_URL=", "SUPABASE_URL=",
               "SUPABASE_PUBLISHABLE_KEY=", "SUPABASE_ANON_KEY=", "LIVEKIT_WS_URL=",
               "SDI_OAUTH_PROVIDERS=", "SDI_MICROSOFT_TENANT="]
    start = time.monotonic()
    code = run(command, evidence / "auth-tests.log", 900)
    receipt = {"source": commit, "exitCode": code, "seconds": time.monotonic() - start,
               "runtimeVerified": False}
    try:
        exported = run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)],
                       evidence / "summary.json", 60)
        if exported == 0:
            summary = json.loads((evidence / "summary.json").read_text())
            receipt["runtimeVerified"] = (code == 0 and summary.get("passedTests") == 12
                                           and summary.get("failedTests") == 0
                                           and summary.get("skippedTests", 0) == 0)
    finally:
        (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return code if code else (0 if receipt["runtimeVerified"] else 3)


if __name__ == "__main__":
    raise SystemExit(main())

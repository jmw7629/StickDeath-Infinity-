#!/usr/bin/env python3
"""Compile the checked-in iOS app and capture isolated, unconfigured launch evidence."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import plistlib
import re
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
if os.environ.get("GITHUB_ACTIONS") != "true":
    raise RuntimeError("This compile/capture helper is restricted to ephemeral CI")
if subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain=v1"]):
    raise RuntimeError("Preserve unexpected checkout changes before native compilation")
OUT = Path(os.environ["RUNNER_TEMP"]) / "sdi-native-compile-evidence"
BUILD = Path(os.environ["RUNNER_TEMP"]) / "sdi-native-compile"
OUT.mkdir(exist_ok=False)
BUILD.mkdir(exist_ok=False)

def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def inputs():
    names = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z"]).decode().split("\0")
    return {name: sha(ROOT / name) for name in names if name and (
        name.startswith("StickDeathInfinity/") or name.startswith("StickDeathInfinity.xcodeproj/")
        or name.startswith("Tests/NativeAuth/"))}

env = dict(os.environ, TMPDIR=str(BUILD))
xcode = subprocess.check_output(["xcodebuild", "-version"], env=env, text=True)
if not re.search(r"Xcode (?:2[6-9]|[3-9][0-9])(?:\.|\s)", xcode):
    choices = []
    for app in Path("/Applications").glob("Xcode_26*.app"):
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        version = tuple(int(x) for x in re.findall(r"\d+", info["CFBundleShortVersionString"]))
        choices.append((version, app))
    if not choices:
        raise RuntimeError("Xcode 26 is required for this native compile")
    env["DEVELOPER_DIR"] = str(max(choices, key=lambda x: x[0])[1] / "Contents/Developer")
    xcode = subprocess.check_output(["xcodebuild", "-version"], env=env, text=True)

before = inputs()
if not before:
    raise RuntimeError("Native input inventory is empty")
(OUT / "input-sha256.json").write_text(json.dumps(before, indent=2) + "\n")
args = ["xcodebuild", "-project", "StickDeathInfinity.xcodeproj", "-scheme", "StickDeathInfinity",
        "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", str(BUILD / "DerivedData"), "-clonedSourcePackagesDirPath", str(BUILD / "Packages"),
        "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
        "-jobs", "2", "CODE_SIGNING_ALLOWED=NO", "build"]
(OUT / "argv.json").write_text(json.dumps(args, indent=2) + "\n")
receipt = {"sourceCommit": git("rev-parse", "HEAD"), "sourceTree": git("rev-parse", "HEAD^{tree}"),
           "toolchain": xcode.strip(), "action": "unsigned iOS Simulator app build",
           "startedAt": now(), "nativeInputCount": len(before),
           "runtimeVerified": False, "deviceSigningVerified": False, "status": "running"}
(OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
start = time.monotonic()
with (OUT / "xcodebuild.log").open("w") as log:
    child = subprocess.Popen(args, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    while True:
        try:
            code = child.wait(timeout=30)
            break
        except subprocess.TimeoutExpired:
            print(f"Native app compilation active: {int(time.monotonic()-start)}s", flush=True)
            if time.monotonic() - start >= 1500:
                os.killpg(child.pid, signal.SIGINT)
                try:
                    code = child.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        code = child.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        code = child.wait()
                receipt["timeout"] = True
                break
after = inputs()
app = BUILD / "DerivedData/Build/Products/Debug-iphonesimulator/StickDeathInfinity.app"
matched = before == after
receipt.update(buildExitCode=code, nativeInputsPostflightMatched=matched, completedAt=now(),
               status="passed" if code == 0 and matched and app.is_dir() else "failed")
if app.is_dir():
    receipt["appBinariesSHA256"] = {p.name: sha(p) for p in app.iterdir()
                                   if p.is_file() and (p.name == "StickDeathInfinity" or p.suffix == ".dylib")}
(OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt), flush=True)
if receipt["status"] != "passed":
    raise SystemExit(1)

capture = {"sourceCommit": receipt["sourceCommit"], "scope": "isolated native launch only; not Studio journey acceptance",
           "status": "unavailable"}
owned = None
try:
    previous = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"], env=env))
    previous_ids = {d["udid"] for ds in previous["devices"].values() for d in ds}
    created = subprocess.run(["python3", "scripts/native-smoke/select_simulator.py", "--device", "iphone"],
                             cwd=ROOT, env=env, text=True, capture_output=True, timeout=90, check=True)
    candidate = created.stdout.strip().splitlines()[-1]
    if candidate in previous_ids or not re.fullmatch(r"[A-Fa-f0-9-]{36}", candidate):
        raise RuntimeError("Capture selector did not return a newly owned simulator")
    marker = Path(os.environ["RUNNER_TEMP"]) / "sdi-fresh-simulator.json"
    marker_data = marker.read_bytes()
    if len(marker_data) > 16 * 1024:
        raise RuntimeError("Capture ownership marker exceeded its bound")
    evidence = json.loads(marker_data)
    if evidence.get("state") != "verified" or evidence.get("created", {}).get("udid") != candidate or evidence.get("sourceCommit") != receipt["sourceCommit"]:
        raise RuntimeError("Capture ownership marker does not match this source/device")
    owned = candidate
    (OUT / "fresh-simulator.json").write_bytes(marker_data)
    capture["simulatorUDID"] = owned
    subprocess.run(["xcrun", "simctl", "boot", owned], env=env, capture_output=True, timeout=30, check=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", owned, "-b"], env=env, capture_output=True, timeout=180, check=True)
    subprocess.run(["xcrun", "simctl", "install", owned, str(app)], env=env, capture_output=True, timeout=60, check=True)
    bundle = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
    subprocess.run(["xcrun", "simctl", "launch", owned, bundle], env=env, capture_output=True, timeout=30, check=True)
    time.sleep(0.8)
    for name, delay in [("launch-early.png", 0), ("launch-settled.png", 3)]:
        if delay:
            time.sleep(delay)
        subprocess.run(["xcrun", "simctl", "io", owned, "screenshot", str(OUT / name)],
                       env=env, capture_output=True, timeout=30, check=True)
    capture.update(status="captured", screenshots={n: sha(OUT / n) for n in ["launch-early.png", "launch-settled.png"]})
except Exception as e:
    capture.update(status="unavailable", reasonType=type(e).__name__)
    detail = getattr(e, "stderr", None) or str(e)
    (OUT / "capture-error.txt").write_bytes(detail if isinstance(detail, bytes) else str(detail).encode())
finally:
    if owned:
        capture["cleanup"] = "Ephemeral CI teardown; no device erase or delete"
        try:
            result = subprocess.run(["xcrun", "simctl", "shutdown", owned], env=env, capture_output=True, timeout=30)
            capture["ownedSimulatorShutdownExitCode"] = result.returncode
            capture["cleanupStatus"] = "passed" if result.returncode == 0 else "failed"
        except (subprocess.TimeoutExpired, OSError) as e:
            capture["cleanupStatus"] = "failed"
            capture["cleanupReasonType"] = type(e).__name__
(OUT / "capture.json").write_text(json.dumps(capture, indent=2) + "\n")
print(json.dumps(capture), flush=True)

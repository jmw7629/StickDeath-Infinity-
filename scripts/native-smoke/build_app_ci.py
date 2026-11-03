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

from seed_diagnostics import result_projection, run_bounded, text_projection

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

LIBRARY_SCOPE = "isolated native empty project library only; not Studio journey acceptance"
LIBRARY_ARGUMENTS = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                     "-sdi.guest.chosen.v1", "YES", "-tutorial_completed", "YES"]
LIBRARY_OFFLINE_SETTINGS = (
    "SPATTER_BACKEND_URL", "SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY", "LIVEKIT_WS_URL",
    "SDI_UPLOAD_SERVICE_URL", "SDI_RENDER_PREVIEW_URL", "SDI_PUBLISHING_CONSENT_VERSION", "SDI_PUBLISHING_TERMS_URL",
    "SDI_OAUTH_PROVIDERS", "SDI_MICROSOFT_TENANT", "SDI_STOREKIT_PLAN_4_99_PRODUCT_ID",
    "SDI_STOREKIT_PLAN_9_99_PRODUCT_ID", "SDI_STOREKIT_PLAN_19_99_PRODUCT_ID",
    "SDI_STOREKIT_PLAN_4_99_ANNUAL_PRODUCT_ID", "SDI_STOREKIT_PLAN_9_99_ANNUAL_PRODUCT_ID",
    "SDI_STOREKIT_CREDITS_SMALL_PRODUCT_ID", "SDI_STOREKIT_CREDITS_LARGE_PRODUCT_ID",
    "SDI_BILLING_ANNUAL_OWNER_CONFIGURED",
)

def library_offline_preflight(info, environment):
    # Match AppConfig.configuredString: whitespace-only and unexpanded Xcode
    # settings are unavailable. Refuse every remaining value, including invalid
    # endpoints, rather than trying to authenticate or probe a configured service.
    def configured(value):
        return isinstance(value, str) and bool(value.strip()) and "$(" not in value and "${" not in value
    for key in LIBRARY_OFFLINE_SETTINGS:
        if configured(info.get(key)) or configured(environment.get(key)) or configured(environment.get("SIMCTL_CHILD_" + key)):
            raise RuntimeError("Library capture requires an unconfigured build and launch environment")
    return {"status": "unconfigured", "checkedSettings": list(LIBRARY_OFFLINE_SETTINGS),
            "environmentChecked": True, "networkTrafficMeasured": False}

capture_stage = "simulator-inventory"
capture_steps = []

def capture_command(stage, arguments, seconds):
    """One bounded owned-device command; acknowledgement is never frame proof."""
    global capture_stage
    capture_stage = stage
    started = time.monotonic()
    # run_bounded inherits the process environment. Preserve this helper's
    # selected Xcode and private scratch directory without changing that API.
    command = ["/usr/bin/env", *(key + "=" + env[key] for key in ("DEVELOPER_DIR", "TMPDIR") if key in env),
               *arguments]
    result = run_bounded(command, started + seconds + 1, stdout_cap=16 * 1024,
                         stderr_cap=16 * 1024, work_deadline=started + seconds)
    step = {"stage": stage, "timeoutSeconds": seconds,
            "result": result_projection(result)}
    if stage in {"owned-app-launch", "owned-library-launch"}:
        # These fixed simctl launch commands do not attach the app console or
        # print launch arguments/environment. Preserve bounded command output
        # privately so an actual launch failure is distinguishable from an
        # exited command whose descendant retained a capture pipe.
        outputs = {}
        for stream, data in (("stdout", result.stdout), ("stderr", result.stderr)):
            name = stage + "." + stream + ".txt"
            (OUT / name).write_bytes(data)
            outputs[stream] = {"file": name, "bytesRetained": len(data),
                               "sha256": hashlib.sha256(data).hexdigest()}
        step["privateCommandOutput"] = outputs
    capture_steps.append(step)
    if result.spawn_error:
        raise OSError("The capture command could not be started")
    if result.timed_out:
        raise subprocess.TimeoutExpired(arguments, seconds)
    if result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, arguments)
    return result.stdout

def capture_error(name, error):
    # Retain only fixed stages, numeric results and irreversible projections in
    # existing private artifact members. No argv, environment or raw log text.
    detail = getattr(error, "stderr", None) or str(error)
    raw = detail if isinstance(detail, bytes) else str(detail).encode()
    report = {"scope": "private capture diagnostics; not app or display acceptance",
              "stage": capture_stage, "reasonType": type(error).__name__,
              "steps": capture_steps, "error": text_projection(raw[:16 * 1024])}
    data = (json.dumps(report, indent=2) + "\n").encode()
    if len(data) > 32 * 1024:
        data = (json.dumps({"stage": capture_stage, "reasonType": type(error).__name__,
                           "diagnosticByteBudgetExceeded": True}) + "\n").encode()
    (OUT / name).write_bytes(data)

capture = {"sourceCommit": receipt["sourceCommit"], "scope": "isolated native launch only; not Studio journey acceptance",
           "status": "unavailable"}
owned = None
try:
    previous = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"], env=env))
    previous_ids = {d["udid"] for ds in previous["devices"].values() for d in ds}
    capture_stage = "fresh-simulator-selection"
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
    capture_stage = "owned-simulator-boot"
    subprocess.run(["xcrun", "simctl", "boot", owned], env=env, capture_output=True, timeout=30, check=True)
    capture_stage = "owned-simulator-bootstatus"
    subprocess.run(["xcrun", "simctl", "bootstatus", owned, "-b"], env=env, capture_output=True, timeout=180, check=True)
    # Experimental display activation after ca5 installed/launched successfully
    # but its first screenshot timed out. Headless capture is supported; this is
    # not a proven cause/fix. Never launch the default/recent simulator instead.
    try:
        capture_stage = "selected-sdk-simulator-path"
        developer = env.get("DEVELOPER_DIR") or capture_command(
            "selected-sdk-path", ["/usr/bin/xcode-select", "-p"], 10).decode().strip()
        simulator = Path(developer) / "Applications/Simulator.app"
        if not simulator.is_dir():
            raise RuntimeError("The selected SDK has no Simulator application")
        capture_command("owned-simulator-ui-activation", ["/usr/bin/open", "-a", str(simulator),
                        "--args", "-CurrentDeviceUDID", owned], 30)
        # One read-only IO acknowledgement; descriptor text is not interpreted as
        # a rendered display. Only the original PNG captures count below.
        capture_command("owned-display-io-enumeration", ["xcrun", "simctl", "io", owned, "enumerate"], 15)
    except Exception as e:
        # Optional setup must never disable the supported headless capture path.
        # Retain its bounded failure only if a later actual capture also fails.
        capture_steps.append({"stage": capture_stage, "optionalDisplaySetup": "unavailable",
                              "reasonType": type(e).__name__, "continuedHeadlessCapture": True})
    capture_stage = "owned-app-install"
    subprocess.run(["xcrun", "simctl", "install", owned, str(app)], env=env, capture_output=True, timeout=180, check=True)
    built_info = plistlib.loads((app / "Info.plist").read_bytes())
    bundle = built_info["CFBundleIdentifier"]
    capture_stage = "owned-app-launch"
    capture_command("owned-app-launch", ["xcrun", "simctl", "launch", owned, bundle], 30)
    time.sleep(0.8)
    for name, delay in [("launch-early.png", 0), ("launch-settled.png", 3)]:
        if delay:
            time.sleep(delay)
        capture_command(name, ["xcrun", "simctl", "io", owned, "screenshot", str(OUT / name)], 30)
    capture.update(status="captured", screenshots={n: sha(OUT / n) for n in ["launch-early.png", "launch-settled.png"]})
    # This optional second presentation uses the real remembered-guest route.
    # No document/media is seeded and no editor, project or panel is auto-opened.
    library = {"sourceCommit": receipt["sourceCommit"], "sourceTree": receipt["sourceTree"],
               "appExecutableSHA256FromBuildReceipt": receipt["appBinariesSHA256"]["StickDeathInfinity"],
               "scope": LIBRARY_SCOPE, "status": "unavailable", "projectsSeeded": False,
               "routeEvidence": "source-derived existing preferences; screenshot inspection required"}
    capture["library"] = library
    try:
        capture_stage = "library-offline-preflight"
        library["offlineConfiguration"] = library_offline_preflight(built_info, env)
        if bundle != "com.willisbmb.StickDeathInfinity":
            raise RuntimeError("Unexpected native app identity")
        capture_stage = "owned-library-terminate"
        subprocess.run(["xcrun", "simctl", "terminate", owned, bundle], env=env, capture_output=True, timeout=30, check=True)
        capture_stage = "owned-library-launch"
        capture_command("owned-library-launch", ["xcrun", "simctl", "launch", owned, bundle, *LIBRARY_ARGUMENTS], 30)
        time.sleep(3)
        name = "projects-library.png"
        capture_command(name, ["xcrun", "simctl", "io", owned, "screenshot", str(OUT / name)], 30)
        library.update(status="captured", launchArguments=LIBRARY_ARGUMENTS,
                       screenshot={"file": name, "sha256": sha(OUT / name)})
    except Exception as e:
        # Keep both valid original launch captures and the passed build receipt.
        # A partial optional image never becomes a claimed library capture.
        library.update(status="unavailable", reasonType=type(e).__name__)
        try:
            capture_error("library-capture-error.txt", e)
        except OSError:
            pass  # An optional error log must not relabel the original captures.
except Exception as e:
    capture.update(status="unavailable", reasonType=type(e).__name__)
    capture_error("capture-error.txt", e)
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
capture["commandSteps"] = capture_steps
(OUT / "capture.json").write_text(json.dumps(capture, indent=2) + "\n")
print(json.dumps(capture), flush=True)

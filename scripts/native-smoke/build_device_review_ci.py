#!/usr/bin/env python3
"""Build an unsigned, offline SDI Review device artifact on hosted CI only.

This helper neither signs nor installs an app. Its package becomes eligible for
upload only after exact-source, arm64/iOS-device and unsigned-payload checks.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import signal
import stat
import struct
import subprocess
import time
import zipfile

REPOSITORY = "jmw7629/StickDeath-Infinity-"
APP = "StickDeathInfinity"
BUNDLE = "com.willisbmb.StickDeathInfinity.review"
ORIGINAL_BUNDLE = "com.willisbmb.StickDeathInfinity"
RESOURCE_INFO = "swift-crypto_Crypto.bundle/Info.plist"
RESOURCE_BUNDLE = "swift-crypto.Crypto.resources"
GIB = 1024 ** 3
MAX_APP_BYTES = 512 * 1024 ** 2
MAX_FILES = 10_000
MAX_LOG_BYTES = 32 * 1024 ** 2
BUILD_SECONDS = 1800
PACKAGE_SECONDS = 180
OVERALL_SECONDS = 2100
WORK_DEADLINE = None
OFFLINE_SETTINGS = (
    "SPATTER_BACKEND_URL", "SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY", "LIVEKIT_WS_URL",
    "SDI_UPLOAD_SERVICE_URL", "SDI_RENDER_PREVIEW_URL", "SDI_PUBLISHING_CONSENT_VERSION", "SDI_PUBLISHING_TERMS_URL",
    "SDI_OAUTH_PROVIDERS", "SDI_MICROSOFT_TENANT", "SDI_STOREKIT_PLAN_4_99_PRODUCT_ID",
    "SDI_STOREKIT_PLAN_9_99_PRODUCT_ID", "SDI_STOREKIT_PLAN_19_99_PRODUCT_ID",
    "SDI_STOREKIT_PLAN_4_99_ANNUAL_PRODUCT_ID", "SDI_STOREKIT_PLAN_9_99_ANNUAL_PRODUCT_ID",
    "SDI_STOREKIT_CREDITS_SMALL_PRODUCT_ID", "SDI_STOREKIT_CREDITS_LARGE_PRODUCT_ID",
    "SDI_BILLING_ANNUAL_OWNER_CONFIGURED",
)
MACHO_MAGICS = {bytes.fromhex(x) for x in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def check_time():
    if WORK_DEADLINE is not None and time.monotonic() >= WORK_DEADLINE:
        raise TimeoutError("Unsigned device preparation exceeded its overall work deadline")


def require_sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise ValueError("An exact lowercase 40-hex source commit is required")
    return value


def identity(path):
    s = path.lstat()
    return (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns)


def read_regular(path, maximum):
    before = identity(path)
    if not stat.S_ISREG(before[2]) or before[3] > maximum:
        raise ValueError("Expected a bounded regular input")
    with path.open("rb") as stream:
        if (os.fstat(stream.fileno()).st_dev, os.fstat(stream.fileno()).st_ino) != before[:2]:
            raise ValueError("Input changed while opening")
        data = stream.read(maximum + 1)
    if len(data) != before[3] or identity(path) != before:
        raise ValueError("Input changed during reading")
    return data


def sha_file(path):
    before = identity(path)
    if not stat.S_ISREG(before[2]):
        raise ValueError("Expected a regular file for hashing")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        if (os.fstat(stream.fileno()).st_dev, os.fstat(stream.fileno()).st_ino) != before[:2]:
            raise ValueError("File changed while opening for hashing")
        for block in iter(lambda: stream.read(64 * 1024), b""):
            digest.update(block)
    if identity(path) != before:
        raise ValueError("File changed during hashing")
    return digest.hexdigest()


def write_json(path, value):
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    if len(data) > 8 * 1024 ** 2:
        raise ValueError("Evidence JSON exceeds its bound")
    with path.open("wb") as stream:
        stream.write(data)
    os.chmod(path, 0o600)


def command(argv, *, cwd, env, maximum=8 * 1024 ** 2):
    check_time()
    deadline = time.monotonic() + 20
    if WORK_DEADLINE is not None:
        deadline = min(deadline, WORK_DEADLINE)
    child = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    streams = {"stdout": bytearray(), "stderr": bytearray()}
    selector = selectors.DefaultSelector()
    reason = None
    exited_at = None
    try:
        for name in streams:
            pipe = getattr(child, name)
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, name)
        while selector.get_map() or child.poll() is None:
            now = time.monotonic()
            if now >= deadline:
                reason = "metadata command time budget"
                break
            if child.poll() is not None:
                exited_at = now if exited_at is None else exited_at
                if now - exited_at > 1 and selector.get_map():
                    reason = "metadata descendant retained output pipe"
                    break
            for key, _ in selector.select(min(0.1, deadline - now)):
                try:
                    data = os.read(key.fileobj.fileno(), 64 * 1024)
                except BlockingIOError:
                    continue
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                target = streams[key.data]
                keep = min(len(data), maximum - len(target))
                target.extend(data[:keep])
                if keep != len(data):
                    reason = "metadata command output byte budget"
                    break
            if reason:
                break
    finally:
        stop_owned(child, retained_pipe=bool(reason and selector.get_map()))
        selector.close()
        child.stdout.close()
        child.stderr.close()
    if reason or child.returncode:
        error = subprocess.CalledProcessError(child.returncode, argv, bytes(streams["stdout"]), bytes(streams["stderr"]))
        error.budget_reason = reason
        raise error
    return bytes(streams["stdout"])


def require_ci(environment):
    required = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS",
                "GITHUB_EVENT_NAME": "workflow_dispatch", "SDI_DELIVERY_MODE": "unsigned_review",
                "GITHUB_REPOSITORY": REPOSITORY, "GITHUB_JOB": "unsigned-review"}
    if any(environment.get(key) != value for key, value in required.items()):
        raise ValueError("Explicit unsigned_review dispatch on the existing hosted Mac job is required")
    expected = require_sha(environment.get("SDI_EXPECTED_HEAD"))
    if require_sha(environment.get("GITHUB_SHA")) != expected:
        raise ValueError("Dispatch source and expected source differ")
    if require_sha(environment.get("GITHUB_WORKFLOW_SHA")) != expected:
        raise ValueError("Workflow version must equal the reviewed dispatch source")
    for key in ("GITHUB_RUN_ID", "GITHUB_RUN_NUMBER", "GITHUB_RUN_ATTEMPT"):
        if not re.fullmatch(r"[1-9][0-9]{0,19}", environment.get(key, "")):
            raise ValueError("Positive bounded CI run metadata is required")
    if not environment.get("GITHUB_REF", "").startswith(("refs/heads/", "refs/tags/")):
        raise ValueError("An explicit dispatch branch or tag is required")
    return expected


def require_unconfigured(info, environment):
    for key in OFFLINE_SETTINGS:
        for values, name in ((info, key), (environment, key), (environment, "SIMCTL_CHILD_" + key)):
            if name in values and (not isinstance(values[name], str) or values[name].strip()):
                raise ValueError("Unsigned Review requires absent or blank service and billing configuration")


def source_snapshot(root, env, expected):
    def git(*args):
        return command(["git", "-C", str(root), *args], cwd=root, env=env)
    if git("rev-parse", "HEAD").decode().strip() != expected:
        raise ValueError("Checkout HEAD differs from the expected source")
    # No path-prefix exclusions, ignored source exceptions or generated outputs
    # in the checkout. All build products and generated metadata live in scratch.
    if git("status", "--porcelain=v1", "--untracked-files=all", "--ignored"):
        raise ValueError("Preserve unexpected tracked, untracked or ignored checkout changes")
    tree = require_sha(git("rev-parse", "HEAD^{tree}").decode().strip())
    entries = git("ls-files", "--stage", "-z").split(b"\0")
    files = {}
    total = 0
    for entry in entries:
        check_time()
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, blob, stage = metadata.decode().split()
        name = raw_name.decode("utf-8")
        if (mode not in {"100644", "100755"} or stage != "0" or name in files or
                name.startswith("/") or ".." in Path(name).parts or "\\" in name):
            raise ValueError("Unsupported tracked source entry")
        path = root / name
        before = identity(path)
        if (not stat.S_ISREG(before[2]) or path.resolve(strict=True) != path or
                bool(before[2] & 0o111) != (mode == "100755")):
            raise ValueError("Tracked source type, location or mode differs from the index")
        total += before[3]
        if len(files) >= MAX_FILES or total > 2 * GIB:
            raise ValueError("Tracked source inventory exceeds its bound")
        digest = hashlib.sha256()
        git_digest = hashlib.sha1(b"blob " + str(before[3]).encode() + b"\0")
        with path.open("rb") as stream:
            if (os.fstat(stream.fileno()).st_dev, os.fstat(stream.fileno()).st_ino) != before[:2]:
                raise ValueError("Source changed while opening")
            for block in iter(lambda: stream.read(64 * 1024), b""):
                check_time()
                digest.update(block)
                git_digest.update(block)
        if identity(path) != before or git_digest.hexdigest() != blob:
            raise ValueError("Tracked source bytes differ from the exact Git blob")
        files[name] = {"mode": mode, "gitBlob": blob, "bytes": before[3], "sha256": digest.hexdigest()}
    if not files or "StickDeathInfinity/Info.plist" not in files:
        raise ValueError("The complete application source inventory is required")
    return {"sourceCommit": expected, "sourceTree": tree, "scope": "all tracked stage-zero files; no exclusions",
            "trackedCount": len(files), "trackedBytes": total, "files": files}


def review_metadata(original, commit, tree, run_number, run_id, attempt):
    if original.get("CFBundleIdentifier") != ORIGINAL_BUNDLE or original.get("CFBundlePackageType") != "APPL":
        raise ValueError("Unexpected original app metadata")
    number = int(run_number)
    if not 1 <= number <= 99_989_999:
        raise ValueError("CI run number exceeds the Review build-version range")
    overrides = {"CFBundleIdentifier": BUNDLE, "CFBundleName": "SDI Review", "CFBundleDisplayName": "SDI Review",
                 "CFBundleVersion": f"{1 + number // 10000}.{number // 100 % 100}.{number % 100}",
                 "CFBundleURLTypes": [{"CFBundleURLName": BUNDLE, "CFBundleURLSchemes": ["stickdeath-review"]}],
                 "SDIReviewSourceCommit": require_sha(commit), "SDIReviewSourceTree": require_sha(tree),
                 "SDIReviewVariant": "unsigned-isolated-device-review", "SDIReviewCIRunID": run_id,
                 "SDIReviewCIRunAttempt": attempt, **{key: "" for key in OFFLINE_SETTINGS}}
    return {**original, **overrides}, overrides


def build_arguments(scratch, metadata):
    return ["xcodebuild", "-project", "StickDeathInfinity.xcodeproj", "-scheme", APP,
            "-configuration", "Debug", "-sdk", "iphoneos", "-destination", "generic/platform=iOS",
            "-derivedDataPath", str(scratch / "DerivedData"),
            "-clonedSourcePackagesDirPath", str(scratch / "Packages"),
            "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates",
            "-jobs", "2", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", "IPHONEOS_DEPLOYMENT_TARGET=17.0",
            "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM=",
            "PRODUCT_BUNDLE_IDENTIFIER=" + BUNDLE, "INFOPLIST_FILE=" + str(metadata),
            "OTHER_LDFLAGS=$(inherited) -no_adhoc_codesign", *(key + "=" for key in OFFLINE_SETTINGS), "build"]


class Guard:
    def __init__(self, runner, scratch):
        self.runner, self.scratch = runner, scratch
        self.minimum = None
        self.last_size_check = 0.0

    def check(self, *, initial=False):
        check_time()
        free = shutil.disk_usage(self.runner).free
        self.minimum = free if self.minimum is None else min(self.minimum, free)
        if free < (8 * GIB if initial else 4 * GIB):
            raise RuntimeError("Hosted runner scratch free-space floor reached")
        now = time.monotonic()
        if now - self.last_size_check < 20:
            return
        total = count = 0
        for directory, folders, files in os.walk(self.scratch, followlinks=False):
            for name in folders + files:
                try:
                    s = (Path(directory) / name).lstat()
                except FileNotFoundError:
                    continue  # A compiler may remove its own transient output.
                count += 1
                if stat.S_ISREG(s.st_mode):
                    total += s.st_size
                if total > 16 * GIB or count > 250_000:
                    raise RuntimeError("Owned CI build scratch exceeded its disk or entry bound")
        self.last_size_check = now


def stop_owned(child, *, retained_pipe=False):
    if child.poll() is not None and not retained_pipe:
        return
    for sig, seconds in ((signal.SIGINT, 5), (signal.SIGTERM, 5), (signal.SIGKILL, 5)):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            break
        if child.poll() is not None:
            # The direct child has exited but an owned descendant kept its
            # output pipe. Terminate that original process group as well.
            if retained_pipe:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            break
        try:
            child.wait(timeout=seconds)
            break
        except subprocess.TimeoutExpired:
            pass
    # A stopped driver may exit before its compiler descendants. The process
    # group was created exclusively for this command, so finish its cleanup.
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def compile_once(argv, root, env, log_path, guard):
    started = time.monotonic()
    result = {"status": "running", "maximumSeconds": BUILD_SECONDS, "maximumLogBytes": MAX_LOG_BYTES,
              "logBytesObserved": 0, "logBytesRetained": 0, "stopReason": None}
    with log_path.open("xb") as log:
        child = subprocess.Popen(argv, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        selector = selectors.DefaultSelector()
        os.set_blocking(child.stdout.fileno(), False)
        selector.register(child.stdout, selectors.EVENT_READ)
        next_guard = next_progress = started
        exited_at = None
        try:
            while selector.get_map() or child.poll() is None:
                now = time.monotonic()
                if now >= started + BUILD_SECONDS:
                    result["stopReason"] = "build-time-budget"
                    break
                if now >= next_guard:
                    try:
                        guard.check()
                    except (RuntimeError, TimeoutError):
                        result["stopReason"] = "scratch-or-overall-budget"
                        break
                    next_guard = now + 2
                if now >= next_progress:
                    print(f"Unsigned device compilation active: {int(now - started)}s", flush=True)
                    next_progress = now + 30
                if child.poll() is not None:
                    exited_at = now if exited_at is None else exited_at
                    if now - exited_at > 2 and selector.get_map():
                        result["stopReason"] = "descendant-retained-output-pipe"
                        break
                for key, _ in selector.select(0.25):
                    try:
                        data = os.read(key.fileobj.fileno(), 64 * 1024)
                    except BlockingIOError:
                        continue
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    result["logBytesObserved"] += len(data)
                    keep = min(len(data), MAX_LOG_BYTES - result["logBytesRetained"])
                    log.write(data[:keep])
                    result["logBytesRetained"] += keep
                    if keep != len(data):
                        result["stopReason"] = "build-log-byte-budget"
                        break
                if result["stopReason"]:
                    break
        except Exception as error:
            result["stopReason"] = "build-output-collection-failure"
            result["collectionReasonType"] = type(error).__name__
        finally:
            stop_owned(child, retained_pipe=bool(result["stopReason"] and selector.get_map()))
            selector.close()
            child.stdout.close()
            result.update(exitCode=child.returncode, elapsedSeconds=round(time.monotonic() - started, 6),
                          ownedChildReaped=child.poll() is not None,
                          status="passed" if child.returncode == 0 and not result["stopReason"] else "failed")
    return result


def version_string(number):
    return f"{number >> 16}.{number >> 8 & 255}.{number & 255}"


def inspect_macho(path):
    """Read bounded Mach-O headers; reject Simulator, fat, signed and legacy code."""
    with path.open("rb") as stream:
        header = stream.read(32)
        if len(header) != 32 or header[:4] != b"\xcf\xfa\xed\xfe":
            raise ValueError("Every native payload must be a thin little-endian 64-bit Mach-O")
        _, cpu, subtype, filetype, ncmds, size, flags, _ = struct.unpack("<IiiIIIII", header)
        if cpu != 0x0100000C or subtype & 0xFFFFFF != 0 or filetype not in {2, 6, 8}:
            raise ValueError("Every native payload must be arm64 device executable code")
        if ncmds > 8192 or size > 2 * 1024 ** 2 or size > path.stat().st_size - 32:
            raise ValueError("Mach-O load-command bounds are invalid")
        commands = stream.read(size)
    offset = 0
    build = None
    dependencies = []
    rpaths = []
    for _ in range(ncmds):
        if offset + 8 > len(commands):
            raise ValueError("Truncated Mach-O load command")
        kind, length = struct.unpack_from("<II", commands, offset)
        if length < 8 or length % 8 or offset + length > len(commands):
            raise ValueError("Invalid Mach-O load-command length")
        payload = commands[offset:offset + length]
        plain = kind & 0x7FFFFFFF
        if plain == 0x1D:
            raise ValueError("Code signature load command is forbidden in the unsigned review artifact")
        if plain == 0x32:
            if length < 24 or build is not None:
                raise ValueError("Missing or duplicate device build-version command")
            platform, minimum, sdk, tools = struct.unpack_from("<IIII", payload, 8)
            if platform != 2 or 24 + tools * 8 != length:
                raise ValueError("Native payload is not an iOS-device build")
            build = {"platform": "iOS", "minimumOS": version_string(minimum), "sdk": version_string(sdk)}
        if plain in {0xC, 0xD, 0x18, 0x1F, 0x23, 0x1C}:
            fixed = 12 if plain == 0x1C else 24
            if length < fixed:
                raise ValueError("Truncated native dynamic-link command")
            start = struct.unpack_from("<I", payload, 8)[0]
            if not fixed <= start < length or b"\0" not in payload[start:]:
                raise ValueError("Invalid native dynamic-link path")
            name = payload[start:].split(b"\0", 1)[0].decode("utf-8")
            if not name.startswith(("@rpath/", "@executable_path/", "@loader_path/", "/System/Library/", "/usr/lib/")):
                raise ValueError("Unexpected absolute or relative native dependency path")
            (rpaths if plain == 0x1C else dependencies).append(name)
        offset += length
    if offset != size or build is None:
        raise ValueError("Complete LC_BUILD_VERSION device evidence is required")
    return {"architecture": "arm64", "fileType": filetype, "headerFlags": flags,
            "buildVersion": build, "dependencies": dependencies, "rpaths": rpaths, "signature": "absent"}


def app_inventory(app, check):
    if app.is_symlink() or not app.is_dir():
        raise ValueError("A real built application directory is required")
    result = {}
    total = directories = 0
    for directory, folders, files in os.walk(app, followlinks=False):
        for name in sorted(folders + files):
            check()
            path = Path(directory) / name
            relative = path.relative_to(app).as_posix()
            entry = identity(path)
            if ("\\" in relative or any(ord(c) < 32 for c in relative) or len(relative.encode()) > 1024 or
                    entry[2] & 0o7000 or not (stat.S_ISDIR(entry[2]) or stat.S_ISREG(entry[2]))):
                raise ValueError("Linked, special or unsafe application member")
            if ("_CodeSignature" in path.relative_to(app).parts or path.suffix.lower() in
                    {".mobileprovision", ".p12", ".pfx", ".p8", ".key", ".pem", ".cer", ".der"}):
                raise ValueError("Provisioning, certificate, key or signature material cannot enter the package")
            if stat.S_ISDIR(entry[2]):
                directories += 1
                if directories > MAX_FILES or path.suffix in {".app", ".appex"}:
                    raise ValueError("Unexpected nested application or excessive directory count")
                continue
            total += entry[3]
            if total > MAX_APP_BYTES or len(result) >= MAX_FILES:
                raise ValueError("Application payload exceeds the review byte or file budget")
            result[relative] = {"bytes": entry[3], "mode": stat.S_IMODE(entry[2]), "sha256": sha_file(path)}
    if not result:
        raise ValueError("Built application is empty")
    return result


def correct_resource_identity(app, evidence):
    path = app / RESOURCE_INFO
    if not path.exists():
        return []
    raw = read_regular(path, 1024 ** 2)
    info = plistlib.loads(raw)
    if info.get("CFBundleIdentifier") == RESOURCE_BUNDLE:
        return []
    if info.get("CFBundleIdentifier") != BUNDLE or info.get("CFBundleExecutable"):
        raise ValueError("Unexpected swift-crypto nonexecutable resource identity")
    # The explicit global Review bundle override also reaches this SwiftPM
    # resource target. Restore only its known resource ID, never native code.
    (evidence / "crypto-resource-info-before.plist").write_bytes(raw)
    info["CFBundleIdentifier"] = RESOURCE_BUNDLE
    path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False))
    return [{"path": RESOURCE_INFO, "key": "CFBundleIdentifier", "before": BUNDLE, "after": RESOURCE_BUNDLE,
             "beforeSHA256": hashlib.sha256(raw).hexdigest(), "afterSHA256": sha_file(path)}]


def validate_product(app, expected_info, files, check):
    info = plistlib.loads(read_regular(app / "Info.plist", 1024 ** 2))
    for key in ("CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleVersion", "CFBundleURLTypes",
                "SDIReviewSourceCommit", "SDIReviewSourceTree", "SDIReviewVariant", "SDIReviewCIRunID", "SDIReviewCIRunAttempt"):
        if info.get(key) != expected_info[key]:
            raise ValueError("Built Review identity or source metadata differs from the declared override")
    if (info.get("CFBundleExecutable") != APP or info.get("CFBundlePackageType") != "APPL" or
            info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"] or info.get("DTPlatformName") != "iphoneos" or
            info.get("MinimumOSVersion") != "17.0"):
        raise ValueError("Built metadata does not identify the intended iOS-device application")
    require_unconfigured(info, {})
    binaries = {}
    for name in files:
        check()
        path = app / name
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic in MACHO_MAGICS:
            binaries[name] = inspect_macho(path)
            minimum = tuple(int(x) for x in binaries[name]["buildVersion"]["minimumOS"].split("."))
            if minimum > (17, 0, 0):
                raise ValueError("Embedded native code exceeds the app's supported minimum iOS version")
        if name.endswith("/Info.plist"):
            nested = plistlib.loads(read_regular(path, 1024 ** 2))
            if nested.get("CFBundleIdentifier") == BUNDLE:
                raise ValueError("Review app identity leaked into a nested bundle")
    if APP not in binaries:
        raise ValueError("The built native app executable is missing")
    if binaries[APP]["fileType"] != 2 or not (files[APP]["mode"] & stat.S_IXUSR):
        raise ValueError("The main app payload must be an owner-executable MH_EXECUTE file")
    main = binaries[APP]["buildVersion"]
    if main["minimumOS"] != "17.0.0" or int(main["sdk"].split(".")[0]) < 26:
        raise ValueError("The main executable requires the current iOS SDK and supported deployment target")
    return info, binaries


def package_product(app, output, files, check):
    output.mkdir(mode=0o700, exist_ok=False)
    partial = output / "StickDeathInfinity-review-unsigned-iphoneos.zip.partial"
    with partial.open("xb") as sink:
        with zipfile.ZipFile(sink, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=3) as archive:
            for name, entry in sorted(files.items()):
                check()
                path = app / name
                zi = zipfile.ZipInfo(app.name + "/" + name)
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = (stat.S_IFREG | entry["mode"]) << 16
                digest = hashlib.sha256()
                count = 0
                with path.open("rb") as source, archive.open(zi, "w") as member:
                    while block := source.read(64 * 1024):
                        check()
                        count += len(block)
                        if count > entry["bytes"]:
                            raise ValueError("Built file grew during packaging")
                        digest.update(block)
                        member.write(block)
                if count != entry["bytes"] or digest.hexdigest() != entry["sha256"]:
                    raise ValueError("Packaged source bytes changed")
                if sink.tell() > MAX_APP_BYTES:
                    raise ValueError("Compressed archive exceeds its byte budget")
        sink.flush()
        os.fsync(sink.fileno())
    if partial.stat().st_size > MAX_APP_BYTES:
        raise ValueError("Completed archive exceeds its byte budget")
    with zipfile.ZipFile(partial) as archive:
        members = archive.infolist()
        expected = {app.name + "/" + name: entry for name, entry in files.items()}
        if len(members) != len(expected) or {x.filename for x in members} != set(expected):
            raise ValueError("Unexpected or duplicate archive member")
        for member in members:
            check()
            entry = expected[member.filename]
            if member.file_size != entry["bytes"] or member.flag_bits & 1:
                raise ValueError("Invalid archive size or encryption")
            digest = hashlib.sha256()
            read_bytes = 0
            with archive.open(member) as source:
                while block := source.read(64 * 1024):
                    check()
                    read_bytes += len(block)
                    if read_bytes > entry["bytes"]:
                        raise ValueError("Archive member exceeds its declared byte count")
                    digest.update(block)
            if read_bytes != entry["bytes"] or digest.hexdigest() != entry["sha256"]:
                raise ValueError("Archive readback differs from the actual app")
    if app_inventory(app, check) != files:
        raise ValueError("Built application changed during archive verification")
    final = output / "StickDeathInfinity-review-unsigned-iphoneos.zip"
    os.link(partial, final, follow_symlinks=False)
    partial.unlink()
    return {"file": final.name, "bytes": final.stat().st_size, "sha256": sha_file(final)}


def package_pins(root, scratch, env):
    lock = root / "StickDeathInfinity.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    data = read_regular(lock, 1024 ** 2)
    resolved = json.loads(data)
    pins = resolved.get("pins")
    checkouts = scratch / "Packages/checkouts"
    if not isinstance(pins, list) or not pins or len(pins) > 32 or not checkouts.is_dir():
        raise ValueError("Locked dependency checkouts are required")
    found = {}
    for pin in pins:
        name = pin["identity"]
        if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,127}", name) or name in found:
            raise ValueError("Invalid or duplicate locked package identity")
        checkout = checkouts / name
        if checkout.is_symlink() or not checkout.is_dir():
            raise ValueError("Exact locked dependency checkout is missing")
        actual = command(["git", "-C", str(checkout), "rev-parse", "HEAD"], cwd=root, env=env).decode().strip()
        if require_sha(actual) != require_sha(pin["state"]["revision"]):
            raise ValueError("Dependency checkout differs from Package.resolved")
        if command(["git", "-C", str(checkout), "status", "--porcelain=v1", "--untracked-files=all"], cwd=root, env=env):
            raise ValueError("Dependency checkout changed during compilation")
        found[name] = {"revision": actual, "version": pin["state"].get("version")}
    if {p.name for p in checkouts.iterdir() if p.is_dir()} != set(found):
        raise ValueError("Unexpected dependency checkout outside the locked closure")
    return {"lockfileSHA256": hashlib.sha256(data).hexdigest(), "pins": found}


def main():
    # This guard precedes even output-directory creation when run outside CI.
    global WORK_DEADLINE
    environment = dict(os.environ)
    if any(environment.get(key) != value for key, value in
           {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS"}.items()):
        raise ValueError("This helper is restricted to the existing hosted Mac CI environment")
    WORK_DEADLINE = time.monotonic() + OVERALL_SECONDS
    expected = None
    root = Path(__file__).resolve().parents[2]
    runner = Path(environment["RUNNER_TEMP"]).resolve(strict=True)
    if not runner.is_dir() or runner == root or runner in root.parents:
        raise ValueError("A distinct existing runner scratch directory is required")
    evidence = runner / "sdi-device-review-evidence"
    evidence.mkdir(mode=0o700, exist_ok=False)
    receipt = {"schema": "sdi-unsigned-device-review-build-v1", "deliveryMode": "unsigned_review",
               "status": "running", "stage": "preflight",
               "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "action": "unsigned isolated arm64 iOS-device Review build and bounded package",
               "signingVerified": False, "runtimeVerified": False, "deviceInstallationVerified": False}
    scratch = runner / "sdi-device-review-build"
    output = runner / "sdi-device-review-package"
    guard = Guard(runner, scratch)
    before = None
    env = dict(environment)
    try:
        write_json(evidence / "receipt.json", receipt)
        expected = require_ci(environment)
        receipt["sourceCommit"] = expected
        require_unconfigured({}, env)
        if scratch.exists() or output.exists():
            raise ValueError("Preserve existing device-review scratch or package outputs")
        scratch.mkdir(mode=0o700)
        (scratch / "Tmp").mkdir(mode=0o700)
        env["TMPDIR"] = str(scratch / "Tmp") + "/"
        env["CLANG_MODULE_CACHE_PATH"] = str(scratch / "ModuleCache")
        guard.check(initial=True)
        before = source_snapshot(root, env, expected)
        write_json(evidence / "input-sha256.json", before)
        receipt.update(sourceTree=before["sourceTree"], trackedInputCount=before["trackedCount"], stage="toolchain")
        choices = []
        for app in Path("/Applications").glob("Xcode_26*.app"):
            info = plistlib.loads(read_regular(app / "Contents/Info.plist", 1024 ** 2))
            version = info.get("CFBundleShortVersionString", "")
            if re.fullmatch(r"26(?:\.[0-9]+){0,2}", version):
                choices.append((tuple(int(x) for x in version.split(".")), app))
        if not choices:
            raise ValueError("The existing macos-15 runner must provide an Xcode 26 toolchain")
        env["DEVELOPER_DIR"] = str(max(choices, key=lambda item: item[0])[1] / "Contents/Developer")
        toolchain = command(["xcodebuild", "-version"], cwd=root, env=env, maximum=64 * 1024).decode().strip()
        if not re.fullmatch(r"Xcode 26(?:\.[0-9]+){0,2}\nBuild version [A-Za-z0-9]+", toolchain):
            raise ValueError("Selected toolchain does not match Xcode 26 policy")
        sdk = command(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], cwd=root, env=env,
                      maximum=64 * 1024).decode().strip()
        if not re.fullmatch(r"26(?:\.[0-9]+){0,2}", sdk):
            raise ValueError("Selected toolchain must provide the iOS 26 device SDK")
        receipt.update(toolchain=toolchain, sdk=sdk, developerDirectory=env["DEVELOPER_DIR"])
        info_path = root / "StickDeathInfinity/Info.plist"
        original_info = plistlib.loads(read_regular(info_path, 1024 ** 2))
        review_info, overrides = review_metadata(original_info, expected, before["sourceTree"],
                                                env["GITHUB_RUN_NUMBER"], env["GITHUB_RUN_ID"], env["GITHUB_RUN_ATTEMPT"])
        metadata = scratch / "ReviewInfo.plist"
        metadata.write_bytes(plistlib.dumps(review_info, fmt=plistlib.FMT_XML, sort_keys=False))
        write_json(evidence / "metadata-input.json", {"sourceInfoSHA256": sha_file(info_path),
                   "generatedInfoSHA256": sha_file(metadata), "declaredOverrides": overrides})
        args = build_arguments(scratch, metadata)
        write_json(evidence / "argv.json", args)
        receipt["stage"] = "compile"
        receipt["compileAttempts"] = 1
        write_json(evidence / "receipt.json", receipt)
        built = compile_once(args, root, env, evidence / "xcodebuild.log", guard)
        write_json(evidence / "build-result.json", built)
        receipt["build"] = built
        if built["status"] != "passed":
            raise RuntimeError("The sole unsigned device build did not complete successfully")
        after = source_snapshot(root, env, expected)
        if after != before:
            raise ValueError("Tracked compilation inputs changed during the build")
        dependencies = package_pins(root, scratch, env)
        write_json(evidence / "package-pins.json", dependencies)
        app = scratch / f"DerivedData/Build/Products/Debug-iphoneos/{APP}.app"
        if app.resolve(strict=True) != app:
            raise ValueError("Built product escaped owned scratch")
        receipt["stage"] = "validate-and-package"
        deadline = time.monotonic() + PACKAGE_SECONDS
        def check():
            if time.monotonic() >= deadline:
                raise TimeoutError("Device review validation and packaging exceeded its shared deadline")
            guard.check()
        raw_files = app_inventory(app, check)
        write_json(evidence / "raw-product-manifest.json", raw_files)
        corrections = correct_resource_identity(app, evidence)
        files = app_inventory(app, check)
        changed = {name for name in set(raw_files) | set(files) if raw_files.get(name) != files.get(name)}
        if changed != ({RESOURCE_INFO} if corrections else set()):
            raise ValueError("Unexpected post-build payload change")
        info, binaries = validate_product(app, review_info, files, check)
        archive = package_product(app, output, files, check)
        if source_snapshot(root, env, expected) != before or package_pins(root, scratch, env) != dependencies:
            raise ValueError("Source or locked dependencies changed during packaging")
        manifest = {"schema": "sdi-unsigned-device-review-package-v1", "deliveryMode": "unsigned_review", "sourceCommit": expected,
                    "sourceTree": before["sourceTree"], "appBundleIdentifier": BUNDLE,
                    "displayName": "SDI Review", "bundleVersion": info["CFBundleVersion"],
                    "platform": "iOS device", "architectures": ["arm64"], "unsigned": True,
                    "embeddedProvisioningProfiles": 0, "nativeBinaries": binaries, "files": files,
                    "fileCount": len(files), "uncompressedBytes": sum(x["bytes"] for x in files.values()),
                    "archive": archive, "declaredPostBuildMetadataChanges": corrections,
                    "offlineSettingsVerified": list(OFFLINE_SETTINGS),
                    "scope": "Unsigned isolated offline Review artifact; requires local developer signing; no runtime acceptance"}
        write_json(output / "manifest.json", manifest)
        receipt.update(status="passed", stage="complete", nativeInputsPostflightMatched=True,
                       dependencyPinsPostflightMatched=True, unsignedPayloadVerified=True,
                       archive=archive, postBuildMetadataChanges=corrections)
        receipt["completedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        receipt["minimumScratchFreeBytes"] = guard.minimum
        write_json(evidence / "receipt.json", receipt)
        provenance = {"schema": "sdi-unsigned-device-review-provenance-v1", "deliveryMode": "unsigned_review", "sourceCommit": expected,
                      "sourceTree": before["sourceTree"], "workflowCommit": env["GITHUB_WORKFLOW_SHA"],
                      "runID": env["GITHUB_RUN_ID"], "runAttempt": env["GITHUB_RUN_ATTEMPT"],
                      "toolchain": toolchain, "sdk": sdk, "archiveSHA256": archive["sha256"],
                      "manifestSHA256": sha_file(output / "manifest.json"),
                      "evidenceSHA256": {name: sha_file(evidence / name) for name in
                          ("receipt.json", "argv.json", "input-sha256.json", "package-pins.json", "metadata-input.json",
                           "build-result.json", "raw-product-manifest.json", "xcodebuild.log")}}
        write_json(output / "compile-provenance.json", provenance)
        check()
        command_output = Path(env["GITHUB_OUTPUT"])
        if command_output.is_symlink() or not command_output.is_file():
            raise ValueError("The existing step output command file is required")
        with command_output.open("a") as stream:
            stream.write("review_app_ready=true\n")
        print(json.dumps({"unsignedDeviceReview": {"status": "passed", "sourceCommit": expected,
                         "sourceTree": before["sourceTree"], "archive": archive, "runtimeVerified": False}}), flush=True)
        return 0
    except Exception as error:
        receipt.update(status="failed", reasonType=type(error).__name__,
                       reason=str(error)[:2048],
                       completedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       minimumScratchFreeBytes=guard.minimum)
        # Metadata commands have fixed argv and contain no credentials. Retain
        # bounded raw failures, while the full build log remains independently.
        if isinstance(error, subprocess.CalledProcessError):
            receipt["metadataCommandExitCode"] = error.returncode
            receipt["metadataCommandBudgetFailure"] = getattr(error, "budget_reason", None)
            for name, data in (("stdout", error.stdout), ("stderr", error.stderr)):
                if isinstance(data, bytes):
                    (evidence / ("failed-metadata." + name)).write_bytes(data[:64 * 1024])
        if before is not None:
            try:
                receipt["nativeInputsPostflightMatched"] = source_snapshot(root, env, expected) == before
            except Exception as postflight:
                receipt["nativeInputsPostflightMatched"] = False
                receipt["postflightReasonType"] = type(postflight).__name__
        write_json(evidence / "receipt.json", receipt)
        print(json.dumps({"unsignedDeviceReview": {key: receipt.get(key) for key in
                         ("status", "stage", "reasonType", "sourceCommit", "nativeInputsPostflightMatched")}}), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

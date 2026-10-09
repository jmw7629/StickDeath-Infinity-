#!/usr/bin/env python3
"""Preserve the real, unconfigured universal simulator app after Xcode builds it.

This archive is a native review input, not evidence that it runs on another Mac.
No runtime, signing identity, backend configuration or existing simulator changes.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import time
import zipfile

SETTINGS = ("SPATTER_BACKEND_URL", "SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY",
            "SUPABASE_ANON_KEY", "LIVEKIT_WS_URL")
MAXIMUM_BYTES = 512 * 1024 * 1024
MAXIMUM_FILES = 10_000


def identity(path: Path) -> tuple:
    s = path.lstat()
    return (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns)


def inventory(app: Path) -> dict[str, tuple]:
    if app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        raise ValueError("Use a real simulator app directory, not a link")
    found = {".": identity(app)}
    total = count = 0
    for directory, folders, files in os.walk(app, followlinks=False):
        for name in sorted(folders + files):
            path = Path(directory) / name
            entry = identity(path)
            mode = entry[2]
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)) or "\\" in name:
                raise ValueError("App contains a linked or unsupported file")
            relative = path.relative_to(app).as_posix()
            if relative == "embedded.mobileprovision":
                raise ValueError("A device provisioning profile cannot enter this simulator archive")
            found[relative] = entry
            if stat.S_ISREG(mode):
                count += 1
                total += entry[3]
            if count > MAXIMUM_FILES or total > MAXIMUM_BYTES or len(found) > MAXIMUM_FILES * 2:
                raise ValueError("Simulator app exceeds the review archive budget")
    return found


def package(app: Path, output: Path, commit: str) -> dict:
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Exact source commit required")
    deadline = time.monotonic() + 120
    def check_deadline():
        if time.monotonic() >= deadline:
            raise TimeoutError("Native review packaging exceeded its two-minute budget")
    def inspect(command):
        check_deadline()
        return subprocess.check_output(command, timeout=min(30, max(0.01, deadline - time.monotonic())))
    check_deadline()
    app = app.absolute()
    before = inventory(app)
    info_path = app / "Info.plist"
    if not info_path.is_file() or info_path.stat().st_size > 1024 * 1024:
        raise ValueError("Missing or oversized built Info.plist")
    info = plistlib.loads(info_path.read_bytes())
    if info.get("CFBundleIdentifier") != "com.willisnmb.stickdeathinfinity":
        raise ValueError("Unexpected app identity")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
        raise ValueError("Only simulator builds can be preserved here")
    if any(str(info.get(key, "")).strip() for key in SETTINGS):
        raise ValueError("Review app must have empty public backend settings")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise ValueError("Invalid app executable")
    binary = app / executable
    if executable not in before or not stat.S_ISREG(before[executable][2]):
        raise ValueError("Built app executable is missing")
    # Xcode Debug builds can put real application code in a separate dylib.
    # Validate every Mach-O slice, not only the small launcher executable.
    mach_o_magic = {bytes.fromhex(value) for value in ["feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"]}
    binaries = []
    for name, entry in before.items():
        check_deadline()
        if stat.S_ISREG(entry[2]):
            with (app / name).open("rb") as file:
                if file.read(4) in mach_o_magic:
                    binaries.append(name)
    if executable not in binaries:
        raise ValueError("App executable is not a native Mach-O binary")
    binary_versions = {}
    for name in binaries:
        binary = app / name
        archs = inspect(["xcrun", "lipo", "-archs", str(binary)]).decode().split()
        if not {"x86_64", "arm64"}.issubset(archs):
            raise ValueError("Every preserved native binary needs Intel and Apple-silicon simulator slices")
        versions = {}
        for arch in ["x86_64", "arm64"]:
            text = inspect(["xcrun", "vtool", "-arch", arch, "-show-build", str(binary)]).decode()
            if not re.search(r"platform\s+IOSSIMULATOR\b", text):
                raise ValueError("Native executable slice is not built for the iOS simulator")
            minimum = re.search(r"minos\s+([0-9.]+)", text)
            sdk = re.search(r"sdk\s+([0-9.]+)", text)
            if not minimum or not sdk:
                raise ValueError("Missing simulator minimum OS or SDK evidence")
            versions[arch] = {"minimumOS": minimum.group(1), "sdk": sdk.group(1)}
        binary_versions[name] = {"architectures": sorted(archs), "buildVersions": versions}
    archs = binary_versions[executable]["architectures"]
    build_versions = binary_versions[executable]["buildVersions"]
    check_deadline()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    partial = output / "StickDeathInfinity-simulator.zip.partial"
    opened_identity = None
    hashes = {}
    try:
        with partial.open("xb") as archive:
            opened_identity = (os.fstat(archive.fileno()).st_dev, os.fstat(archive.fileno()).st_ino)
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=3) as zipped:
                for name, entry in sorted(before.items()):
                    check_deadline()
                    if not stat.S_ISREG(entry[2]):
                        continue
                    path = app / name
                    if identity(path) != entry:
                        raise ValueError("Built app changed before packaging")
                    digest = hashlib.sha256()
                    zi = zipfile.ZipInfo(app.name + "/" + name)
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    zi.external_attr = (stat.S_IFREG | (entry[2] & 0o777)) << 16
                    with path.open("rb") as source, zipped.open(zi, "w") as destination:
                        if (os.fstat(source.fileno()).st_dev, os.fstat(source.fileno()).st_ino) != entry[:2]:
                            raise ValueError("Built app file changed while opening")
                        copied = 0
                        while chunk := source.read(64 * 1024):
                            check_deadline()
                            copied += len(chunk)
                            if copied > entry[3]:
                                raise ValueError("Built app grew during packaging")
                            digest.update(chunk)
                            destination.write(chunk)
                        if copied != entry[3]:
                            raise ValueError("Built app shrank during packaging")
                    hashes[name] = digest.hexdigest()
                    if identity(path) != entry:
                        raise ValueError("Built app file changed during packaging")
            archive.flush()
            os.fsync(archive.fileno())
        if inventory(app) != before:
            raise ValueError("Built app inventory changed during packaging")
        if partial.stat().st_size > MAXIMUM_BYTES:
            raise ValueError("Compressed app exceeds archive budget")
        with zipfile.ZipFile(partial) as archive:
            if archive.testzip() is not None:
                raise ValueError("Native review archive CRC validation failed")
            for item in archive.infolist():
                check_deadline()
                name = item.filename.removeprefix(app.name + "/")
                with archive.open(item) as source:
                    digest = hashlib.sha256()
                    while chunk := source.read(64 * 1024):
                        digest.update(chunk)
                if name not in hashes or digest.hexdigest() != hashes[name]:
                    raise ValueError("Archived file does not match the actual built app")
        check_deadline()
        final = output / "StickDeathInfinity-simulator.zip"
        # Exclusive publication: never replace a file that another operation owns.
        os.link(partial, final, follow_symlinks=False)
        partial.unlink()
        digest = hashlib.sha256()
        with final.open("rb") as file:
            while chunk := file.read(64 * 1024):
                digest.update(chunk)
        receipt = {"sourceCommit": commit, "appBundleIdentifier": info["CFBundleIdentifier"],
                   "architectures": sorted(archs), "buildVersions": build_versions, "nativeBinaries": binary_versions,
                   "emptyPublicSettings": list(SETTINGS), "fileHashes": hashes,
                   "archiveSHA256": digest.hexdigest(), "archiveBytes": final.stat().st_size,
                   "fileCount": len(hashes), "uncompressedBytes": sum(e[3] for e in before.values() if stat.S_ISREG(e[2])),
                   "appWasModified": False, "localMacRuntimeVerified": False,
                   "scope": "CI-built simulator app for isolated native review; not a device or TestFlight build"}
        with (output / "manifest.json").open("x") as manifest:
            manifest.write(json.dumps(receipt, indent=2) + "\n")
        return receipt
    except Exception:
        if opened_identity and partial.exists() and identity(partial)[:2] == opened_identity:
            partial.unlink()
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    arguments = parser.parse_args()
    result = package(arguments.app, arguments.output, arguments.commit)
    print(json.dumps({key: value for key, value in result.items() if key != "fileHashes"}))

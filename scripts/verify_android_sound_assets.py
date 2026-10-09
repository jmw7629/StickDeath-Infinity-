#!/usr/bin/env python3
"""Inspect the built APK, not merely the source catalogue or Gradle declaration."""
import hashlib
import json
from pathlib import Path
import sys
import zipfile


def verify(apk):
    root = Path(__file__).resolve().parents[1] / "StickDeathInfinity/Resources/StudioSounds"
    catalogue_bytes = (root / "catalogue.json").read_bytes()
    catalogue = json.loads(catalogue_bytes)
    if catalogue.get("schemaVersion") != 1 or len(catalogue.get("sounds", [])) != 2127:
        raise ValueError("Unexpected source catalogue; review the library contract before packaging")
    total = 0
    seen = set()
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("APK contains duplicate entry names")
        for filename, expected in (("catalogue.json", catalogue_bytes), ("CREDITS.txt", (root / "CREDITS.txt").read_bytes())):
            entry = archive.getinfo("assets/" + filename)
            if entry.file_size != len(expected) or archive.read(entry) != expected:
                raise ValueError(f"Packaged {filename} differs from the licensed source")
        for sound in catalogue["sounds"]:
            filename = sound["filename"]
            if filename in seen or filename not in (sound["sha256"] + ".wav", sound["sha256"] + ".m4a"):
                raise ValueError("Unsafe or duplicate catalogue asset path")
            seen.add(filename)
            if sound["license"] != "CC0-1.0" or not 0 < sound["byteCount"] <= 4 * 1024 * 1024:
                raise ValueError(f"Invalid license or size: {filename}")
            entry = archive.getinfo("assets/" + filename)
            if entry.file_size != sound["byteCount"] or entry.compress_type != zipfile.ZIP_STORED:
                raise ValueError(f"Sound must be intact and uncompressed for asset descriptors: {filename}")
            if hashlib.sha256(archive.read(entry)).hexdigest() != sound["sha256"]:
                raise ValueError(f"Packaged sound hash mismatch: {filename}")
            total += entry.file_size
        packaged = {n.removeprefix("assets/") for n in names if n.startswith("assets/") and n.endswith((".wav", ".m4a"))}
        if packaged != seen:
            raise ValueError("APK audio assets differ from the catalogue")
    return {"artifact": str(apk), "soundCount": len(seen), "soundBytes": total,
            "catalogueSHA256": hashlib.sha256(catalogue_bytes).hexdigest(), "result": "PASS"}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: verify_android_sound_assets.py app-debug.apk")
    print(json.dumps(verify(Path(sys.argv[1])), indent=2))

#!/usr/bin/env python3
"""Verify the bundled Studio sound catalogue's provenance and deduplication (#191).

Runs on Linux without Apple frameworks. For every sound in
StickDeathInfinity/Resources/StudioSounds/catalogue.json it checks:

  * the shipped file exists, is a regular file of the declared size, and its
    SHA-256 equals both `sha256` and the filename stem (the catalogue identity);
  * `id == sha256`, `originalSHA256` is a 64-hex digest distinct per sound, and
    no two sounds share shipped bytes or publisher originals (deduplication);
  * the licence is CC0-1.0 with the canonical URL and the source URL is an
    https link to one of the two verified publishers (kenney.nl, opengameart.org);
  * labels are bounded, waveform peaks (and optional RMS) are 256 finite values
    in 0...1 with RMS never above the peak;
  * no file in the directory is unaccounted for (apart from the manifest and
    licence text files), so no unlisted binary ships;
  * optional bundled pack metadata is admitted only with the exact compiled
    descriptor pin and two exact pinned, fully validated metadata catalogues.

Metadata never stands in for audio verification. Passing an actual optional
pack directory uses the same complete audio-file checks as the bundled library.

The script prints a per-category/per-author/per-source summary and exits
non-zero on the first inconsistency. It never modifies files.
"""
from __future__ import annotations

import collections
import hashlib
import json
import math
import os
import re
import stat
import sys
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DIRECTORY = ROOT / "StickDeathInfinity/Resources/StudioSounds"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
ALLOWED_HOSTS = {"kenney.nl", "opengameart.org"}
ALLOWED_EXTENSIONS = {"wav", "aiff", "aifc", "caf", "m4a", "mp3", "aac"}
LICENSE = "CC0-1.0"
LICENSE_URL = "https://creativecommons.org/publicdomain/zero/1.0/"
MAX_BYTES = 16 * 1024 * 1024
BIN_COUNT = 256
MAX_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_PACK_MANIFEST_BYTES = 512 * 1024
DESCRIPTOR_SHA256 = "e5a58b24d84d1112481f54676f55b2cdb48ecc8929bb32e691dd1ea823bbbf66"
PACK_MANIFESTS = {
    "ambience-nature-cc0-v1": "004d60b4b1bad48497df729d20096d1e7123888c26414a681f7f9123d41e1d34",
    "comedy-cartoon-cc0-v1": "27b3c71240c5c5dae86b3a49728d455e63d1bde50c923da9559b976d8337a033",
}


class ProvenanceError(Exception):
    pass


def directory_identity(path: Path) -> tuple[int, int]:
    before = path.lstat()
    if not stat.S_ISDIR(before.st_mode):
        raise ProvenanceError(f"not a regular directory (links refused): {path}")
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        opened = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise ProvenanceError(f"directory changed while opening: {path}")
        return opened.st_dev, opened.st_ino
    finally:
        os.close(descriptor)


def check_directory(path: Path, identity: tuple[int, int]) -> None:
    if directory_identity(path) != identity:
        raise ProvenanceError(f"directory changed during verification: {path}")


def read_regular(path: Path, limit: int) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or not 1 <= before.st_size <= limit:
            raise ProvenanceError(f"not a bounded regular file: {path}")
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(descriptor, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(descriptor)
        if len(data) != before.st_size or len(data) > limit or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ProvenanceError(f"file changed during verification: {path}")
        return bytes(data)
    finally:
        os.close(descriptor)


def decode_json(data: bytes) -> object:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ProvenanceError(f"duplicate JSON key: {key}")
            result[key] = value
        return result
    return json.loads(data.decode("utf-8"), object_pairs_hook=unique)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def label_ok(text: object, limit: int = 120) -> bool:
    return isinstance(text, str) and 0 < len(text) <= limit and not any(ord(c) < 32 or ord(c) == 127 for c in text)


def bins_ok(values: object) -> bool:
    return (isinstance(values, list) and len(values) == BIN_COUNT
            and all(isinstance(v, (int, float)) and math.isfinite(v) and 0 <= v <= 1 for v in values))


def _verify_sounds(directory: Path, manifest: dict, *, check_audio_files: bool) -> dict:
    """One rights/schema validator; metadata-only callers must pin bytes first."""
    if not isinstance(manifest, dict):
        raise ProvenanceError("manifest must be an object")
    if manifest.get("schemaVersion") != 1:
        raise ProvenanceError("unsupported schemaVersion")
    sounds = manifest.get("sounds")
    if not isinstance(sounds, list) or not 1 <= len(sounds) <= 5000:
        raise ProvenanceError("sounds must be a non-empty list of at most 5000 entries")

    seen_ids, seen_files, seen_originals = set(), set(), set()
    categories = collections.Counter()
    authors = collections.Counter()
    sources = collections.Counter()
    total_bytes = 0
    with_rms = 0
    for index, sound in enumerate(sounds):
        if not isinstance(sound, dict):
            raise ProvenanceError(f"sound[{index}] must be an object")
        where = f"sound[{index}] {sound.get('id', '?')[:12]}"
        for key in ("id", "title", "category", "author", "sourceURL", "license", "licenseURL",
                    "originalSHA256", "filename", "sha256", "byteCount", "duration", "sampleRate", "channels", "waveformPeaks"):
            if key not in sound:
                raise ProvenanceError(f"{where}: missing {key}")
        digest, original = sound["sha256"], sound["originalSHA256"]
        if not (isinstance(digest, str) and isinstance(original, str) and HEX64.match(digest) and HEX64.match(original)):
            raise ProvenanceError(f"{where}: digests must be 64 lowercase hex characters")
        if sound["id"] != digest:
            raise ProvenanceError(f"{where}: id must equal sha256")
        if digest in seen_ids:
            raise ProvenanceError(f"{where}: duplicate shipped bytes {digest}")
        if original in seen_originals:
            raise ProvenanceError(f"{where}: duplicate publisher original {original}")
        seen_ids.add(digest); seen_originals.add(original)
        filename = sound["filename"]
        if not isinstance(filename, str):
            raise ProvenanceError(f"{where}: filename must be text")
        stem, _, extension = filename.rpartition(".")
        if stem != digest or extension not in ALLOWED_EXTENSIONS or "/" in filename:
            raise ProvenanceError(f"{where}: filename must be <sha256>.<ext>, got {filename}")
        if check_audio_files:
            path = directory / filename
            if path.is_symlink() or not path.is_file():
                raise ProvenanceError(f"{where}: shipped file missing or not a regular file: {filename}")
            size = path.stat().st_size
            if size != sound["byteCount"] or not 1 <= size <= MAX_BYTES:
                raise ProvenanceError(f"{where}: byteCount {sound['byteCount']} does not match file size {size}")
            if sha256_of(path) != digest:
                raise ProvenanceError(f"{where}: file digest mismatch for {filename}")
        else:
            # Only the exact release-pinned metadata path uses this branch.
            # General verify()/CLI calls always require the actual audio bytes.
            size = sound["byteCount"]
            if type(size) is not int or not 1 <= size <= MAX_BYTES:
                raise ProvenanceError(f"{where}: byteCount out of range")
        seen_files.add(filename)
        total_bytes += size
        if not (label_ok(sound["title"]) and label_ok(sound["category"]) and label_ok(sound["author"])):
            raise ProvenanceError(f"{where}: invalid title/category/author label")
        if sound["license"] != LICENSE or sound["licenseURL"] != LICENSE_URL:
            raise ProvenanceError(f"{where}: licence must be {LICENSE} with the canonical URL")
        parts = urlsplit(sound["sourceURL"])
        if parts.scheme != "https" or parts.hostname not in ALLOWED_HOSTS or parts.username or parts.password:
            raise ProvenanceError(f"{where}: sourceURL must be https on an allowed publisher host: {sound['sourceURL']}")
        duration, rate, channels = sound["duration"], sound["sampleRate"], sound["channels"]
        if not (isinstance(duration, (int, float)) and math.isfinite(duration) and 0 < duration <= 300):
            raise ProvenanceError(f"{where}: duration out of range")
        if not (isinstance(rate, (int, float)) and 8000 <= rate <= 192000) or channels not in (1, 2):
            raise ProvenanceError(f"{where}: sample rate or channel count out of range")
        peaks = sound["waveformPeaks"]
        if not bins_ok(peaks) or not any(v > 0 for v in peaks):
            raise ProvenanceError(f"{where}: waveformPeaks must be 256 finite values in 0...1 with some signal")
        rms = sound.get("waveformRMS")
        if rms is not None:
            if not bins_ok(rms) or any(r > p + 1e-6 for r, p in zip(rms, peaks)):
                raise ProvenanceError(f"{where}: waveformRMS must be 256 values in 0...1 never above the peak")
            with_rms += 1
        tags = sound.get("tags")
        if tags is not None:
            if (not isinstance(tags, list) or len(tags) > 16 or len(set(tags)) != len(tags)
                    or not all(re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", t) and len(t) <= 32 for t in tags)):
                raise ProvenanceError(f"{where}: invalid tags")
        categories[sound["category"]] += 1
        authors[sound["author"]] += 1
        sources[parts.hostname] += 1

    return {
        "sounds": len(sounds), "distinctShipped": len(seen_ids), "distinctOriginals": len(seen_originals),
        "bytes": total_bytes, "withRMS": with_rms, "categories": dict(categories),
        "authors": dict(authors), "sourceHosts": dict(sources),
    }


def _verify_optional_metadata(directory: Path, bundled: dict) -> list[dict]:
    descriptor_path = directory / "sound-packs.json"
    if not os.path.lexists(descriptor_path):
        return []
    root_identity = directory_identity(directory)
    data = read_regular(descriptor_path, 32 * 1024)
    if hashlib.sha256(data).hexdigest() != DESCRIPTOR_SHA256:
        raise ProvenanceError("optional sound descriptor pin mismatch")
    descriptors = decode_json(data)
    if (not isinstance(descriptors, list) or len(descriptors) != 2
            or {item.get("id") for item in descriptors if isinstance(item, dict)} != set(PACK_MANIFESTS)):
        raise ProvenanceError("optional sound descriptors do not name the exact two released packs")
    metadata_root = directory / "pack-catalogues"
    metadata_identity = directory_identity(metadata_root)
    if {path.name for path in metadata_root.iterdir()} != set(PACK_MANIFESTS):
        raise ProvenanceError("unexpected or missing optional metadata pack directory")
    shipped = {sound["sha256"] for sound in bundled["sounds"]}
    originals = {sound["originalSHA256"] for sound in bundled["sounds"]}
    result = []
    for descriptor in descriptors:
        pack_id = descriptor["id"]
        expected_base = f"https://raw.githubusercontent.com/jmw7629/StickDeath-Infinity-/sdi-sound-packs-v1/assets/sound-packs/{pack_id}/"
        if (not label_ok(descriptor["title"]) or descriptor["baseURL"] != expected_base
                or descriptor["manifestURL"] != expected_base + "catalogue.json"
                or descriptor["manifestSHA256"] != PACK_MANIFESTS[pack_id]
                or type(descriptor["manifestBytes"]) is not int or not 1 <= descriptor["manifestBytes"] <= MAX_PACK_MANIFEST_BYTES
                or type(descriptor["soundCount"]) is not int or not 1 <= descriptor["soundCount"] <= 128
                or type(descriptor["totalAudioBytes"]) is not int or not 1 <= descriptor["totalAudioBytes"] <= 64 * 1024 * 1024):
            raise ProvenanceError(f"{pack_id}: invalid pinned descriptor")
        check_directory(directory, root_identity); check_directory(metadata_root, metadata_identity)
        pack_directory = metadata_root / pack_id
        pack_identity = directory_identity(pack_directory)
        if {path.name for path in pack_directory.iterdir()} != {"catalogue.json"}:
            raise ProvenanceError(f"{pack_id}: unlisted optional metadata file")
        manifest_data = read_regular(pack_directory / "catalogue.json", MAX_PACK_MANIFEST_BYTES)
        if (len(manifest_data) != descriptor["manifestBytes"]
                or hashlib.sha256(manifest_data).hexdigest() != descriptor["manifestSHA256"]):
            raise ProvenanceError(f"{pack_id}: optional metadata manifest pin mismatch")
        manifest = decode_json(manifest_data)
        summary = _verify_sounds(pack_directory, manifest, check_audio_files=False)
        if summary["sounds"] != descriptor["soundCount"] or summary["bytes"] != descriptor["totalAudioBytes"]:
            raise ProvenanceError(f"{pack_id}: optional metadata count or audio-byte total mismatch")
        for sound in manifest["sounds"]:
            if sound["sha256"] in shipped or sound["originalSHA256"] in originals:
                raise ProvenanceError(f"{pack_id}: duplicate bundled/optional sound or publisher original")
            shipped.add(sound["sha256"]); originals.add(sound["originalSHA256"])
        check_directory(directory, root_identity); check_directory(metadata_root, metadata_identity); check_directory(pack_directory, pack_identity)
        result.append({"id": pack_id, "sounds": summary["sounds"], "audioBytes": summary["bytes"],
                       "manifestSHA256": descriptor["manifestSHA256"], "metadataOnly": True})
    check_directory(directory, root_identity); check_directory(metadata_root, metadata_identity)
    return result


def verify(directory: Path) -> dict:
    root_identity = directory_identity(directory)
    manifest_path = directory / "catalogue.json"
    if not manifest_path.is_file():
        raise ProvenanceError(f"missing manifest: {manifest_path}")
    manifest = decode_json(read_regular(manifest_path, MAX_MANIFEST_BYTES))
    summary = _verify_sounds(directory, manifest, check_audio_files=True)
    optional = _verify_optional_metadata(directory, manifest)
    recognized_metadata = {"sound-packs.json", "pack-catalogues"} if optional else set()
    seen_files = {sound["filename"] for sound in manifest["sounds"]}
    unexpected = sorted(p.name for p in directory.iterdir()
                        if p.name not in seen_files and p.name != "catalogue.json" and p.suffix != ".txt" and not p.name.startswith(".")
                        and p.name not in recognized_metadata)
    if unexpected:
        raise ProvenanceError(f"unlisted files in the sound directory: {unexpected[:5]}")
    # Existing licence/hidden-file allowances never authorize directories or
    # links. The one admitted directory was fully checked above.
    for path in directory.iterdir():
        if path.name not in recognized_metadata and (path.is_symlink() or not path.is_file()):
            raise ProvenanceError(f"unlisted or nonregular path in the sound directory: {path.name}")
    check_directory(directory, root_identity)
    if optional:
        summary["optionalPacks"] = optional
        summary["availableDistinctWithOptional"] = summary["sounds"] + sum(pack["sounds"] for pack in optional)
    return summary


def main(argv: list[str]) -> int:
    directory = Path(argv[1]) if len(argv) > 1 else DEFAULT_DIRECTORY
    try:
        summary = verify(directory)
    except (ProvenanceError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"SOUND_CATALOGUE_PROVENANCE=FAIL {error}")
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    print(f"SOUND_CATALOGUE_PROVENANCE=PASS sounds={summary['sounds']} distinct={summary['distinctShipped']} "
          f"originals={summary['distinctOriginals']} bytes={summary['bytes']} withRMS={summary['withRMS']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

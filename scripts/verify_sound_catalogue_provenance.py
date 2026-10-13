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
    licence text files), so no unlisted binary ships.

The script prints a per-category/per-author/per-source summary and exits
non-zero on the first inconsistency. It never modifies files.
"""
from __future__ import annotations

import collections
import hashlib
import json
import math
import re
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


class ProvenanceError(Exception):
    pass


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


def verify(directory: Path) -> dict:
    manifest_path = directory / "catalogue.json"
    if not manifest_path.is_file():
        raise ProvenanceError(f"missing manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
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
        where = f"sound[{index}] {sound.get('id', '?')[:12]}"
        for key in ("id", "title", "category", "author", "sourceURL", "license", "licenseURL",
                    "originalSHA256", "filename", "sha256", "byteCount", "duration", "sampleRate", "channels", "waveformPeaks"):
            if key not in sound:
                raise ProvenanceError(f"{where}: missing {key}")
        digest, original = sound["sha256"], sound["originalSHA256"]
        if not (HEX64.match(digest) and HEX64.match(original)):
            raise ProvenanceError(f"{where}: digests must be 64 lowercase hex characters")
        if sound["id"] != digest:
            raise ProvenanceError(f"{where}: id must equal sha256")
        if digest in seen_ids:
            raise ProvenanceError(f"{where}: duplicate shipped bytes {digest}")
        if original in seen_originals:
            raise ProvenanceError(f"{where}: duplicate publisher original {original}")
        seen_ids.add(digest); seen_originals.add(original)
        filename = sound["filename"]
        stem, _, extension = filename.rpartition(".")
        if stem != digest or extension not in ALLOWED_EXTENSIONS or "/" in filename:
            raise ProvenanceError(f"{where}: filename must be <sha256>.<ext>, got {filename}")
        path = directory / filename
        if path.is_symlink() or not path.is_file():
            raise ProvenanceError(f"{where}: shipped file missing or not a regular file: {filename}")
        size = path.stat().st_size
        if size != sound["byteCount"] or not 1 <= size <= MAX_BYTES:
            raise ProvenanceError(f"{where}: byteCount {sound['byteCount']} does not match file size {size}")
        if sha256_of(path) != digest:
            raise ProvenanceError(f"{where}: file digest mismatch for {filename}")
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

    unexpected = sorted(p.name for p in directory.iterdir()
                        if p.name not in seen_files and p.name != "catalogue.json" and p.suffix != ".txt" and not p.name.startswith("."))
    if unexpected:
        raise ProvenanceError(f"unlisted files in the sound directory: {unexpected[:5]}")
    return {
        "sounds": len(sounds), "distinctShipped": len(seen_ids), "distinctOriginals": len(seen_originals),
        "bytes": total_bytes, "withRMS": with_rms, "categories": dict(categories),
        "authors": dict(authors), "sourceHosts": dict(sources),
    }


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

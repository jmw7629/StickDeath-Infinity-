"""Licensed-asset registry for render intake (#188).

A render may declare the library assets it contains as `asset_credits`
(image and sound SHA-256 digests taken from the export manifest). The registry
loads the shipped catalogues and admits a render only when every declared
digest names a catalogued asset with a recorded licence. It cannot see assets
the client did not declare; the client writes every visible library asset into
the manifest, and the rights summary and owner review remain the authority for
anything else. Unknown digests fail closed.
"""
from __future__ import annotations

import json
import hashlib
import math
import os
from pathlib import Path
import re
import stat
from contextlib import ExitStack
from urllib.parse import urlsplit

from .store import IntakeError

DIGEST = re.compile(r"^[a-f0-9]{64}$")
KINDS = ("image", "sound")
MAX_CREDITS = 200
DEFAULT_ROOT = Path(__file__).resolve().parents[2] / "StickDeathInfinity" / "Resources"
# Application-owned trust anchor, never read from a request or configuration.
# Pinned to the shipped descriptors for permanent owned sdi-sound-packs-v1 assets.
TRUSTED_SOUND_PACK_DESCRIPTORS_SHA256 = "e5a58b24d84d1112481f54676f55b2cdb48ecc8929bb32e691dd1ea823bbbf66"
MAX_SOUND_PACK_DESCRIPTOR_BYTES = 64 * 1024
MAX_SOUND_PACK_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_SOUND_PACKS = 16
MAX_OPTIONAL_SOUNDS = 5000
MAX_OPTIONAL_AUDIO_BYTES = 128 * 1024 * 1024
SOUND_PACK_ID = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def _bounded_regular_file(directory: int, name: str, limit: int) -> bytes:
    """Read one local regular file relative to an already anchored directory."""
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= limit:
            raise ValueError("Invalid trusted sound-pack file.")
        data = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
        if (len(data) != before.st_size or
                (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) !=
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
            raise ValueError("Trusted sound-pack file changed during reading.")
        return data


def _strict_json(data: bytes):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate trusted sound-pack property.")
            result[key] = value
        return result
    return json.loads(data.decode("utf-8"), object_pairs_hook=unique)


def _label(value) -> bool:
    return (isinstance(value, str) and 0 < len(value) <= 120 and
            not any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value))


def _number(value, minimum, maximum) -> bool:
    return (type(value) in (int, float) and minimum <= value <= maximum and math.isfinite(value))


def _optional_sound_valid(sound) -> bool:
    required = {"id", "title", "category", "author", "sourceURL", "license", "licenseURL", "originalSHA256",
                "filename", "sha256", "byteCount", "duration", "sampleRate", "channels", "waveformPeaks"}
    if not isinstance(sound, dict) or not required <= set(sound) <= required | {"tags", "waveformRMS"}:
        return False
    if not all(isinstance(sound[key], str) and DIGEST.fullmatch(sound[key]) for key in ("id", "sha256", "originalSHA256")):
        return False
    if (sound["id"] != sound["sha256"] or sound["filename"] != sound["sha256"] + ".wav" or
            sound["license"] != "CC0-1.0" or sound["licenseURL"] != "https://creativecommons.org/publicdomain/zero/1.0/" or
            not all(_label(sound[key]) for key in ("title", "category", "author")) or
            type(sound["byteCount"]) is not int or not 0 < sound["byteCount"] <= 16 * 1024 * 1024 or
            not _number(sound["duration"], 0, 300) or sound["duration"] == 0 or
            not _number(sound["sampleRate"], 8000, 192000) or type(sound["channels"]) is not int or sound["channels"] not in (1, 2)):
        return False
    source = sound["sourceURL"]
    if not isinstance(source, str) or len(source) > 2048:
        return False
    parsed = urlsplit(source)
    if (parsed.scheme != "https" or parsed.hostname not in ("kenney.nl", "opengameart.org") or
            parsed.username is not None or parsed.password is not None):
        return False
    peaks, rms, tags = sound["waveformPeaks"], sound.get("waveformRMS"), sound.get("tags")
    if (not isinstance(peaks, list) or len(peaks) != 256 or not all(_number(p, 0, 1) for p in peaks) or not any(peaks)):
        return False
    if rms is not None and (not isinstance(rms, list) or len(rms) != 256 or
                            not all(_number(r, 0, 1) and r <= p + 0.000001 for r, p in zip(rms, peaks))):
        return False
    return tags is None or (isinstance(tags, list) and len(tags) <= 16 and
                            all(isinstance(t, str) and len(t) <= 32 and SOUND_PACK_ID.fullmatch(t) for t in tags) and
                            len(set(tags)) == len(tags))


def _trusted_optional_sounds(base: Path) -> list[dict]:
    """Load pinned server-shipped metadata only. Never follow a descriptor URL.

    Descriptor absence retains bundled-only behavior, including custom resource
    roots. A present descriptor or pack that cannot be verified aborts loading;
    it cannot silently weaken the licence authority to client-supplied metadata.
    """
    try:
        (base / "StudioSounds" / "sound-packs.json").lstat()
    except FileNotFoundError:
        return []
    try:
        with ExitStack() as opened:
            def directory(name, parent=None):
                fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                opened.callback(os.close, fd)
                return fd
            root = directory(base)
            sounds_root = directory("StudioSounds", root)
            descriptor_bytes = _bounded_regular_file(sounds_root, "sound-packs.json", MAX_SOUND_PACK_DESCRIPTOR_BYTES)
            if hashlib.sha256(descriptor_bytes).hexdigest() != TRUSTED_SOUND_PACK_DESCRIPTORS_SHA256:
                raise ValueError("Untrusted sound-pack descriptors.")
            descriptors = _strict_json(descriptor_bytes)
            if not isinstance(descriptors, list) or not 0 < len(descriptors) <= MAX_SOUND_PACKS:
                raise ValueError("Invalid sound-pack descriptors.")
            catalogues = directory("pack-catalogues", sounds_root)
            ids, sound_ids, original_ids, combined = set(), set(), set(), []
            manifest_total = audio_total = 0
            fields = {"id", "title", "manifestURL", "manifestBytes", "manifestSHA256", "baseURL", "soundCount", "totalAudioBytes"}
            for descriptor in descriptors:
                if not isinstance(descriptor, dict) or set(descriptor) != fields:
                    raise ValueError("Invalid sound-pack descriptor.")
                pack_id = descriptor["id"]
                if (not isinstance(pack_id, str) or len(pack_id) > 80 or not SOUND_PACK_ID.fullmatch(pack_id) or pack_id in ids or
                        not _label(descriptor["title"]) or
                        type(descriptor["manifestBytes"]) is not int or not 0 < descriptor["manifestBytes"] <= MAX_SOUND_PACK_MANIFEST_BYTES or
                        not isinstance(descriptor["manifestSHA256"], str) or not DIGEST.fullmatch(descriptor["manifestSHA256"]) or
                        type(descriptor["soundCount"]) is not int or not 0 < descriptor["soundCount"] <= MAX_OPTIONAL_SOUNDS or
                        type(descriptor["totalAudioBytes"]) is not int or not 0 < descriptor["totalAudioBytes"] <= MAX_OPTIONAL_AUDIO_BYTES or
                        not all(isinstance(descriptor[k], str) and 0 < len(descriptor[k]) <= 2048 for k in ("manifestURL", "baseURL")) or
                        descriptor["manifestURL"] != descriptor["baseURL"] + "catalogue.json"):
                    raise ValueError("Invalid sound-pack descriptor fields.")
                ids.add(pack_id)
                pack = directory(pack_id, catalogues)
                data = _bounded_regular_file(pack, "catalogue.json", descriptor["manifestBytes"])
                if len(data) != descriptor["manifestBytes"] or hashlib.sha256(data).hexdigest() != descriptor["manifestSHA256"]:
                    raise ValueError("Unverified sound-pack catalogue.")
                manifest_total += len(data)
                if manifest_total > MAX_SOUND_PACK_MANIFEST_BYTES:
                    raise ValueError("Sound-pack metadata limit exceeded.")
                manifest = _strict_json(data)
                if (not isinstance(manifest, dict) or set(manifest) != {"schemaVersion", "sounds"} or
                        type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != 1 or
                        not isinstance(manifest["sounds"], list) or len(manifest["sounds"]) != descriptor["soundCount"]):
                    raise ValueError("Invalid sound-pack catalogue schema.")
                entries = manifest["sounds"]
                for sound in entries:
                    if not _optional_sound_valid(sound) or sound["id"] in sound_ids or sound["originalSHA256"] in original_ids:
                        raise ValueError("Invalid or duplicate trusted optional sound.")
                    sound_ids.add(sound["id"]); original_ids.add(sound["originalSHA256"])
                audio_bytes = sum(sound["byteCount"] for sound in entries)
                if audio_bytes != descriptor["totalAudioBytes"]:
                    raise ValueError("Sound-pack audio total mismatch.")
                audio_total += audio_bytes
                combined.extend(entries)
                if len(combined) > MAX_OPTIONAL_SOUNDS or audio_total > MAX_OPTIONAL_AUDIO_BYTES:
                    raise ValueError("Optional sound-pack limit exceeded.")
            return combined
    except (OSError, ValueError, UnicodeError) as error:
        raise ValueError("Trusted optional sound catalogues could not be verified.") from error


class LicensedAssetRegistry:
    def __init__(self, images: dict, sounds: dict):
        licences = {entry.get("id"): entry for entry in images.get("licenses", []) if isinstance(entry, dict)}
        self.images: dict[str, str] = {}
        for entry in images.get("images", []):
            if not isinstance(entry, dict):
                continue
            licence = licences.get(entry.get("licenseID"))
            if not licence or not isinstance(licence.get("license"), str) or not licence["license"].strip():
                continue  # an image without a recorded licence is never admitted
            for key in ("sha256", "originalSHA256"):
                digest = entry.get(key)
                if isinstance(digest, str) and DIGEST.fullmatch(digest):
                    self.images[digest] = licence["license"]
        self.sounds: dict[str, str] = {}
        for entry in sounds.get("sounds", []):
            if not isinstance(entry, dict) or not isinstance(entry.get("license"), str) or not entry["license"].strip():
                continue
            for key in ("sha256", "originalSHA256"):
                digest = entry.get(key)
                if isinstance(digest, str) and DIGEST.fullmatch(digest):
                    self.sounds[digest] = entry["license"]

    @classmethod
    def from_catalogues(cls, root: Path | None = None) -> "LicensedAssetRegistry":
        base = Path(root or os.environ.get("SDI_ASSET_CATALOGUE_ROOT") or DEFAULT_ROOT)
        images = json.loads((base / "StudioImages" / "catalogue.json").read_text(encoding="utf-8"))
        sounds = json.loads((base / "StudioSounds" / "catalogue.json").read_text(encoding="utf-8"))
        if not isinstance(images, dict) or not isinstance(sounds, dict):
            raise ValueError("Asset catalogues must be JSON objects.")
        registry = cls(images, sounds)
        if not registry.images or not registry.sounds:
            raise ValueError("Asset catalogues carry no licensed entries.")
        for sound in _trusted_optional_sounds(base):
            for key in ("sha256", "originalSHA256"):
                digest = sound[key]
                existing = registry.sounds.get(digest)
                if existing is not None and existing != sound["license"]:
                    raise ValueError("Trusted sound catalogue licences conflict.")
                registry.sounds[digest] = sound["license"]
        return registry

    @staticmethod
    def normalize(credits) -> list[dict]:
        """Shape check only: a bounded, de-duplicated list of {kind, sha256}."""
        if not isinstance(credits, list) or len(credits) > MAX_CREDITS:
            raise IntakeError("Asset credits must be a bounded list.")
        seen: set[tuple[str, str]] = set()
        result = []
        for credit in credits:
            if (not isinstance(credit, dict) or set(credit) != {"kind", "sha256"} or credit["kind"] not in KINDS
                    or not isinstance(credit["sha256"], str) or not DIGEST.fullmatch(credit["sha256"])):
                raise IntakeError("Asset credits must name a kind and a SHA-256 digest.")
            key = (credit["kind"], credit["sha256"])
            if key not in seen:
                seen.add(key)
                result.append({"kind": key[0], "sha256": key[1]})
        return result

    def check(self, credits: list[dict]) -> list[dict]:
        """Every declared asset must be a catalogued, licensed library asset."""
        checked = []
        for credit in self.normalize(credits):
            table = self.images if credit["kind"] == "image" else self.sounds
            licence = table.get(credit["sha256"])
            if licence is None:
                raise IntakeError("An asset in this render is not in the licensed library. Remove it or replace it with a library asset before submitting.", 422)
            checked.append({**credit, "license": licence})
        return checked

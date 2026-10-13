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
import os
from pathlib import Path
import re

from .store import IntakeError

DIGEST = re.compile(r"^[a-f0-9]{64}$")
KINDS = ("image", "sound")
MAX_CREDITS = 200
DEFAULT_ROOT = Path(__file__).resolve().parents[2] / "StickDeathInfinity" / "Resources"


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

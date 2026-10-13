#!/usr/bin/env python3
"""Deterministic shared `.sdi` contract fixtures for iOS and Android.

Each fixture is the iOS DeviceStorageManager portable envelope:
`SDIPROJECT000001\n` + 8-byte big-endian payload length + SHA-256(payload) + Revision v1 JSON,
whose `project.editableDocumentData` is a base64 `StudioDocumentArchive` (`document` +
`rasterFrameIndices`). They are independently constructed from the Codable contract in
`StickDeathInfinity/Models` (schema 35), not captured device exports. `expectations.json`
records what each production client must do with them; `verify_fixtures.py` checks that the
committed bytes are exactly what this script produces.
"""
import base64
import hashlib
import json
import struct
from pathlib import Path

MAGIC = b"SDIPROJECT000001\n"
ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / "assets"
PROJECT_ID = "00000000-0000-0000-0000-000000000035"


def points(*xy, pressures=None):
    result = [{"x": x, "y": y} for x, y in xy]
    if pressures is not None:
        for point, pressure in zip(result, pressures):
            point["pressure"] = pressure
    return result


def round_brush(seed):
    return {"version": 1, "family": "round", "seed": seed, "smoothing": 3, "pressureEnabled": True,
            "tipAngleDegrees": 45, "texture": 0.5, "grain": 0.3}


def studio_document(schema=35):
    """The golden schema-35 document: lock modes, a label, PhotoCraft blends, holds, pressure and the mixer."""
    return {
        "schemaVersion": schema, "id": PROJECT_ID, "name": "Swift schema 35 studio fixture",
        "width": 64, "height": 64, "fps": 12, "activeFrameID": "frame-1", "activeLayerID": "layer-ink",
        "layers": [
            {"id": "layer-ink", "name": "Ink", "visible": True, "locked": False, "opacity": 1,
             "lockMode": "position", "blendMode": "multiply", "glowEnabled": False, "colorLabel": "#FC5D5B"},
            {"id": "layer-shade", "name": "Shade", "visible": True, "locked": False, "opacity": 0.6,
             "lockMode": "alpha", "blendMode": "linear-dodge", "glowEnabled": False},
        ],
        "frames": [
            {"id": "frame-1", "elements": [
                {"id": "stroke-pen", "tool": "pen", "points": points((8, 8), (24, 12), (40, 20)), "color": "#2563EB",
                 "width": 10, "opacity": 1, "layerID": "layer-ink"},
                {"id": "stroke-pencil", "tool": "pencil", "points": points((8, 24), (24, 28), (40, 30)), "color": "#DC2626",
                 "width": 10, "opacity": 1, "layerID": "layer-ink"},
                {"id": "stroke-line", "tool": "line", "points": points((4, 60), (60, 60)), "color": "#000000",
                 "width": 2, "opacity": 0.5, "layerID": "layer-ink"},
            ]},
            {"id": "frame-2", "holdTicks": 3, "elements": [
                {"id": "stroke-brush", "tool": "pen", "points": points((8, 40), (40, 44), (48, 50), pressures=[0.2, 0.6, 1.0]),
                 "color": "#111111", "width": 6, "opacity": 0.9, "layerID": "layer-shade", "brush": round_brush(7)},
            ]},
        ],
        "audioClips": [], "mutedAudioTracks": [4], "audioTrackVolumes": [1, 0.7, 1, 1],
        "audioTrackPans": [-0.25, 0, 0.5, 0], "soloedAudioTracks": [2],
        "gridEnabled": False, "onionEnabled": False, "createdAt": 0, "modifiedAt": 0, "revision": 0,
    }


def envelope(document, audio_tracks=None, title=None):
    archive = json.dumps({"document": document, "rasterFrameIndices": {}}, sort_keys=True, separators=(",", ":"))
    project = {
        "id": document["id"],
        "metadata": {"id": document["id"], "title": title or document["name"], "fps": document["fps"],
                     "canvasWidth": document["width"], "canvasHeight": document["height"],
                     "frameCount": len(document["frames"]), "layerCount": len(document["layers"]),
                     "createdAt": 0, "modifiedAt": 0},
        "frames": [{} for _ in document["frames"]],
        "audioTracks": audio_tracks or [],
        "editableDocumentData": base64.b64encode(archive.encode("utf-8")).decode("ascii"),
        "additionalImageAssets": {},
    }
    payload = json.dumps({"version": 1, "project": project}, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return MAGIC + struct.pack(">Q", len(payload)) + hashlib.sha256(payload).digest() + payload


def fixtures():
    golden = studio_document()
    text = studio_document()
    text["frames"][0]["elements"].append({"id": "stroke-text", "tool": "text", "points": points((8, 8)), "color": "#000000",
                                          "width": 4, "opacity": 1, "layerID": "layer-ink", "fillColor": "Hello"})
    future = studio_document(schema=36)
    glow = studio_document()
    glow["layers"][0].update({"glowEnabled": True, "glowColor": "#00FF00", "glowRadius": 12, "glowStrength": 0.75})
    label = studio_document()
    label["layers"][0]["colorLabel"] = "#123456"
    clip = studio_document()
    clip["audioClips"] = [{"id": "clip-1", "soundName": "Kick", "track": 1, "startTime": 0, "duration": 0.5,
                           "volume": 0.8, "assetID": "00000000-0000-0000-0000-00000000A001", "sourceOffset": 0, "isMuted": False}]
    clip_tracks = [{"id": "00000000-0000-0000-0000-00000000A001", "name": "Kick", "format": "wav",
                    "audioData": base64.b64encode(b"RIFF").decode("ascii"), "startTime": 0, "duration": 0.5}]
    return {
        "swift-schema35-studio.sdi": (envelope(golden), {
            "android": "accept", "schemaVersion": 35, "layers": 2, "frames": 2, "elements": 4,
            "notes": "Position/alpha lock modes, a PhotoCraft label, multiply + linear-dodge blends, a 3-tick hold, "
                     "a pressure-sampled round brush, a legacy line and the four-track mixer (volume, mute, pan, solo)."}),
        "swift-schema35-text.sdi": (envelope(text), {
            "android": "reject", "schemaVersion": 35, "reason": "text element (fillColor text) is not importable; original preserved"}),
        "swift-schema36-future.sdi": (envelope(future), {
            "android": "reject", "schemaVersion": 36, "reason": "schema above the supported 1…35 range"}),
        "swift-schema35-glow.sdi": (envelope(glow), {
            "android": "reject", "schemaVersion": 35, "reason": "layer glow has no Android renderer"}),
        "swift-schema35-unknown-label.sdi": (envelope(label), {
            "android": "reject", "schemaVersion": 35, "reason": "colorLabel outside the eleven PhotoCraft swatches"}),
        "swift-schema35-audio-clip.sdi": (envelope(clip, audio_tracks=clip_tracks), {
            "android": "reject", "schemaVersion": 35, "reason": "managed audio clips/assets are not importable yet"}),
    }


def write():
    ASSETS.mkdir(parents=True, exist_ok=True)
    expectations = {}
    for name, (data, expectation) in fixtures().items():
        (ASSETS / name).write_bytes(data)
        expectations[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), **expectation}
    (ROOT / "expectations.json").write_text(json.dumps(expectations, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return expectations


if __name__ == "__main__":
    for name, info in write().items():
        print(f"{name}: {info['bytes']} bytes {info['sha256'][:12]}… ({info['android']})")

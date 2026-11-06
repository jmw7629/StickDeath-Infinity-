"""Bounded MP4 inspection plus actual decode before private review registration.

Uses operator-installed, pinned FFmpeg tools; does not download executables or
run media-provided scripts. Invoke inside the host's resource-limited worker.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
from .store import IntakeError
from .decoder import DecoderSandbox, ValidationReceipt


class MediaValidator:
    def __init__(self, sandbox: DecoderSandbox, *, max_seconds: int = 600,
                 decode_timeout: int = 600, max_pixels: int = 8_294_400):
        if not isinstance(sandbox, DecoderSandbox):
            raise ValueError("A pinned decoder sandbox is required.")
        if not 1 <= max_seconds <= 3600 or not 1 <= decode_timeout <= 1800 or not 1 <= max_pixels <= 16_777_216:
            raise ValueError("Invalid media validation limits.")
        self.sandbox = sandbox
        self.max_seconds, self.decode_timeout, self.max_pixels = max_seconds, decode_timeout, max_pixels

    def __call__(self, path: Path):
        with self.sandbox.snapshot(path) as snapshot:
            self._validate(snapshot)
            receipt = ValidationReceipt(snapshot.size, snapshot.sha256)
        return receipt

    def _validate(self, snapshot):
        raw = self.sandbox.probe(snapshot)
        try:
            metadata = json.loads(raw)
            streams = metadata["streams"]; container = metadata["format"]
            duration = float(container["duration"])
            video = [s for s in streams if s["codec_type"] == "video"]
            audio = [s for s in streams if s["codec_type"] == "audio"]
            if (not math.isfinite(duration) or not 0 < duration <= self.max_seconds or len(video) != 1 or
                    len(audio) > 1 or len(streams) != len(video)+len(audio) or int(container["size"]) != snapshot.size or
                    "mp4" not in container["format_name"].split(",")):
                raise ValueError()
            v = video[0]; width = int(v["width"]); height = int(v["height"])
            numerator, denominator = map(int,v["avg_frame_rate"].split("/"))
            if (v["codec_name"] not in ("h264","hevc") or width <= 0 or height <= 0 or
                    max(width,height) > 4096 or width*height > self.max_pixels or denominator <= 0 or
                    not 0 < numerator/denominator <= 60):
                raise ValueError()
            if audio and (audio[0]["codec_name"] != "aac" or not 1 <= int(audio[0]["channels"]) <= 2 or
                          not 8000 <= int(audio[0]["sample_rate"]) <= 48000):
                raise ValueError()
        except (KeyError,TypeError,ValueError,ZeroDivisionError):
            raise IntakeError("Use a supported MP4: H.264/HEVC video up to 4K/60 FPS and optional stereo AAC audio.",422) from None
        # Decode every selected frame/sample; null muxer intentionally discards
        # decoded validation output, not a substitute for actual exported audio.
        self.sandbox.decode(snapshot, self.decode_timeout)

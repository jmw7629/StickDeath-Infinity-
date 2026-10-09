"""Bounded MP4 inspection plus actual decode before private review registration.

Uses operator-installed, pinned FFmpeg tools; does not download executables or
run media-provided scripts. Invoke inside the host's resource-limited worker.
"""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import signal
import stat
import subprocess
import tempfile
import time
from .store import IntakeError, MAX_BYTES


class MediaValidator:
    def __init__(self, ffprobe: Path, ffmpeg: Path, *, max_seconds: int = 600,
                 decode_timeout: int = 600, max_pixels: int = 8_294_400):
        self.ffprobe = self._executable(ffprobe)
        self.ffmpeg = self._executable(ffmpeg)
        if not 1 <= max_seconds <= 3600 or not 1 <= decode_timeout <= 1800 or not 1 <= max_pixels <= 16_777_216:
            raise ValueError("Invalid media validation limits.")
        self.max_seconds, self.decode_timeout, self.max_pixels = max_seconds, decode_timeout, max_pixels

    @staticmethod
    def _executable(path):
        path = Path(path).resolve(strict=True)
        info = path.stat()
        if not path.is_absolute() or not stat.S_ISREG(info.st_mode) or not os.access(path,os.X_OK) or info.st_mode & 0o022:
            raise ValueError("Use a pinned operator-owned media executable.")
        return str(path)

    @staticmethod
    def _run(arguments, timeout, output_limit):
        # Files avoid pipe deadlock/unbounded communicate() buffers. stderr never
        # reaches client responses or logs; uploaded names/metadata may be sensitive.
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                                       start_new_session=True, close_fds=True)
            deadline = time.monotonic()+timeout
            try:
                while process.poll() is None:
                    if time.monotonic() >= deadline or os.fstat(output.fileno()).st_size > output_limit or os.fstat(errors.fileno()).st_size > 65536:
                        raise IntakeError("Media exceeds validation time or diagnostic limits.",422)
                    time.sleep(0.05)
                if process.returncode != 0:
                    raise IntakeError("The rendered video could not be decoded. Export a new MP4.",422)
                output.seek(0)
                result = output.read(output_limit+1)
                if len(result) > output_limit:
                    raise IntakeError("Media metadata exceeds the permitted limit.",422)
                return result
            finally:
                if process.poll() is None:
                    os.killpg(process.pid,signal.SIGKILL)
                process.wait()

    def __call__(self, path: Path):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or not 1 <= info.st_size <= MAX_BYTES:
            raise IntakeError("Invalid rendered file.",422)
        common = ["-v","error","-max_alloc","67108864","-protocol_whitelist","file",
                  "-format_whitelist","mov","-probesize","5242880","-analyzeduration","5000000"]
        raw = self._run([self.ffprobe,*common,"-show_entries",
            "format=format_name,duration,size:stream=index,codec_type,codec_name,width,height,channels,sample_rate,duration,avg_frame_rate",
            "-of","json",str(path)],30,65536)
        try:
            metadata = json.loads(raw)
            streams = metadata["streams"]; container = metadata["format"]
            duration = float(container["duration"])
            video = [s for s in streams if s["codec_type"] == "video"]
            audio = [s for s in streams if s["codec_type"] == "audio"]
            if (not math.isfinite(duration) or not 0 < duration <= self.max_seconds or len(video) != 1 or
                    len(audio) > 1 or len(streams) != len(video)+len(audio) or int(container["size"]) != info.st_size or
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
        self._run([self.ffmpeg,"-nostdin",*common,"-xerror","-err_detect","explode","-threads","2",
                   "-i",str(path),"-map","0:v:0","-map","0:a:0?","-threads","2","-filter_threads","1",
                   "-f","null","-"],self.decode_timeout,1024)
        after = path.lstat()
        if (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns) != (info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns):
            raise IntakeError("Render changed during validation.",409)

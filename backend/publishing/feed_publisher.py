"""Feed publication worker: the host adapter for ``feed-publication.sql`` (#217,
#219, #220, #245). One job per call, never a daemon, nothing starts on import.

The database decides what may be published (``release_allowed`` on claim and on
finish). This worker only moves bytes: it resolves the registered private artifact
inside owned storage, verifies the SHA-256 of the actual bytes against the approved
digest, measures the duration with the injected probe, copies the file to the
approved HTTPS hosting through the injected ``HostingAdapter`` and reports the
result. Removals (moderation, cancellation after copy, account deletion) run first
and succeed only when the adapter confirms the hosted copy is gone. The creator's
original is never touched: the artifact root holds server staging copies only.

Poster thumbnails (#217): after the bytes are verified, one JPEG frame is extracted
from that same verified file at a fixed instant (``poster_instant``) with
single-threaded, bit-exact ffmpeg settings, bounded to 640 px on the long edge and
256 KiB, hashed, hosted beside the video and reported with ``publish_finish``. A
poster that cannot be produced is simply absent (clients show a placeholder); it
never blocks the approved video and is never substituted with another image.
Removals delete the hosted poster together with the video.

A second executor that finds the worker lock held claims nothing and reports
``busy`` (#263), like ``PublishingWorker``'s slot cap.
"""
from __future__ import annotations

import fcntl
import hashlib
import subprocess
from pathlib import Path
from typing import Callable, Optional, Protocol

from .worker import JobAPI

MAX_DURATION_SECONDS = 3600.0
MAX_POSTER_BYTES = 256 * 1024
POSTER_EDGE = 640


class FeedJobAPI(JobAPI):
    """Service-role RPC client for the four feed worker functions."""
    PREFIX = "sdi_feed_"
    PERMITTED = frozenset({"publish_claim", "publish_finish", "removal_claim", "removal_finish"})


class HostingAdapter(Protocol):
    def put(self, name: str, source: Path, digest: str) -> str:
        """Copy ``source`` to public HTTPS hosting under ``name`` and return the URL.
        Must verify the stored bytes match ``digest`` before returning."""

    def delete(self, url: str) -> bool:
        """Remove a hosted copy. Return True only when the copy is confirmed gone."""


class FeedError(Exception):
    """A reason that is safe to store in ``publish_jobs.last_error``."""


def poster_instant(duration: float) -> float:
    """The frame the poster shows: one second in, or the midpoint of a shorter clip.
    Fixed by the measured duration alone, so a re-run selects the same frame."""
    return round(min(1.0, duration / 2.0), 3)


def ffmpeg_poster(source: Path, duration: float, destination: Path, ffmpeg: str = "ffmpeg", timeout: float = 60.0) -> None:
    """Extract one bit-exact JPEG frame from ``source`` into ``destination``.

    Accurate seek (``-ss`` after ``-i``), one thread and ``+bitexact`` keep the
    output identical for identical input on the same ffmpeg build. Raises on any
    failure; the caller treats that as "no poster"."""
    scale = "scale=w='if(gte(iw,ih),min(%d,iw),-2)':h='if(gte(iw,ih),-2,min(%d,ih))':flags=bicubic" % (POSTER_EDGE, POSTER_EDGE)
    command = [ffmpeg, "-nostdin", "-v", "error", "-threads", "1", "-i", str(source), "-ss", "%.3f" % poster_instant(duration),
               "-map", "0:v:0", "-frames:v", "1", "-vf", scale, "-map_metadata", "-1", "-fflags", "+bitexact",
               "-flags:v", "+bitexact", "-c:v", "mjpeg", "-q:v", "5", "-f", "image2", "-y", str(destination)]
    subprocess.run(command, check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class FeedPublisher:
    def __init__(self, api: FeedJobAPI, artifact_root: Path, host: HostingAdapter, probe_duration: Callable[[Path], float],
                 checkpoint_root: Optional[Path] = None, extract_poster: Optional[Callable[[Path, float, Path], None]] = None):
        self.api = api
        self.artifacts = Path(artifact_root).resolve(strict=True)
        self.host = host
        self.probe_duration = probe_duration
        self.checkpoints = Path(checkpoint_root) if checkpoint_root else self.artifacts / ".feed-worker"
        self.extract_poster = extract_poster if extract_poster is not None else ffmpeg_poster

    def run_once(self) -> dict:
        self.checkpoints.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.checkpoints.is_symlink() or self.checkpoints.stat().st_mode & 0o077:
            raise RuntimeError("Worker state must be private.")
        with (self.checkpoints / "worker.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return {"state": "busy"}
            removal = self.api.call("removal_claim")
            if not removal.get("empty"):
                return self._remove(removal)
            job = self.api.call("publish_claim")
            if job.get("empty"):
                return {"state": "idle"}
            return self._publish(job)

    def _delete(self, url) -> bool:
        if not isinstance(url, str) or not url.startswith("https://"):
            return False
        try:
            return self.host.delete(url) is True
        except Exception:
            return False

    def _remove(self, job: dict) -> dict:
        confirmed = self._delete(job.get("url"))
        poster = job.get("poster_url")
        if poster is not None:
            # The poster goes with its video; removal succeeds only when both are gone.
            confirmed = self._delete(poster) and confirmed
        self.api.call("removal_finish", source=job["source"], job=job["job"], token=job["lease"], confirmed=confirmed)
        return {"state": "removed" if confirmed else "removal_unconfirmed", "job": job["job"], "source": job["source"]}

    def _publish(self, job: dict) -> dict:
        job_id, token = job["job"], job["lease"]
        if job.get("destination") != "feed":
            self.api.call("publish_finish", job=job_id, token=token, url=None, duration=None, failure="Unsupported destination for the feed worker.")
            return {"state": "failed", "job": job_id, "reason": "unsupported destination"}
        try:
            source = self._artifact(job)
            duration = self._duration(source)
            url = self.host.put("%s.mp4" % job["digest"], source, job["digest"])
            if not isinstance(url, str) or not url.startswith("https://") or len(url) > 2048:
                raise FeedError("Hosting adapter returned no HTTPS URL; nothing published.")
        except FeedError as error:
            self.api.call("publish_finish", job=job_id, token=token, url=None, duration=None, failure=str(error))
            return {"state": "failed", "job": job_id, "reason": str(error)}
        except Exception:
            # Hosting may hold a partial copy; the message tells the operator to check without leaking detail.
            self.api.call("publish_finish", job=job_id, token=token, url=None, duration=None, failure="Hosting copy failed; verify hosting before retry. Nothing published.")
            return {"state": "failed", "job": job_id, "reason": "hosting error"}
        poster, poster_reason = self._poster(job, source, duration)
        extra = {"poster_url": poster["url"], "poster_digest": poster["digest"], "poster_bytes": poster["bytes"]} if poster else {}
        accepted = self.api.call("publish_finish", job=job_id, token=token, url=url, duration=duration, **extra)
        if accepted is not True:
            # The lease was lost after the copy: the hosted files are orphaned, so remove them now.
            removed = self._delete(url)
            if poster:
                removed = self._delete(poster["url"]) and removed
            return {"state": "reconcile", "job": job_id, "url": url, "orphan_removed": removed}
        result = {"state": "published", "job": job_id, "url": url, "duration": duration, "poster": poster}
        if poster is None:
            result["poster_reason"] = poster_reason
        return result

    def _poster(self, job: dict, source: Path, duration: float):
        """Extract, bound, hash and host the poster. Returns (poster, None) or (None, reason)."""
        staging = self.checkpoints / ("%s.poster.jpg" % job["digest"])
        try:
            staging.unlink(missing_ok=True)
            try:
                self.extract_poster(source, duration, staging)
            except Exception:
                return None, "Poster frame could not be extracted."
            if staging.is_symlink() or not staging.is_file():
                return None, "Poster frame could not be extracted."
            size = staging.stat().st_size
            if not 0 < size <= MAX_POSTER_BYTES:
                return None, "Poster frame is outside the accepted size."
            with staging.open("rb") as handle:
                head = handle.read(3)
                handle.seek(-2, 2)
                tail = handle.read(2)
            if head != b"\xff\xd8\xff" or tail != b"\xff\xd9":
                return None, "Poster frame is not a complete JPEG image."
            digest = sha256_of(staging)
            try:
                url = self.host.put("%s.poster.jpg" % job["digest"], staging, digest)
            except Exception:
                return None, "Poster hosting failed; the video is published without a poster."
            if not isinstance(url, str) or not url.startswith("https://") or len(url) > 2048:
                return None, "Poster hosting returned no HTTPS URL."
            return {"url": url, "digest": digest, "bytes": size}, None
        finally:
            staging.unlink(missing_ok=True)

    def _artifact(self, job: dict) -> Path:
        key = job.get("object_key")
        if not isinstance(key, str) or not key or "/" in key or key.startswith("."):
            raise FeedError("Registered artifact key is invalid.")
        candidate = self.artifacts / key
        if candidate.is_symlink():
            raise FeedError("Registered artifact is not a regular file.")
        try:
            source = candidate.resolve(strict=True)
        except FileNotFoundError:
            raise FeedError("Registered artifact is missing from staging; it may have expired.") from None
        if not source.is_relative_to(self.artifacts) or not source.is_file():
            raise FeedError("Registered artifact lies outside owned storage.")
        if source.stat().st_size != job.get("byte_count"):
            raise FeedError("Artifact size differs from the registered render.")
        if sha256_of(source) != job.get("digest"):
            raise FeedError("Artifact bytes do not match the approved digest; nothing published.")
        return source

    def _duration(self, source: Path) -> float:
        try:
            duration = float(self.probe_duration(source))
        except Exception:
            raise FeedError("Duration could not be measured from the rendered file.") from None
        if not duration > 0 or duration > MAX_DURATION_SECONDS:
            raise FeedError("Measured duration is outside the accepted range.")
        return duration

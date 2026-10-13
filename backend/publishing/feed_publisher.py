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
"""
from __future__ import annotations

import fcntl
import hashlib
from pathlib import Path
from typing import Callable, Optional, Protocol

from .worker import JobAPI

MAX_DURATION_SECONDS = 3600.0


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


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class FeedPublisher:
    def __init__(self, api: FeedJobAPI, artifact_root: Path, host: HostingAdapter, probe_duration: Callable[[Path], float],
                 checkpoint_root: Optional[Path] = None):
        self.api = api
        self.artifacts = Path(artifact_root).resolve(strict=True)
        self.host = host
        self.probe_duration = probe_duration
        self.checkpoints = Path(checkpoint_root) if checkpoint_root else self.artifacts / ".feed-worker"

    def run_once(self) -> dict:
        self.checkpoints.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.checkpoints.is_symlink() or self.checkpoints.stat().st_mode & 0o077:
            raise RuntimeError("Worker state must be private.")
        with (self.checkpoints / "worker.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            removal = self.api.call("removal_claim")
            if not removal.get("empty"):
                return self._remove(removal)
            job = self.api.call("publish_claim")
            if job.get("empty"):
                return {"state": "idle"}
            return self._publish(job)

    def _remove(self, job: dict) -> dict:
        url = job.get("url")
        confirmed = False
        if isinstance(url, str) and url.startswith("https://"):
            try:
                confirmed = self.host.delete(url) is True
            except Exception:
                confirmed = False
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
        accepted = self.api.call("publish_finish", job=job_id, token=token, url=url, duration=duration)
        if accepted is not True:
            # The lease was lost after the copy: the hosted file is orphaned, so remove it now.
            removed = False
            try:
                removed = self.host.delete(url) is True
            except Exception:
                removed = False
            return {"state": "reconcile", "job": job_id, "url": url, "orphan_removed": removed}
        return {"state": "published", "job": job_id, "url": url, "duration": duration}

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

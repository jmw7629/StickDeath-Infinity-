"""Private owner previews for rendered daily drafts (#212), on the existing intake preview links.

The worker copies a validated draft MP4 into the private intake directory as
`<upload>.mp4` (the id is derived from the render digest), records who may view
it and until when in `<upload>.draft.json`, and signs a short-lived
`backend.ingestion.preview.PreviewLinks` URL for the owner. The intake host's
`PreviewApplication` serves it only while `DraftPreviewStore.authority` agrees:
same owner, same digest, same byte count, retention not expired.

Bounds: links last at most 15 minutes (PreviewLinks); the retained copy at most
`MAX_RETENTION_SECONDS`. `expire()` deletes expired copies; the editable project
and original render stay in the renderer's own output directory. Nothing here
publishes, uploads to a third party or makes a preview public; the URL is a
private bearer link delivered only through the owner's review queue.
"""
from __future__ import annotations

import datetime as _dt
import fcntl
import hashlib
import json
import os
import re
import stat
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Optional

from backend.ingestion.preview import PreviewLinks

SCHEMA = "sdi_spatter_draft_preview"
DEFAULT_RETENTION_SECONDS = 7 * 86400
MAX_RETENTION_SECONDS = 14 * 86400
MAX_DRAFT_BYTES = 512 * 1024 * 1024
_DIGEST = re.compile(r"[a-f0-9]{64}")

ENV_ORIGIN = "SDI_INTAKE_ORIGIN"
ENV_KEY_FILE = "SDI_PREVIEW_SIGNING_KEY_FILE"
ENV_DIRECTORY = "SDI_INTAKE_DIRECTORY"
ENV_OWNER = "SDI_DRAFT_PREVIEW_OWNER_ID"
ENV_RETENTION = "SDI_DRAFT_PREVIEW_RETENTION_SECONDS"
ENV_QUOTA = "SDI_INTAKE_TOTAL_BYTES"


def draft_upload_id(digest: str) -> str:
    """Deterministic intake id for a render digest (namespaced away from random upload ids)."""
    if not _DIGEST.fullmatch(digest):
        raise ValueError("Invalid render digest.")
    return str(uuid.UUID(bytes=hashlib.sha256(b"sdi-spatter-draft:" + digest.encode()).digest()[:16], version=4))


@dataclass(frozen=True)
class PublishedPreview:
    """A signed owner link plus the retained-render record the review row needs
    (`object_key`, `byte_count`, `artifact_expires_at` in spatter_draft_progress)."""
    url: str
    expires: _dt.datetime
    object_key: str
    byte_count: int
    retained_until: _dt.datetime


class DraftPreviewStore:
    def __init__(self, root: Path, links: PreviewLinks, owner: str, *, retention: int = DEFAULT_RETENTION_SECONDS,
                 clock: Callable[[], float] = time.time, total_quota: Optional[int] = None,
                 other_usage: Callable[[], int] = lambda: 0):
        """`total_quota` bounds intake disk use: drafts plus `other_usage()` (the
        intake uploads' charged bytes) must stay within it."""
        root = Path(root)
        info = root.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("The preview directory must be a private directory owned by the worker.")
        if not isinstance(links, PreviewLinks):
            raise ValueError("Signed private preview links are required.")
        if not 3600 <= retention <= MAX_RETENTION_SECONDS:
            raise ValueError(f"Draft preview retention must be 1 hour to {MAX_RETENTION_SECONDS // 86400} days.")
        if total_quota is not None and (type(total_quota) is not int or not 1 <= total_quota <= 1024 ** 4):
            raise ValueError("Invalid intake disk quota.")
        self.root, self.links, self.retention, self.clock = root.resolve(), links, int(retention), clock
        self.owner = str(uuid.UUID(owner))
        self.total_quota, self.other_usage = total_quota, other_usage

    def retained_bytes(self, exclude: Optional[str] = None) -> int:
        """Bytes of live (unexpired) draft copies: charged to the intake disk quota."""
        total = 0
        for record_path in self.root.glob("*.draft.json"):
            upload = record_path.name[: -len(".draft.json")]
            if upload == exclude:
                continue
            record = self._record(upload)
            if record and type(record.get("byte_count")) is int and type(record.get("expires")) is int and record["expires"] > self.clock():
                total += record["byte_count"]
        return total

    def _paths(self, upload: str):
        return self.root / (upload + ".mp4"), self.root / (upload + ".draft.json"), self.root / (upload + ".lock")

    def _lock(self, upload: str, shared: bool = False) -> int:
        # Lock files are retained, matching UploadStore and PreviewApplication.
        fd = os.open(self._paths(upload)[2], os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        fcntl.flock(fd, fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
        return fd

    def _record(self, upload: str) -> Optional[dict]:
        try:
            fd = os.open(self._paths(upload)[1], os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            return None
        with os.fdopen(fd, "rb") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 4096:
                return None
            try:
                record = json.loads(handle.read(4097))
            except ValueError:
                return None
        return record if isinstance(record, dict) and record.get("schema") == SCHEMA else None

    def publish(self, movie: Path, digest: str, plan: Any = None) -> PublishedPreview:
        """Copy a verified draft into the preview directory and sign an owner link.
        Idempotent for the same digest. Refused when the intake disk quota is full."""
        upload = draft_upload_id(digest)
        target, record_path, _ = self._paths(upload)
        fd = self._lock(upload)
        try:
            source = os.open(movie, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(source, "rb") as reader:
                info = os.fstat(reader.fileno())
                if not stat.S_ISREG(info.st_mode) or not 1 <= info.st_size <= MAX_DRAFT_BYTES:
                    raise ValueError("The draft movie is missing, empty or too large for a private preview.")
                existing = self._record(upload)
                if existing is not None and existing.get("digest") != digest:
                    raise ValueError("The preview slot belongs to different content.")
                if existing is None and target.exists():
                    raise ValueError("The preview slot is occupied by an intake upload.")
                if self.total_quota is not None and \
                        self.other_usage() + self.retained_bytes(exclude=upload) + info.st_size > self.total_quota:
                    raise ValueError("The intake disk quota is full; no draft preview was made.")
                temporary = self.root / (upload + ".mp4.partial")
                hasher, size = hashlib.sha256(), 0
                out = os.open(temporary, os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                try:
                    with os.fdopen(out, "wb") as writer:
                        for chunk in iter(lambda: reader.read(1 << 20), b""):
                            hasher.update(chunk); size += len(chunk); writer.write(chunk)
                        writer.flush(); os.fsync(writer.fileno())
                    if hasher.hexdigest() != digest or size != info.st_size:
                        raise ValueError("The draft movie changed while it was copied; no preview was made.")
                    # Record first: a crash before the movie lands leaves a record whose
                    # byte count does not match, which authorizes nothing and is retried.
                    record = {"schema": SCHEMA, "upload": upload, "owner": self.owner, "digest": digest, "byte_count": size,
                              "expires": int(self.clock()) + self.retention, "seed": getattr(plan, "seed", None)}
                    partial = self.root / (upload + ".draft.json.partial")
                    with os.fdopen(os.open(partial, os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW, 0o600), "w") as writer:
                        json.dump(record, writer, sort_keys=True); writer.flush(); os.fsync(writer.fileno())
                    os.replace(partial, record_path)
                    os.replace(temporary, target)
                finally:
                    if temporary.exists():
                        temporary.unlink()
        finally:
            os.close(fd)
        url, expires = self.link(upload, digest)
        record = self._record(upload) or {}
        return PublishedPreview(url=url, expires=expires, object_key=upload + ".mp4", byte_count=int(record["byte_count"]),
                                retained_until=_dt.datetime.fromtimestamp(record["expires"], _dt.timezone.utc))

    def link(self, upload: str, digest: str) -> tuple[str, _dt.datetime]:
        """A fresh short-lived owner link while the retained copy is valid (renewal)."""
        authority = self.authority(upload, self.owner, digest)
        if authority is None:
            raise ValueError("The retained draft preview has expired or is unavailable.")
        url, expires = self.links(upload, self.owner, digest)
        retained = _dt.datetime.fromtimestamp(authority["expires"], _dt.timezone.utc)
        return url, min(expires, retained)

    def authority(self, upload: str, owner: str, digest: str) -> Optional[Mapping[str, Any]]:
        """`PreviewApplication` authorization: only the configured owner, only this
        digest, only until retention ends. None means not a (live) draft preview."""
        try:
            upload, owner = str(uuid.UUID(upload)), str(uuid.UUID(owner))
        except (ValueError, TypeError, AttributeError):
            return None
        record = self._record(upload)
        if (record is None or record.get("upload") != upload or owner != self.owner or record.get("owner") != owner
                or record.get("digest") != digest or type(record.get("byte_count")) is not int
                or type(record.get("expires")) is not int or record["expires"] <= self.clock()):
            return None
        try:
            info = os.stat(self._paths(upload)[0], follow_symlinks=False)
        except OSError:
            return None
        if not stat.S_ISREG(info.st_mode) or info.st_size != record["byte_count"]:
            return None
        return {"byte_count": record["byte_count"], "expires": record["expires"]}

    def expire(self, limit: int = 100) -> int:
        """Delete expired draft copies (movie and record; the lock file is retained)."""
        removed = 0
        for record_path in sorted(self.root.glob("*.draft.json"))[: max(1, limit) * 4]:
            upload = record_path.name[: -len(".draft.json")]
            try:
                upload = str(uuid.UUID(upload))
            except ValueError:
                continue
            fd = self._lock(upload)
            try:
                record = self._record(upload)
                if record is None or type(record.get("expires")) is not int or record["expires"] <= self.clock():
                    for path in self._paths(upload)[:2]:
                        if path.exists() or path.is_symlink():
                            path.unlink()
                    removed += 1
            finally:
                os.close(fd)
            if removed >= limit:
                break
        return removed

    def __call__(self, movie: Path, digest: str, plan: Any = None) -> PublishedPreview:
        return self.publish(movie, digest, plan)

    def signer(self, fallback: Callable[[str, str, str], tuple]) -> Callable[[str, str, str], tuple]:
        """Preview signer for the intake host (ReviewRegistrar): a live draft record
        for this owner and digest is re-signed through `link()` (bounded by its
        retention); anything else goes to the registered-upload signer."""
        def sign(upload: str, owner: str, digest: str):
            if self.authority(upload, owner, digest) is not None:
                return self.link(str(uuid.UUID(upload)), digest)
            return fallback(upload, owner, digest)
        return sign


def _secret_file(path: str) -> bytes:
    path = Path(path)
    if not path.is_absolute():
        raise ValueError("Secret file paths must be absolute.")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or not 32 <= info.st_size <= 16384:
            raise ValueError("Use a bounded private worker-owned signing key file.")
        return source.read(16385)


def draft_previews_from_env(environ: Optional[Mapping[str, str]] = None,
                            clock: Callable[[], float] = time.time) -> Optional[DraftPreviewStore]:
    """The draft preview publisher, or None unless the owner id, intake origin,
    signing key file, intake directory and intake disk quota are all configured
    (unconfigured-safe: the renderer then fails with its OWNER-GATED preview message)."""
    environ = os.environ if environ is None else environ
    values = {key: environ.get(key, "").strip() for key in (ENV_OWNER, ENV_ORIGIN, ENV_KEY_FILE, ENV_DIRECTORY, ENV_QUOTA)}
    if not values[ENV_OWNER]:
        return None
    missing = [key for key, value in values.items() if not value]
    if missing:
        raise ValueError("Draft previews need " + ", ".join(missing) + ".")
    retention = environ.get(ENV_RETENTION, "").strip()
    if retention and not re.fullmatch(r"[0-9]{1,8}", retention):
        raise ValueError(f"{ENV_RETENTION} must be a whole number of seconds.")
    if not re.fullmatch(r"[0-9]{1,13}", values[ENV_QUOTA]):
        raise ValueError(f"{ENV_QUOTA} must be a whole number of bytes.")
    links = PreviewLinks(values[ENV_ORIGIN], _secret_file(values[ENV_KEY_FILE]), clock=clock)
    from backend.ingestion.store import MAX_BYTES, UploadStore
    # Read-only use: the intake uploads' charged bytes; the same total quota covers both.
    quota = int(values[ENV_QUOTA])
    uploads = UploadStore(Path(values[ENV_DIRECTORY]), total_quota=quota, account_quota=max(1, min(quota, MAX_BYTES)))
    return DraftPreviewStore(Path(values[ENV_DIRECTORY]), links, values[ENV_OWNER],
                             retention=int(retention) if retention else DEFAULT_RETENTION_SECONDS, clock=clock,
                             total_quota=int(values[ENV_QUOTA]), other_usage=uploads.charged_bytes)


def combined_authority(drafts: Optional[DraftPreviewStore], fallback: Callable[[str, str, str], Any]):
    """Intake preview authorization: a live draft record first, else the registered-upload authority."""
    def authorize(upload: str, owner: str, digest: str):
        if drafts is not None:
            found = drafts.authority(upload, owner, digest)
            if found is not None:
                return found
        return fallback(upload, owner, digest)
    return authorize

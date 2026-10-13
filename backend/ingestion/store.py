"""Single-host durable binary intake. Deploy behind authenticated HTTPS only.

The transport must revalidate the current account/session before EVERY operation.
The store accepts server-established actor UUIDs, never identity from upload JSON.
No upload is publicly readable or approved by this module.
"""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import time
import uuid
from typing import Callable

CHUNK_BYTES = 4 * 1024 * 1024
MAX_BYTES = 2 * 1024 * 1024 * 1024
DIGEST = re.compile(r"^[a-f0-9]{64}$")


class IntakeError(Exception):
    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


def identifier(value: str) -> str:
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise IntakeError("Invalid identifier.") from None


class UploadStore:
    def __init__(self, root: Path, *, total_quota: int, account_quota: int = MAX_BYTES,
                 lifetime: int = 86400, clock: Callable[[], float] = time.time):
        if not 1 <= account_quota <= total_quota or not 60 <= lifetime <= 7 * 86400:
            raise ValueError("Invalid upload capacity or retention configuration.")
        self.root = Path(root)
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.root.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Upload root must be a private directory owned by the worker.")
        self.root = self.root.resolve()
        self.db = self.root / "intake.sqlite3"
        if self.db.exists() and (self.db.is_symlink() or not self.db.is_file()):
            raise ValueError("Invalid intake database path.")
        self.total_quota = total_quota
        self.account_quota = account_quota
        self.lifetime = lifetime
        self.clock = clock
        with self._connect() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS uploads (
                id TEXT PRIMARY KEY, actor TEXT NOT NULL, request TEXT NOT NULL,
                metadata TEXT NOT NULL, digest TEXT NOT NULL, size INTEGER NOT NULL,
                offset INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'receiving',
                expires REAL NOT NULL, created REAL NOT NULL, review_id TEXT,
                UNIQUE(actor,request))""")
        os.chmod(self.db, 0o600)

    @contextlib.contextmanager
    def _connect(self):
        db = sqlite3.connect(self.db, timeout=15)
        try:
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA synchronous=FULL")
            db.execute("PRAGMA journal_mode=DELETE")
            with db:
                yield db
        finally:
            db.close()

    def _sync_root(self):
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    @contextlib.contextmanager
    def _locked(self, upload: str):
        upload = identifier(upload)
        # Lock files are retained: unlinking a locked inode would admit a second writer.
        fd = os.open(self.root / (upload + ".lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise IntakeError("Upload is busy. Retry after reading its status.", 409)
                    time.sleep(0.05)
            yield upload
        finally:
            os.close(fd)

    def _owned(self, db, actor: str, upload: str):
        row = db.execute("SELECT * FROM uploads WHERE id=? AND actor=?", (upload, identifier(actor))).fetchone()
        if row is None:
            raise IntakeError("Upload unavailable.", 404)
        return row

    def _live(self, row):
        if row["state"] in ("cancelled", "expired", "invalid") or row["expires"] <= self.clock():
            raise IntakeError("Upload is no longer available.", 410)

    @staticmethod
    def _response(row):
        return {key: row[key] for key in ("id", "size", "offset", "state", "expires", "review_id")}

    def begin(self, actor: str, request: str, metadata: dict):
        actor, request = identifier(actor), identifier(request)
        allowed = {"size", "sha256", "title", "source_revision", "destinations", "rights_summary", "consent_version", "made_for_kids"}
        if not isinstance(metadata, dict) or set(metadata) != allowed:
            raise IntakeError("Complete render metadata required.")
        if type(metadata["made_for_kids"]) is not bool:
            raise IntakeError("An explicit audience classification is required.")
        size = metadata["size"]
        if type(size) is not int or not 1 <= size <= MAX_BYTES or not isinstance(metadata["sha256"], str) or not DIGEST.fullmatch(metadata["sha256"]):
            raise IntakeError("Invalid size or checksum.")
        for key, limit in (("title", 100), ("source_revision", 200), ("rights_summary", 2000), ("consent_version", 100)):
            value = metadata[key]
            if not isinstance(value, str) or not 1 <= len(value.strip()) <= limit:
                raise IntakeError("Invalid render metadata.")
        destinations = metadata["destinations"]
        if (not isinstance(destinations, list) or not destinations or
                any(not isinstance(x, str) or x not in ("feed", "youtube", "social") for x in destinations) or
                len(destinations) != len(set(destinations))):
            raise IntakeError("Choose supported destinations explicitly.")
        encoded = json.dumps(metadata, sort_keys=True, separators=(",", ":"))
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            prior = db.execute("SELECT * FROM uploads WHERE actor=? AND request=?", (actor, request)).fetchone()
            if prior:
                if prior["metadata"] != encoded:
                    raise IntakeError("Idempotency key already belongs to a different render.", 409)
                self._live(prior)
                return self._response(prior)
            # Completed files remain charged until retention removes their owned copy.
            used = db.execute("SELECT coalesce(sum(size),0) FROM uploads WHERE state NOT IN ('cancelled','expired','invalid')").fetchone()[0]
            own = db.execute("SELECT coalesce(sum(size),0),count(*) FROM uploads WHERE actor=? AND state NOT IN ('cancelled','expired','invalid')", (actor,)).fetchone()
            if used + size > self.total_quota or own[0] + size > self.account_quota or own[1] >= 5:
                raise IntakeError("Upload capacity reached. Cancel unused uploads or retry later.", 429)
            upload = str(uuid.uuid4()); now = self.clock()
            db.execute("INSERT INTO uploads(id,actor,request,metadata,digest,size,expires,created) VALUES(?,?,?,?,?,?,?,?)",
                       (upload, actor, request, encoded, metadata["sha256"], size, now+self.lifetime, now))
            return self._response(self._owned(db, actor, upload))

    def status(self, actor: str, upload: str):
        with self._connect() as db:
            row = self._owned(db, actor, identifier(upload))
            return self._response(row)

    def append(self, actor: str, upload: str, offset: int, chunk: bytes, checksum: str):
        if type(offset) is not int or offset < 0 or not isinstance(chunk, bytes) or not 1 <= len(chunk) <= CHUNK_BYTES:
            raise IntakeError("Invalid binary chunk.")
        if not isinstance(checksum, str) or not DIGEST.fullmatch(checksum) or hashlib.sha256(chunk).hexdigest() != checksum:
            raise IntakeError("Chunk checksum mismatch.", 422)
        with self._locked(upload) as upload, self._connect() as db:
            row = self._owned(db, actor, upload); self._live(row)
            if row["state"] != "receiving" or offset + len(chunk) > row["size"]:
                raise IntakeError("Upload cannot accept this chunk.", 409)
            path = self.root / (upload + ".mp4")
            fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "r+b") as file:
                actual = os.fstat(file.fileno()).st_size
                if actual < row["offset"]:
                    raise IntakeError("Stored upload requires operator recovery.", 409)
                # A crash after fsync but before DB commit leaves an uncommitted tail.
                file.truncate(row["offset"])
                if offset < row["offset"]:
                    if offset + len(chunk) > row["offset"]:
                        raise IntakeError("Offset conflict. Read upload status before retrying.", 409)
                    file.seek(offset)
                    if file.read(len(chunk)) != chunk:
                        raise IntakeError("Retried chunk differs from stored bytes.", 409)
                    return self._response(row)
                if offset != row["offset"]:
                    raise IntakeError("Offset conflict. Read upload status before retrying.", 409)
                file.seek(offset); file.write(chunk); file.flush(); os.fsync(file.fileno())
                self._sync_root()
                db.execute("UPDATE uploads SET offset=? WHERE id=?", (offset+len(chunk), upload))
                return self._response(self._owned(db, actor, upload))

    def complete(self, actor: str, upload: str, *, validate_media: Callable[[Path], None],
                 register_review: Callable[[str, str, Path, dict, float], str]):
        """Callbacks are trusted server adapters. Registration MUST be idempotent by
        upload ID and require owner review; client metadata never grants approval.
        Validator must probe/decode bounded media, not trust the file extension.
        """
        with self._locked(upload) as upload, self._connect() as db:
            row = self._owned(db, actor, upload); self._live(row)
            if row["state"] == "submitted":
                return self._response(row)
            if row["offset"] != row["size"]:
                raise IntakeError("Upload is incomplete.", 409)
            path = self.root / (upload + ".mp4")
            digest = hashlib.sha256()
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as file:
                if os.fstat(file.fileno()).st_size != row["size"]:
                    raise IntakeError("Stored size mismatch.", 422)
                while True:
                    block = file.read(CHUNK_BYTES)
                    if not block: break
                    digest.update(block)
            if digest.hexdigest() != row["digest"]:
                raise IntakeError("Full render checksum mismatch. Cancel and upload the correct file.", 422)
            validate_media(path)
            # Fence cancellation before an external registration can commit. If the
            # response is lost, retries reconcile by the same immutable upload ID.
            db.execute("UPDATE uploads SET state='registering' WHERE id=?", (upload,))
            db.commit()
            review = identifier(register_review(upload, identifier(actor), path, json.loads(row["metadata"]), row["expires"]))
            db.execute("UPDATE uploads SET state='submitted',review_id=? WHERE id=?", (review,upload))
            return self._response(self._owned(db,actor,upload))

    def cancel(self, actor: str, upload: str):
        with self._locked(upload) as upload, self._connect() as db:
            row = self._owned(db,actor,upload)
            if row["state"] in ("submitted", "registering"):
                raise IntakeError("Registration may exist. Reconcile or withdraw the review before removing its artifact.",409)
            (self.root / (upload + ".mp4")).unlink(missing_ok=True)
            self._sync_root()
            db.execute("UPDATE uploads SET state='cancelled' WHERE id=?",(upload,))
            return self._response(self._owned(db,actor,upload))

    def expire(self, artifact_released: Callable[[str, str | None], bool], limit: int = 100):
        """Operator-only bounded retention. A submitted file is deleted only after
        the job/review adapter confirms no active reader and expired registration.
        The adapter must fence new publishing leases before returning true.
        """
        removed = 0
        with self._connect() as db:
            rows = db.execute("SELECT id,actor FROM uploads WHERE expires<=? AND state NOT IN ('expired','cancelled') LIMIT ?",
                              (self.clock(),max(1,min(limit,100)))).fetchall()
        for candidate in rows:
            with self._locked(candidate["id"]) as upload, self._connect() as db:
                row = self._owned(db,candidate["actor"],upload)
                if row["state"] in ("expired", "cancelled") or row["expires"] > self.clock():
                    continue
                if row["state"] in ("submitted", "registering") and not artifact_released(upload, row["review_id"]):
                    continue
                (self.root / (upload + ".mp4")).unlink(missing_ok=True)
                self._sync_root()
                db.execute("UPDATE uploads SET state='expired' WHERE id=?",(upload,)); removed += 1
        return removed

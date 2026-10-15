"""Remove the temporary server copy once publication is verified (#190).

The intake host keeps a submitted render only while something may still read it.
``upload-retention.sql`` decides when that is over: every destination of the
current approved render holds a verified provider receipt, no job is in flight,
failed, reconciling or awaiting removal, no social/marketing reuse is pending and
no appeal is open. This runner asks for those candidates, has the database fence
the artifact (``sdi_release_published_upload`` expires every artifact version so
no new lease can start) and only then unlinks the local staging file.

Order matters for crash safety: authorization is recorded before the unlink and is
idempotent, and the database repeats authorized candidates for two days, so a host
that stops between the two steps finishes on the next run. A refusal, an error or
any doubt leaves the file in place; the expiry sweep (``retention.py``) remains the
fallback. Only files inside the intake directory are touched. The creator's
original and editable project live on the device and are never reachable here.

    python3 -m backend.publishing.cleanup --execute [--limit 25]

Nothing schedules this command; the approved host maintenance job runs it.
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Callable, Optional

from ..ingestion.store import IntakeError, UploadStore, identifier
from .worker import JobAPI


class ReleaseAPI(JobAPI):
    PREFIX = "sdi_"
    PERMITTED = frozenset({"publication_release_candidates", "release_published_upload"})


def _candidates(raw, limit: int) -> list:
    if not isinstance(raw, list):
        raise ValueError("Release candidates must be a list.")
    found = []
    for item in raw[:limit]:
        if not isinstance(item, dict):
            continue
        try:
            found.append((identifier(item.get("upload")), identifier(item.get("review"))))
        except IntakeError:
            continue
    return found


def release_published(api: ReleaseAPI, store: UploadStore, limit: int = 25) -> dict:
    """One bounded pass. Returns counts only: no paths, URLs or member data."""
    limit = max(1, min(int(limit), 100))
    report = {"released": 0, "already_released": 0, "kept": 0, "failed": 0}
    try:
        candidates = _candidates(api.call("publication_release_candidates", lim=limit), limit)
    except Exception as error:
        report["failed"] += 1
        report["error"] = type(error).__name__
        return report
    for upload, review in candidates:
        try:
            outcome = _release_one(api, store, upload, review)
        except Exception:
            outcome = "failed"
        report[outcome] += 1
    return report


def _release_one(api: ReleaseAPI, store: UploadStore, upload: str, review: str) -> str:
    # Same per-upload lock as completion, cancellation and expiry.
    with store._locked(upload) as upload, store._connect() as db:
        row = db.execute("SELECT state,review_id FROM uploads WHERE id=?", (upload,)).fetchone()
        if row is None:
            return "kept"  # registered elsewhere or unknown to this host: nothing to remove here
        if row["state"] in ("expired", "cancelled"):
            return "already_released"
        if row["state"] != "submitted" or row["review_id"] != review:
            return "kept"
        if api.call("release_published_upload", upload=upload, review=review) is not True:
            return "kept"
        path = store.root / (upload + ".mp4")
        if path.is_symlink():
            return "kept"  # never follow a link out of the private directory
        path.unlink(missing_ok=True)
        store._sync_root()
        db.execute("UPDATE uploads SET state='expired' WHERE id=?", (upload,))
        return "released"


def main(argv: Optional[list] = None, factory: Optional[Callable[[], tuple]] = None) -> int:
    parser = argparse.ArgumentParser(description="Remove temporary server renders after verified publication.")
    parser.add_argument("--execute", action="store_true", help="Required: allow removal of released server copies.")
    parser.add_argument("--limit", type=int, default=25, choices=range(1, 101), metavar="1..100")
    args = parser.parse_args(argv)
    if not args.execute:
        parser.error("No deletion performed. Supply --execute in the approved host maintenance job.")
    try:
        if factory:
            api, store = factory()
        else:
            from ..ingestion.application import create_application
            app = create_application()
            registrar = app.upload.register_review
            api, store = ReleaseAPI(registrar.base, registrar.key), app.upload.store
        report = release_published(api, store, args.limit)
    except Exception:
        # Never print configuration, signed URLs, tokens, paths or raw RPC errors.
        print("Post-publication cleanup did not finish; files were kept.", file=sys.stderr)
        return 1
    print(json.dumps(report, sort_keys=True))
    return 1 if report["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())

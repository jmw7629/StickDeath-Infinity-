"""Durable, deduplicated outbound email queue on a private SQLite file.

Recipients come from ``sdi_email_recipients`` (the database applies preferences,
account state and suppressions). The queue adds: one message per
``(address hash, template, dedup key)``, bounded retries with backoff, a
suppression re-check at claim time (a bounce recorded after enqueue still wins),
and bounce reporting through the injected callback so the database suppresses the
address. Addresses live in the queue only until the message is sent or abandoned,
then they are blanked; the hash stays for deduplication.
"""
from __future__ import annotations

import contextlib
import os
import sqlite3
import stat
import time
import uuid
from pathlib import Path
from typing import Callable, Dict, List, Mapping, Optional

from .templates import Rendered, email_hash, render

MAX_ATTEMPTS = 3
BACKOFF_SECONDS = (60, 600, 3600)
RETENTION_SECONDS = 30 * 86400


class EmailQueue:
    def __init__(self, path: Path, clock: Callable[[], float] = time.time):
        self.path = Path(path)
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.path.parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o077:
            raise ValueError("Queue directory must be private.")
        self.clock = clock
        with self._connect() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY, address_hash TEXT NOT NULL, address TEXT NOT NULL, template TEXT NOT NULL,
                dedup_key TEXT NOT NULL, category TEXT NOT NULL, subject TEXT NOT NULL, body TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'queued', attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL,
                reason TEXT NOT NULL DEFAULT '', created REAL NOT NULL, updated REAL NOT NULL,
                UNIQUE(address_hash, template, dedup_key))""")
        os.chmod(self.path, 0o600)

    @contextlib.contextmanager
    def _connect(self):
        db = sqlite3.connect(self.path, timeout=15)
        try:
            db.row_factory = sqlite3.Row
            with db:
                yield db
        finally:
            db.close()

    def enqueue(self, address: str, template: str, context: Mapping[str, str], dedup_key: str,
                unsubscribe_url: Optional[str] = None) -> Dict[str, str]:
        if not isinstance(address, str) or "@" not in address or len(address) > 320 or any(c.isspace() for c in address):
            raise ValueError("recipient address invalid")
        if not dedup_key or len(dedup_key) > 200:
            raise ValueError("dedup key required")
        rendered: Rendered = render(template, context, unsubscribe_url)
        digest = email_hash(address)
        now = self.clock()
        message_id = str(uuid.uuid4())
        with self._connect() as db:
            existing = db.execute("SELECT id, state FROM messages WHERE address_hash=? AND template=? AND dedup_key=?", (digest, template, dedup_key)).fetchone()
            if existing:
                return {"status": "duplicate", "id": existing["id"], "state": existing["state"]}
            db.execute("INSERT INTO messages(id,address_hash,address,template,dedup_key,category,subject,body,next_attempt,created,updated) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                       (message_id, digest, address, template, dedup_key, rendered.category, rendered.subject, rendered.text, now, now, now))
        return {"status": "queued", "id": message_id, "state": "queued"}

    def claim(self, batch: int = 50, suppressed: Optional[Callable[[str], bool]] = None) -> List[dict]:
        if not 1 <= batch <= 500:
            raise ValueError("batch must be 1..500")
        now = self.clock()
        claimed: List[dict] = []
        with self._connect() as db:
            rows = db.execute("SELECT * FROM messages WHERE state='queued' AND next_attempt<=? ORDER BY created LIMIT ?", (now, batch)).fetchall()
            for row in rows:
                if suppressed and suppressed(row["address_hash"]):
                    db.execute("UPDATE messages SET state='suppressed', address='', reason='suppressed before send', updated=? WHERE id=?", (now, row["id"]))
                    continue
                db.execute("UPDATE messages SET state='sending', attempts=attempts+1, updated=? WHERE id=?", (now, row["id"]))
                claimed.append({"id": row["id"], "address": row["address"], "address_hash": row["address_hash"], "template": row["template"],
                                "category": row["category"], "subject": row["subject"], "body": row["body"], "attempt": row["attempts"] + 1})
        return claimed

    def mark(self, message_id: str, outcome: str, reason: str = "", on_bounce: Optional[Callable[[str], None]] = None) -> str:
        """``outcome``: sent | retry | bounced. Returns the resulting state."""
        now = self.clock()
        with self._connect() as db:
            row = db.execute("SELECT * FROM messages WHERE id=? AND state='sending'", (message_id,)).fetchone()
            if row is None:
                return "unknown"
            if outcome == "sent":
                db.execute("UPDATE messages SET state='sent', address='', reason='', updated=? WHERE id=?", (now, message_id))
                return "sent"
            if outcome == "bounced":
                db.execute("UPDATE messages SET state='bounced', address='', reason=?, updated=? WHERE id=?", (reason[:200], now, message_id))
                if on_bounce:
                    on_bounce(row["address_hash"])
                return "bounced"
            if outcome != "retry":
                raise ValueError("unknown outcome")
            if row["attempts"] >= MAX_ATTEMPTS:
                db.execute("UPDATE messages SET state='failed', address='', reason=?, updated=? WHERE id=?", (reason[:200], now, message_id))
                return "failed"
            delay = BACKOFF_SECONDS[min(row["attempts"] - 1, len(BACKOFF_SECONDS) - 1)]
            db.execute("UPDATE messages SET state='queued', next_attempt=?, reason=?, updated=? WHERE id=?", (now + delay, reason[:200], now, message_id))
            return "queued"

    def counts(self) -> Dict[str, int]:
        with self._connect() as db:
            return {row["state"]: row["n"] for row in db.execute("SELECT state, COUNT(*) AS n FROM messages GROUP BY state")}

    def purge(self) -> int:
        """Drop finished rows past retention; keeps nothing but counts in the report."""
        with self._connect() as db:
            cursor = db.execute("DELETE FROM messages WHERE state IN ('sent','failed','bounced','suppressed') AND updated<?", (self.clock() - RETENTION_SECONDS,))
            return cursor.rowcount

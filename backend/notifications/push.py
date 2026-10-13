"""Push batch worker: moves one claimed batch from ``sdi_announcement_claim`` to
the injected transport and reports results to ``sdi_announcement_finish``.

The database already applied audience, preferences, account state and daily caps;
the batch contains only deliveries that may be sent. No APNs or FCM client ships
here: APNs needs HTTP/2 with token authentication and FCM HTTP v1 needs OAuth2
service-account tokens, both held by the deployment, which supplies a
``PushTransport``. Development and test environments use ``SinkTransport``, which
records what would have been sent and never contacts a device.
"""
from __future__ import annotations

from typing import List, Protocol, Tuple

from ..publishing.worker import JobAPI

PERMANENT_FAILURES = ("Unregistered", "BadDeviceToken", "unregistered", "invalid_token")


class AnnouncementAPI(JobAPI):
    PREFIX = "sdi_announcement_"
    PERMITTED = frozenset({"claim", "finish"})


class PushTransport(Protocol):
    def send(self, platform: str, environment: str, token: str, title: str, body: str) -> Tuple[bool, str]:
        """Return ``(ok, reason)``. ``reason`` for a permanent token failure must be
        one of PERMANENT_FAILURES so the database revokes the device."""


class SinkTransport:
    """Records sends; optional scripted failures keyed by token."""

    def __init__(self, failures=None):
        self.sent: List[dict] = []
        self.failures = dict(failures or {})

    def send(self, platform, environment, token, title, body):
        self.sent.append({"platform": platform, "environment": environment, "token_suffix": token[-6:], "title": title, "body": body})
        if token in self.failures:
            return False, self.failures[token]
        return True, ""


class PushBatchWorker:
    def __init__(self, api: AnnouncementAPI, transport: PushTransport, batch: int = 500):
        if not 1 <= batch <= 1000:
            raise ValueError("batch must be 1..1000")
        self.api = api
        self.transport = transport
        self.batch = batch

    def run_once(self) -> dict:
        claimed = self.api.call("claim", batch=self.batch)
        if claimed.get("empty"):
            return {"state": "idle"}
        results = []
        for delivery in claimed.get("deliveries", []):
            try:
                ok, reason = self.transport.send(delivery["platform"], delivery["environment"], delivery["token"], delivery["title"], delivery["body"])
            except Exception:
                ok, reason = False, "transport error"
            results.append({"delivery": delivery["delivery"], "ok": bool(ok), "reason": "" if ok else str(reason)[:200]})
        finish = self.api.call("finish", results=results) if results else {"sent": 0, "failed": 0}
        return {"state": "complete" if claimed.get("complete") else "batch", "announcement": claimed.get("announcement"),
                "attempted": len(results), "sent": finish.get("sent", 0), "failed": finish.get("failed", 0)}

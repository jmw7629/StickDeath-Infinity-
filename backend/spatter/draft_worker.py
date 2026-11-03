"""One explicitly invoked daily draft pass on the trusted render host."""
from __future__ import annotations

import datetime as dt
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Mapping

from .draft_preview import DraftPreviewStore
from .draft_queue import (CAPACITY_NOT_CONFIGURED, DRAFT_PLAN_CHANGED, DRAFT_QUALITY_FAILED,
                          DRAFT_QUALITY_INCOMPLETE, DRAFT_RENDER_FAILED, DRAFT_STOPPED, RunOutcome, run_once)
from .draft_rpc_transport import BoundedRPCOpener, MAX_RESPONSE_BYTES, RPC_NAMES, RPC_WALL_SECONDS
from .renderer_cli import CLIRenderer

_DRAFT_LEASE_SECONDS = 15 * 60
_ITEM_CAP_REFUSAL = "The agent did not authorize a daily draft item."
_FAILURE_REASONS = frozenset({CAPACITY_NOT_CONFIGURED, DRAFT_PLAN_CHANGED, DRAFT_QUALITY_FAILED,
                              DRAFT_QUALITY_INCOMPLETE, DRAFT_RENDER_FAILED, DRAFT_STOPPED, _ITEM_CAP_REFUSAL})


class DraftServiceError(RuntimeError):
    """Sanitized error. An unconfirmed RPC must not be retried by this pass."""


def validate_draft_https_origin(origin: str) -> str:
    """Check raw origin text before URL parsing can normalize whitespace."""
    if (not isinstance(origin, str) or not 1 <= len(origin) <= 2048
            or any(not 33 <= ord(char) <= 126 for char in origin)):
        raise ValueError("Configure an authorized HTTPS origin.")
    parsed = urllib.parse.urlsplit(origin)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None or parsed.password is not None
            or "?" in origin or "#" in origin or "\\" in origin
            or parsed.path not in ("", "/") or parsed.port not in (None, 443)):
        raise ValueError("Configure an authorized HTTPS origin.")
    return f"https://{parsed.netloc}"


def validate_draft_backend(backend_url: str, server_secret_key: str) -> str:
    """Validate private host settings without opening a connection."""
    origin = validate_draft_https_origin(backend_url)
    if not isinstance(server_secret_key, str) or not re.fullmatch(r"sb_secret_[A-Za-z0-9_-]{1,500}", server_secret_key):
        raise ValueError("A server-only Supabase secret API key is required.")
    return origin


def _uuid(value: Any) -> str:
    try:
        return str(uuid.UUID(value))
    except (TypeError, ValueError, AttributeError):
        raise DraftServiceError("Daily draft service returned an invalid record ID.") from None


class DraftRPCStore:
    """Service-only adapter for the existing Supabase draft and agent RPCs.

    Each store owns one pass. The draft lease is fixed after the initial
    `rendering` transition. Agent heartbeat is a separate pause/stop check.
    """

    def __init__(self, backend_url: str, server_secret_key: str, *, clock=time.monotonic, opener=None):
        self._origin = validate_draft_backend(backend_url, server_secret_key)
        self._key = server_secret_key
        self._clock = clock
        self._opener = opener if opener is not None else BoundedRPCOpener()
        self._claimed = False
        self._item_allowed = False
        self._identity: tuple[str, str, str] | None = None
        self._deadline: float | None = None

    def _rpc(self, name: str, payload: dict, *, timeout: float = RPC_WALL_SECONDS) -> Any:
        if name not in RPC_NAMES:
            raise ValueError("Unsupported daily draft operation.")
        request = urllib.request.Request(
            f"{self._origin}/rest/v1/rpc/{name}", method="POST", data=json.dumps(payload, allow_nan=False).encode(),
            headers={"apikey": self._key, "Content-Type": "application/json"},
        )
        try:
            with self._opener.open(request, timeout=timeout) as response:
                raw = response.read(MAX_RESPONSE_BYTES + 1)
            if len(raw) > MAX_RESPONSE_BYTES:
                raise ValueError("RPC response exceeded its bound.")
            return json.loads(raw)
        except urllib.error.HTTPError as error:
            self._identity = None
            if error.code in (401, 403):
                raise DraftServiceError("Daily draft service authorization was refused.") from None
            raise DraftServiceError("Daily draft service did not confirm the operation.") from None
        except (OSError, ValueError):
            self._identity = None
            raise DraftServiceError("Daily draft service did not confirm the operation.") from None

    def claim(self, target_date: dt.date, owner: str, seed: int, version: str, brief: Mapping[str, Any]) -> Mapping[str, Any]:
        if self._claimed:
            raise DraftServiceError("A daily draft store can claim only one pass.")
        self._claimed = True
        result = self._rpc("sdi_spatter_draft_claim", {"p_date": target_date.isoformat(), "p_owner": owner,
                           "p_seed": seed, "p_brief_version": version, "p_brief": dict(brief)})
        if not isinstance(result, dict) or type(result.get("claimed")) is not bool:
            raise DraftServiceError("Daily draft service returned an invalid claim.")
        if result["claimed"]:
            if (type(result.get("attempt")) is not int or not 1 <= result["attempt"] <= 3
                    or type(result.get("planner_seed")) is not int or not isinstance(result.get("brief"), dict)):
                raise DraftServiceError("Daily draft service returned an incomplete claim.")
            result = {**result, "job": _uuid(result.get("job"))}
            self._identity = (result["job"], owner, _uuid(result.get("run")))
            item_cap = result.get("per_run_item_cap")
            self._item_allowed = type(item_cap) is int and 1 <= item_cap <= 10_000
        return result

    def _lease_live(self) -> bool:
        if self._identity is None or self._deadline is None:
            return False
        remaining = self._deadline - self._clock()
        return (remaining > 0 and self._rpc("sdi_agent_run_heartbeat", {"run": self._identity[2]},
                                            timeout=min(RPC_WALL_SECONDS, remaining)) is True
                and self._clock() < self._deadline)

    def progress(self, job: str, owner: str, state: str, *, storyboard=None, quality=None,
                 sha256=None, error="", review=None) -> Mapping[str, Any]:
        if self._identity is None or self._identity[:2] != (job, owner):
            return {"status": "refused", "reason": "This pass does not own the draft claim."}
        if state not in ("rendering", "failed", "review_pending"):
            raise ValueError("Unsupported daily draft state.")
        if state == "rendering" and self._deadline is not None:
            if not self._lease_live():
                return {"status": "refused", "reason": "The draft lease ended or the agent was stopped."}
            return {"status": "confirmed", "state": "rendering"}
        if state == "review_pending":
            if not self._lease_live():
                return {"status": "refused", "reason": "The draft lease ended or the agent was stopped."}
            if not isinstance(review, Mapping) or not {"object_key", "byte_count", "artifact_expires_at"} <= review.keys():
                return {"status": "refused", "reason": "Owner review requires a retained private preview."}
        cap_refused = state == "rendering" and not self._item_allowed
        if cap_refused:
            state, error = "failed", _ITEM_CAP_REFUSAL
        if state == "failed":
            error = error if error in _FAILURE_REASONS else DRAFT_RENDER_FAILED
        else:
            error = ""
        started = self._clock()
        result = self._rpc("sdi_spatter_draft_progress", {"p_job": job, "p_owner": owner, "p_state": state,
                           "p_storyboard": storyboard, "p_quality": quality, "p_sha": sha256, "p_error": error, "p_review": review})
        if not isinstance(result, dict) or result.get("status") not in ("confirmed", "refused"):
            raise DraftServiceError("Daily draft service returned an invalid progress receipt.")
        if result["status"] == "confirmed":
            if result.get("state") != state:
                raise DraftServiceError("Daily draft service returned a different state.")
            if state == "rendering":
                # Starting before the HTTP request is conservative: SQL sets its
                # lease only after the request reaches the database.
                self._deadline = started + _DRAFT_LEASE_SECONDS
            else:
                self._identity = None
                if state == "review_pending":
                    result = {**result, "review": _uuid(result.get("review"))}
        if cap_refused:
            return {"status": "refused", "reason": _ITEM_CAP_REFUSAL}
        return result


def run_daily_draft_once(*, backend_url: str, server_secret_key: str, renderer: CLIRenderer) -> RunOutcome:
    """Run one UTC day after the host injects its private renderer and credential.

    The verified preview store supplies the same owner ID used to sign its URL.
    This worker can submit a private review record, and has no release operation.
    """
    if not isinstance(renderer, CLIRenderer) or not isinstance(renderer.publish_preview, DraftPreviewStore):
        raise ValueError("Configure the native draft renderer and retained owner preview store first.")
    if renderer.timeout <= RPC_WALL_SECONDS:
        raise ValueError("The production render timeout must exceed one draft service request.")
    return run_once(DraftRPCStore(backend_url, server_secret_key), owner=f"daily-draft-{uuid.uuid4()}",
                    reviewer=renderer.publish_preview.owner, now=lambda: dt.datetime.now(dt.timezone.utc),
                    renderer=renderer, safe_diagnostics=True)

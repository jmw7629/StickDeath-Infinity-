"""Spatter cloud-advice request handler (contract implementation, no provider calls).

This is the server side of the versioned, provider-neutral contract that
``StickDeathInfinity/App/SpatterBackendClient.swift`` speaks:

    request  {schemaVersion: 1, messages: [{role, content}], suggestedPromptId?, max_tokens?, temperature?}
    response {schemaVersion: 1, reply, usage: {units}, budget: {remaining, resetsAt}}

The handler is framework-free and standard-library only. Deployment wires it to
an HTTPS edge/function runtime and injects three collaborators:

* ``verify_jwt``  – verifies the Supabase access token (RS256/ES256 via the
  project JWKS, or HS256 with the legacy JWT secret) and returns the claims. It
  must check ``exp``, ``aud == "authenticated"`` and the issuer. The handler
  never decodes a token without verification and never logs it.
* ``budget``      – per-user daily allowance backed by the ``spatter_daily_budget``
  table (see README). ``reserve(user_id)`` atomically decrements and returns the
  remaining count or ``None`` when exhausted; ``release(user_id)`` refunds a
  reservation when the provider call did not happen.
* ``provider``    – any object with ``complete(messages) -> (reply, units)``.
  ``NullProvider`` is the default and answers 503 "not configured". In a
  deployment it is a ``providers.ProviderRouter`` (model switch, per-attempt
  timeout, bounded retries). No paid provider is referenced here; the owner
  selects and configures one privately.
* ``meter``       – optional ``metering.Meter`` (``SqlMeter`` over
  ``public.sdi_spatter_usage_meter``). When given it replaces ``budget`` and
  enforces plan allowances, rate, daily safety cap, global ceiling and the
  emergency stop, settling each reservation exactly once.

Nothing in this module starts a server, reads secrets or contacts a provider.
"""
from __future__ import annotations

import datetime as _dt
import json
from dataclasses import dataclass
from typing import Any, Callable, Mapping, Optional, Protocol, Sequence, Tuple

from .metering import Decision, Meter
from . import suggested_prompts
from .providers import ProviderRouter, ProviderUnavailable  # noqa: F401  (ProviderRouter is the deployment provider)

SCHEMA_VERSION = 1
MAX_BODY_BYTES = 128 * 1024
MAX_MESSAGES = 41
MAX_CONTENT_BYTES = 32_768
MAX_REPLY_BYTES = 32_768
ROLES = ("system", "user", "assistant")


class HandlerError(Exception):
    """Carries an HTTP status and a short public reason; never provider detail."""

    def __init__(self, status: int, reason: str, **extra: Any):
        super().__init__(reason)
        self.status = status
        self.reason = reason
        # Public, non-sensitive fields only (code, retryAfterSeconds, allowance, upgrade).
        self.extra = extra


class Provider(Protocol):
    name: str

    def complete(self, messages: Sequence[Mapping[str, str]]) -> Tuple[str, int]:
        """Return (reply_text, usage_units). Raise ProviderUnavailable on failure."""




class NullProvider:
    """Default: the deployment has not configured a provider. Always 503."""

    name = "none"

    def complete(self, messages: Sequence[Mapping[str, str]]) -> Tuple[str, int]:
        raise HandlerError(503, "not configured")


class Budget(Protocol):
    def reserve(self, user_id: str) -> Optional[Tuple[int, _dt.datetime]]:
        """Atomically consume one unit. Returns (remaining, resets_at) or None when exhausted."""

    def release(self, user_id: str) -> None:
        """Refund the unit reserved by the most recent reserve() for this user."""


@dataclass
class Response:
    status: int
    body: dict

    def json(self) -> str:
        return json.dumps(self.body, separators=(",", ":"), sort_keys=True)


def _iso(when: _dt.datetime) -> str:
    if when.tzinfo is None:
        when = when.replace(tzinfo=_dt.timezone.utc)
    return when.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _bearer(headers: Mapping[str, str]) -> str:
    value = ""
    for key, item in headers.items():
        if key.lower() == "authorization":
            value = item
            break
    if not value.startswith("Bearer "):
        raise HandlerError(401, "missing bearer token")
    token = value[len("Bearer "):].strip()
    if not token or len(token.encode()) > 16_384 or not all(32 < ord(c) < 127 for c in token):
        raise HandlerError(401, "invalid bearer token")
    return token


def _parse_request(raw: bytes) -> Tuple[list, Optional[str]]:
    if len(raw) > MAX_BODY_BYTES:
        raise HandlerError(413, "request too large")
    try:
        body = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise HandlerError(400, "malformed json") from None
    if not isinstance(body, dict):
        raise HandlerError(400, "malformed request")
    version = body.get("schemaVersion", 0)
    # schemaVersion absent/0 is the legacy client; 1 is current. Anything newer is refused.
    if version not in (0, 1):
        raise HandlerError(400, "unsupported schemaVersion")
    messages = body.get("messages")
    if not isinstance(messages, list) or not messages or len(messages) > MAX_MESSAGES:
        raise HandlerError(400, "invalid messages")
    cleaned = []
    for item in messages:
        if not isinstance(item, dict):
            raise HandlerError(400, "invalid message")
        role, content = item.get("role"), item.get("content")
        if role not in ROLES or not isinstance(content, str) or not content.strip() \
                or len(content.encode("utf-8")) > MAX_CONTENT_BYTES:
            raise HandlerError(400, "invalid message")
        cleaned.append({"role": role, "content": content})
    if cleaned[-1]["role"] != "user":
        raise HandlerError(400, "last message must be from the user")
    try:
        suggested = suggested_prompts.validate_id(body.get("suggestedPromptId"))
    except ValueError:
        raise HandlerError(400, "unknown suggested prompt", code="unknown_suggested_prompt") from None
    return cleaned, suggested


def _user_id(claims: Mapping[str, Any]) -> str:
    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub or claims.get("aud") not in ("authenticated", ["authenticated"]):
        raise HandlerError(401, "unauthorized")
    if claims.get("role") not in (None, "authenticated"):
        # Service-role or anon keys are never valid for a user advice request.
        raise HandlerError(403, "forbidden role")
    return sub


def handle(headers: Mapping[str, str], raw_body: bytes, *,
           verify_jwt: Callable[[str], Mapping[str, Any]],
           budget: Optional[Budget] = None,
           meter: Optional[Meter] = None,
           provider: Provider = NullProvider(),
           now: Callable[[], _dt.datetime] = lambda: _dt.datetime.now(_dt.timezone.utc)) -> Response:
    """Process one POST. Errors are JSON with the same schemaVersion and a `error` field."""
    try:
        token = _bearer(headers)
        try:
            claims = verify_jwt(token)
        except HandlerError:
            raise
        except Exception:
            raise HandlerError(401, "unauthorized") from None
        user_id = _user_id(claims)
        exp = claims.get("exp")
        if not isinstance(exp, (int, float)) or exp <= now().timestamp():
            raise HandlerError(401, "token expired")
        messages, suggested = _parse_request(raw_body)
        # Provider readiness is checked before a unit is consumed: an unconfigured
        # deployment must not drain anyone's daily budget.
        if isinstance(provider, NullProvider) or getattr(provider, "configured", True) is False:
            raise HandlerError(503, "not configured")
        if meter is not None:
            return _metered(user_id, messages, suggested, meter, provider)
        if budget is None:
            raise HandlerError(503, "not configured")
        reservation = budget.reserve(user_id)
        if reservation is None:
            raise HandlerError(429, "daily budget exhausted")
        remaining, resets_at = reservation
        try:
            reply, units = provider.complete(messages)
        except HandlerError:
            budget.release(user_id)
            raise
        except ProviderUnavailable:
            budget.release(user_id)
            raise HandlerError(502, "provider unavailable") from None
        except Exception:
            budget.release(user_id)
            raise HandlerError(502, "provider unavailable") from None
        if not isinstance(reply, str) or not reply.strip():
            budget.release(user_id)
            raise HandlerError(502, "empty provider reply")
        if len(reply.encode("utf-8")) > MAX_REPLY_BYTES:
            reply = reply.encode("utf-8")[:MAX_REPLY_BYTES].decode("utf-8", "ignore")
        units = int(units) if isinstance(units, (int, float)) and units >= 0 else 0
        return Response(200, {
            "schemaVersion": SCHEMA_VERSION,
            "reply": reply,
            "usage": {"units": units},
            "budget": {"remaining": int(remaining), "resetsAt": _iso(resets_at)},
        })
    except HandlerError as error:
        body = {"schemaVersion": SCHEMA_VERSION, "error": error.reason}
        body.update(error.extra)
        return Response(error.status, body)


UPGRADE_MESSAGE = "Spatter is part of Creator and Pro, or buy Spatter credits to pay as you go."

# Metered refusals: HTTP status, public reason. 429 keeps the existing client's
# "try later / allowance used" message; 503 keeps its "unavailable" message.
_REFUSALS = {
    "unauthorized": (401, "unauthorized"),
    "account_restricted": (403, "account restricted"),
    "emergency_stop": (503, "paused by the operator"),
    "global_limit": (503, "service limit reached for today"),
    "rate_limited": (429, "too many requests"),
    "daily_safety_limit": (429, "daily safety limit reached"),
    "plan_allowance_exhausted": (429, "plan allowance used"),
    # Free without Spatter credits (owner decisions 2026-10-15). 402 is distinct
    # from the 403 the client reads as "not authorized".
    "upgrade_required": (402, UPGRADE_MESSAGE),
    "unknown_suggested_prompt": (400, "unknown suggested prompt"),
    "unavailable": (503, "metering unavailable"),
}


def _allowance(decision: Decision) -> dict:
    """Plan allowance and credit balance for the client. ``remaining`` is null
    for an unlimited plan; ``resetsAt`` is the renewal date (Creator); never a
    guess. ``funding`` says whether this prompt used the plan or one credit."""
    return {
        "plan": decision.plan,
        "period": decision.period,
        "remaining": decision.remaining,
        "resetsAt": _iso(decision.resets_at) if decision.resets_at else None,
        "credits": decision.credits,
        "funding": decision.funding,
    }


def _metered(user_id: str, messages: list, suggested: Optional[str], meter: Meter, provider: Provider) -> Response:
    try:
        decision = meter.reserve(user_id) if suggested is None else meter.reserve(user_id, suggested_prompt=suggested)
    except Exception:
        raise HandlerError(503, "metering unavailable", code="unavailable") from None
    if not decision.allowed or not decision.reservation:
        status, reason = _REFUSALS.get(decision.code, _REFUSALS["unavailable"])
        extra: dict = {"code": decision.code if decision.code in _REFUSALS else "unavailable"}
        if decision.retry_after_seconds:
            extra["retryAfterSeconds"] = decision.retry_after_seconds
        if decision.code in ("plan_allowance_exhausted", "daily_safety_limit"):
            extra["allowance"] = {"plan": decision.plan, "period": decision.period, "remaining": 0 if decision.plan else None,
                                  "resetsAt": _iso(decision.resets_at) if decision.resets_at else None}
        if decision.upgrade:
            extra["upgrade"] = decision.upgrade
        if decision.code == "upgrade_required":
            extra["plan"] = "free"
        if decision.buy_credits:
            extra["buyCredits"] = True
            extra["credits"] = decision.credits or 0
        raise HandlerError(status, reason, **extra)

    def release() -> None:
        try:
            meter.settle(decision.reservation, "release")
        except Exception:
            pass  # An unsettled reservation stays counted; the SQL sweep never refunds silently.

    if decision.plan not in ("creator", "pro") and decision.funding != "credit":
        # The meter must have refused: Free is sent to the provider only on a credit.
        release()
        raise HandlerError(402, UPGRADE_MESSAGE, code="upgrade_required", plan="free", upgrade="creator_or_pro",
                           buyCredits=True, credits=0)
    try:
        reply, units = provider.complete(messages)
    except HandlerError:
        release()
        raise
    except ProviderUnavailable as error:
        release()
        raise HandlerError(502, "provider unavailable", code="provider_unavailable",
                           retryable=bool(getattr(error, "transient", False))) from None
    except Exception:
        release()
        raise HandlerError(502, "provider unavailable", code="provider_unavailable", retryable=False) from None
    if not isinstance(reply, str) or not reply.strip():
        release()
        raise HandlerError(502, "empty provider reply", code="provider_unavailable", retryable=True)
    if len(reply.encode("utf-8")) > MAX_REPLY_BYTES:
        reply = reply.encode("utf-8")[:MAX_REPLY_BYTES].decode("utf-8", "ignore")
    units = int(units) if isinstance(units, (int, float)) and not isinstance(units, bool) and units >= 0 else 0
    try:
        meter.settle(decision.reservation, "commit", units)
    except Exception:
        pass  # The reply was produced and the prompt stays counted.
    # `budget` stays the legacy daily shape the current client renders as
    # "Remaining today"; metered plans use `allowance` so no period is mislabelled.
    return Response(200, {
        "schemaVersion": SCHEMA_VERSION,
        "reply": reply,
        "usage": {"units": units},
        "allowance": _allowance(decision),
    })


class InMemoryBudget:
    """Legacy per-user daily budget (pre-#209 contract). Deployments use `meter=`
    (metering.SqlMeter) instead. Suitable for tests and single-process previews only."""

    def __init__(self, daily_limit: int, now: Callable[[], _dt.datetime]):
        if daily_limit < 0:
            raise ValueError("daily_limit must be non-negative")
        self.daily_limit = daily_limit
        self.now = now
        self._used: dict = {}

    def _day(self) -> _dt.date:
        return self.now().astimezone(_dt.timezone.utc).date()

    def _resets_at(self) -> _dt.datetime:
        return _dt.datetime.combine(self._day() + _dt.timedelta(days=1), _dt.time(), tzinfo=_dt.timezone.utc)

    def reserve(self, user_id: str):
        key = (user_id, self._day())
        used = self._used.get(key, 0)
        if used >= self.daily_limit:
            return None
        self._used[key] = used + 1
        return self.daily_limit - used - 1, self._resets_at()

    def release(self, user_id: str) -> None:
        key = (user_id, self._day())
        if self._used.get(key, 0) > 0:
            self._used[key] -= 1

    def remaining(self, user_id: str) -> int:
        return self.daily_limit - self._used.get((user_id, self._day()), 0)

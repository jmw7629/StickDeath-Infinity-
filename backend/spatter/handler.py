"""Spatter cloud-advice request handler (contract implementation, no provider calls).

This is the server side of the versioned, provider-neutral contract that
``StickDeathInfinity/App/SpatterBackendClient.swift`` speaks:

    request  {schemaVersion: 1, messages: [{role, content}], max_tokens?, temperature?}
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
  ``NullProvider`` is the default and answers 503 "not configured". No paid
  provider is referenced here; the owner selects and configures one privately.

Nothing in this module starts a server, reads secrets or contacts a provider.
"""
from __future__ import annotations

import datetime as _dt
import json
from dataclasses import dataclass
from typing import Any, Callable, Mapping, Optional, Protocol, Sequence, Tuple

SCHEMA_VERSION = 1
MAX_BODY_BYTES = 128 * 1024
MAX_MESSAGES = 41
MAX_CONTENT_BYTES = 32_768
MAX_REPLY_BYTES = 32_768
ROLES = ("system", "user", "assistant")


class HandlerError(Exception):
    """Carries an HTTP status and a short public reason; never provider detail."""

    def __init__(self, status: int, reason: str):
        super().__init__(reason)
        self.status = status
        self.reason = reason


class Provider(Protocol):
    name: str

    def complete(self, messages: Sequence[Mapping[str, str]]) -> Tuple[str, int]:
        """Return (reply_text, usage_units). Raise ProviderUnavailable on failure."""


class ProviderUnavailable(Exception):
    pass


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


def _parse_request(raw: bytes) -> list:
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
    return cleaned


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
           budget: Budget,
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
        messages = _parse_request(raw_body)
        # Provider readiness is checked before a unit is consumed: an unconfigured
        # deployment must not drain anyone's daily budget.
        if isinstance(provider, NullProvider):
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
        return Response(error.status, {"schemaVersion": SCHEMA_VERSION, "error": error.reason})


class InMemoryBudget:
    """Reference implementation of the per-user daily budget semantics used by the
    SQL table. Suitable for tests and single-process previews only."""

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

"""Server-side Spatter prompt metering (#209). Standard library only.

The handler asks a ``Meter`` to reserve one prompt before any provider call and
settles the reservation exactly once afterwards: ``commit`` with the provider's
usage units when a reply was delivered, ``release`` (full refund) when the
provider failed. The device never counts its own allowance.

``SqlMeter`` speaks the service-only RPC ``public.sdi_spatter_usage_meter``
defined in ``backend/sql/spatter-draft-jobs.sql``. ``InMemoryMeter`` implements
the same rules for tests and single-process previews:

* emergency stop (``sdi_private.agent_global``) refuses everything;
* a global daily ceiling, closed (0) until the owner sets it;
* a per-account per-minute rate and a per-account daily safety cap;
* plan allowances from the owner's 2026-10-07 decisions: ``free`` 5 prompts
  treated as one-time, ``creator`` (USD 4.99) 15 per billing period keyed to
  the subscription's paid-through date, ``pro`` (USD 9.99) no plan allowance.

Nothing here reads a secret, contacts a provider or decides an entitlement: the
plan comes from the server-side entitlement view, never from the request.
"""
from __future__ import annotations

import datetime as _dt
import uuid as _uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Mapping, Optional, Protocol, Tuple

PLANS = ("free", "creator", "pro")
REFUSAL_CODES = (
    "unauthorized", "account_restricted", "emergency_stop", "global_limit",
    "rate_limited", "daily_safety_limit", "plan_allowance_exhausted",
)


@dataclass(frozen=True)
class Decision:
    """Outcome of one reservation attempt. ``remaining`` is None for an
    unlimited plan; ``resets_at`` is None for a one-time allowance."""

    allowed: bool
    code: str = ""
    reservation: Optional[str] = None
    plan: Optional[str] = None
    period: Optional[str] = None
    remaining: Optional[int] = None
    resets_at: Optional[_dt.datetime] = None
    retry_after_seconds: Optional[int] = None
    upgrade: Optional[str] = None


class Meter(Protocol):
    def reserve(self, user_id: str) -> Decision: ...

    def settle(self, reservation: str, outcome: str, units: int = 0) -> bool: ...


def _parse_time(value: Any) -> Optional[_dt.datetime]:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = _dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=_dt.timezone.utc)


def decision_from_rpc(payload: Mapping[str, Any]) -> Decision:
    """Strictly decode the SQL function's JSON. Anything unexpected is treated
    as a refusal rather than as permission."""
    if not isinstance(payload, Mapping) or payload.get("allowed") is not True:
        code = payload.get("code") if isinstance(payload, Mapping) else None
        retry = payload.get("retry_after_seconds") if isinstance(payload, Mapping) else None
        return Decision(
            allowed=False,
            code=code if code in REFUSAL_CODES else "unavailable",
            plan=payload.get("plan") if isinstance(payload, Mapping) and payload.get("plan") in PLANS else None,
            period=payload.get("period") if isinstance(payload, Mapping) and isinstance(payload.get("period"), str) else None,
            resets_at=_parse_time(payload.get("resets_at")) if isinstance(payload, Mapping) else None,
            retry_after_seconds=retry if isinstance(retry, int) and 0 < retry <= 3600 else None,
            upgrade=payload.get("upgrade") if isinstance(payload, Mapping) and payload.get("upgrade") in ("pro", "creator_or_pro") else None,
        )
    reservation = payload.get("reservation")
    plan = payload.get("plan")
    remaining = payload.get("remaining")
    if not isinstance(reservation, str) or plan not in PLANS:
        return Decision(allowed=False, code="unavailable")
    if remaining is not None and not (isinstance(remaining, int) and remaining >= 0):
        return Decision(allowed=False, code="unavailable")
    if plan == "pro":
        remaining = None
    elif remaining is None:
        return Decision(allowed=False, code="unavailable")
    return Decision(allowed=True, reservation=reservation, plan=plan,
                    period=payload.get("period") if isinstance(payload.get("period"), str) else None,
                    remaining=remaining, resets_at=_parse_time(payload.get("resets_at")))


class SqlMeter:
    """Adapter over ``public.sdi_spatter_usage_meter`` called with the service
    role. ``rpc(function_name, params) -> dict`` is injected by the deployment."""

    FUNCTION = "sdi_spatter_usage_meter"

    def __init__(self, rpc: Callable[[str, Dict[str, Any]], Mapping[str, Any]]):
        self._rpc = rpc

    def reserve(self, user_id: str) -> Decision:
        return decision_from_rpc(self._rpc(self.FUNCTION, {"action": "reserve", "p_user": user_id}))

    def settle(self, reservation: str, outcome: str, units: int = 0) -> bool:
        if outcome not in ("commit", "release"):
            raise ValueError("outcome must be commit or release")
        result = self._rpc(self.FUNCTION, {"action": "settle", "p_reservation": reservation,
                                           "p_outcome": outcome, "p_units": max(0, int(units))})
        return isinstance(result, Mapping) and result.get("status") == "confirmed"


@dataclass
class Controls:
    global_daily_cap: int = 0
    user_daily_safety_cap: int = 100
    user_per_minute_cap: int = 6
    free_prompts: int = 5
    creator_period_prompts: int = 15
    emergency_stop: bool = False


@dataclass
class _Reservation:
    user_id: str
    buckets: List[str]
    day: _dt.date
    state: str = "reserved"
    units: int = 0


@dataclass
class InMemoryMeter:
    """Reference implementation of the SQL rules. ``entitlement(user_id)``
    returns ``(tier, paid_through)`` or None for free; ``account_state(user_id)``
    returns 'active', 'suspended', 'banned' or None for an unknown account."""

    now: Callable[[], _dt.datetime]
    entitlement: Callable[[str], Optional[Tuple[str, _dt.datetime]]] = lambda _user: None
    account_state: Callable[[str], Optional[str]] = lambda _user: "active"
    controls: Controls = field(default_factory=Controls)
    counters: Dict[Tuple[str, str], int] = field(default_factory=dict)
    global_used: Dict[_dt.date, int] = field(default_factory=dict)
    reservations: Dict[str, _Reservation] = field(default_factory=dict)

    def _utc(self) -> _dt.datetime:
        return self.now().astimezone(_dt.timezone.utc)

    def plan(self, user_id: str) -> Dict[str, Any]:
        ent = self.entitlement(user_id)
        if ent and ent[0] == "pro":
            return {"plan": "pro", "unlimited": True, "remaining": None, "period": "none", "resets_at": None, "bucket": None}
        if ent and ent[0] == "creator":
            paid = ent[1].astimezone(_dt.timezone.utc)
            bucket, limit = "period:" + paid.strftime("%Y-%m-%dT%H:%M:%SZ"), self.controls.creator_period_prompts
            period, resets = "billing_period", paid
        else:
            bucket, limit, period, resets = "free", self.controls.free_prompts, "one_time", None
        used = self.counters.get((user_id, bucket), 0)
        return {"plan": "creator" if bucket != "free" else "free", "unlimited": False, "limit": limit, "used": used,
                "remaining": max(limit - used, 0), "period": period, "resets_at": resets, "bucket": bucket}

    def reserve(self, user_id: str) -> Decision:
        state = self.account_state(user_id)
        if state is None:
            return Decision(False, "unauthorized")
        if state != "active":
            return Decision(False, "account_restricted")
        if self.controls.emergency_stop:
            return Decision(False, "emergency_stop")
        now = self._utc()
        day = now.date()
        if self.global_used.get(day, 0) >= self.controls.global_daily_cap:
            return Decision(False, "global_limit")
        minute = "minute:" + now.strftime("%Y-%m-%dT%H:%M")
        if self.counters.get((user_id, minute), 0) >= self.controls.user_per_minute_cap:
            return Decision(False, "rate_limited", retry_after_seconds=max(1, 60 - now.second))
        day_bucket = "day:" + day.isoformat()
        if self.counters.get((user_id, day_bucket), 0) >= self.controls.user_daily_safety_cap:
            resets = _dt.datetime.combine(day + _dt.timedelta(days=1), _dt.time(), tzinfo=_dt.timezone.utc)
            return Decision(False, "daily_safety_limit", resets_at=resets)
        plan = self.plan(user_id)
        if not plan["unlimited"] and plan["remaining"] <= 0:
            return Decision(False, "plan_allowance_exhausted", plan=plan["plan"], period=plan["period"],
                            resets_at=plan["resets_at"], upgrade="creator_or_pro" if plan["plan"] == "free" else "pro")
        buckets = [minute, day_bucket] + ([plan["bucket"]] if plan["bucket"] else [])
        for bucket in buckets:
            self.counters[(user_id, bucket)] = self.counters.get((user_id, bucket), 0) + 1
        self.global_used[day] = self.global_used.get(day, 0) + 1
        rid = str(_uuid.uuid4())
        self.reservations[rid] = _Reservation(user_id, buckets, day)
        return Decision(True, reservation=rid, plan=plan["plan"], period=plan["period"],
                        remaining=None if plan["unlimited"] else plan["remaining"] - 1, resets_at=plan["resets_at"])

    def settle(self, reservation: str, outcome: str, units: int = 0) -> bool:
        if outcome not in ("commit", "release") or units < 0:
            return False
        item = self.reservations.get(reservation)
        if item is None or item.state != "reserved":
            return False
        if outcome == "release":
            for bucket in item.buckets:
                key = (item.user_id, bucket)
                self.counters[key] = max(self.counters.get(key, 0) - 1, 0)
            self.global_used[item.day] = max(self.global_used.get(item.day, 0) - 1, 0)
            item.state = "released"
        else:
            item.state, item.units = "committed", units
        return True

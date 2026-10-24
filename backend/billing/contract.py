"""Shared contract pieces for the billing edge-function candidates.

Nothing here contacts a provider, reads a secret or opens a connection. The
three handlers (``appstore_notifications``, ``stripe_webhook``,
``stripe_checkout``) map verified provider payloads onto one database call,
``public.sdi_billing_apply_event(...)`` from ``backend/sql/billing.sql``, through
an injected executor. The executor is the only thing that touches PostgreSQL and
the deployment supplies it (service role, PostgREST ``rpc`` or a direct
connection). Tests use a recording fake.

Approved offers are the owner's three monthly tiers (decision 2026-10-20:
creator, pro, unlimited; rank unlimited > pro > creator), each with a 3-day
free trial. No amount is stored or
embedded anywhere in this package: prices live in App Store Connect and the
Stripe dashboard, and Stripe line items reference configured price ids only.
"""
from __future__ import annotations

import datetime as _dt
import json
import re
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

PROVIDERS = ("apple", "stripe")
TIERS = ("creator", "pro", "unlimited")
# Owner decisions 2026-10-14 and 2026-10-20: every paid tier starts with a
# free trial (3 days, App Store introductory offer). A provider-reported trial
# maps to the canonical ``trialing`` status and ``in_trial=True``. The
# entitlement view grants the tier (the Studio is unlocked), but the Spatter
# meter funds no prompt while the account's only entitlements are in a trial.
# Trial length and eligibility are store configuration (App Store introductory
# offer; Stripe trial settings), never embedded here.
TRIAL_TIERS = TIERS
PERIODS = ("monthly", "annual")
CANONICAL_STATUSES = ("active", "trialing", "grace", "past_due", "cancelled", "expired", "revoked", "refunded")
LEDGER_KINDS = ("charge", "refund", "fee", "payout", "adjustment")
APPLY_EVENT_RPC = "sdi_billing_apply_event"

_UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_CURRENCY_RE = re.compile(r"^[A-Z]{3}$")


class ContractError(Exception):
    """Carries an HTTP status and a short public reason. Never provider detail."""

    def __init__(self, status: int, reason: str):
        super().__init__(reason)
        self.status = status
        self.reason = reason


@dataclass(frozen=True)
class ApprovedProduct:
    """One product identifier the owner approved. ``product_id`` is the value
    stored in ``sdi_private.billing_products``; for Apple it is the App Store
    Connect product id, for Stripe it is the internal id that ``stripe_price_id``
    (a ``price_...`` id from the dashboard) is bound to. No amount is carried."""

    product_id: str
    provider: str
    tier: str
    period: str
    stripe_price_id: Optional[str] = None
    owner_configured: bool = False

    def __post_init__(self):
        if not self.product_id or len(self.product_id) > 200:
            raise ValueError("product_id must be 1..200 characters")
        if self.provider not in PROVIDERS:
            raise ValueError("provider must be apple or stripe")
        if self.tier not in TIERS:
            raise ValueError("tier must be creator, pro or unlimited")
        if self.period not in PERIODS:
            raise ValueError("period must be monthly or annual")
        if self.period == "annual" and not self.owner_configured:
            raise ValueError("annual products need explicit owner configuration before they can be approved")
        if self.provider == "stripe" and not (self.stripe_price_id or "").startswith("price_"):
            raise ValueError("stripe products need a configured price id")
        if self.provider == "apple" and self.stripe_price_id is not None:
            raise ValueError("apple products carry no stripe price id")


class ProductCatalog:
    """The approved offers the edge functions may grant. Built from configuration
    or from ``billing_products`` rows the deployment loads with the service role.
    Unknown or unapproved ids never reach a subscription field."""

    def __init__(self, products: Iterable[ApprovedProduct]):
        self._by_id: Dict[Tuple[str, str], ApprovedProduct] = {}
        self._by_price: Dict[str, ApprovedProduct] = {}
        for product in products:
            key = (product.provider, product.product_id)
            if key in self._by_id:
                raise ValueError("duplicate product id %s" % product.product_id)
            self._by_id[key] = product
            if product.stripe_price_id:
                if product.stripe_price_id in self._by_price:
                    raise ValueError("duplicate stripe price id")
                self._by_price[product.stripe_price_id] = product

    @classmethod
    def from_rows(cls, rows: Iterable[Mapping[str, Any]], stripe_price_ids: Optional[Mapping[str, str]] = None) -> "ProductCatalog":
        """Build from ``billing_products`` rows (only ``approved`` rows count).
        ``stripe_price_ids`` maps product_id -> price id from the server configuration."""
        products = []
        for row in rows:
            if not row.get("approved"):
                continue
            products.append(ApprovedProduct(
                product_id=str(row["product_id"]), provider=str(row["provider"]), tier=str(row["tier"]),
                period=str(row["period"]), owner_configured=row.get("owner_configured_at") is not None,
                stripe_price_id=(stripe_price_ids or {}).get(str(row["product_id"])) if row["provider"] == "stripe" else None))
        return cls(products)

    def get(self, provider: str, product_id: Optional[str]) -> Optional[ApprovedProduct]:
        if not product_id:
            return None
        return self._by_id.get((provider, product_id))

    def by_stripe_price(self, price_id: Optional[str]) -> Optional[ApprovedProduct]:
        if not price_id:
            return None
        return self._by_price.get(price_id)

    def monthly(self, provider: str) -> List[ApprovedProduct]:
        return [p for p in self._by_id.values() if p.provider == provider and p.period == "monthly"]


@dataclass
class LedgerEntry:
    ref: str
    kind: str
    amount_minor: int
    currency: str

    def __post_init__(self):
        if self.kind not in LEDGER_KINDS:
            raise ValueError("unknown ledger kind")
        if not self.ref or len(self.ref) > 200:
            raise ValueError("ledger ref must be 1..200 characters")
        if not isinstance(self.amount_minor, int) or isinstance(self.amount_minor, bool) or abs(self.amount_minor) >= 10 ** 15:
            raise ValueError("amount_minor must be an integer in minor units")
        if not _CURRENCY_RE.match(self.currency):
            raise ValueError("currency must be an upper-case ISO code")

    def as_json(self) -> dict:
        return {"ref": self.ref, "kind": self.kind, "amount_minor": self.amount_minor, "currency": self.currency}


@dataclass
class ApplyEventCall:
    """Exactly the parameters of ``public.sdi_billing_apply_event``. Subscription
    fields stay ``None`` whenever nothing may be granted."""

    provider: str
    event_id: str
    event_type: str
    occurred_at: _dt.datetime
    payload: dict
    user_id: Optional[str] = None
    provider_subscription_id: Optional[str] = None
    product_id: Optional[str] = None
    status: Optional[str] = None
    paid_through: Optional[_dt.datetime] = None
    cancel_at_period_end: bool = False
    ledger: List[LedgerEntry] = field(default_factory=list)
    # The provider reports the current period as a free trial. None = not
    # reported (stored as false); the database also treats ``trialing`` as a trial.
    in_trial: Optional[bool] = None

    def __post_init__(self):
        if self.provider not in PROVIDERS:
            raise ValueError("unknown provider")
        if not self.event_id or len(self.event_id) > 200:
            raise ValueError("event_id must be 1..200 characters")
        if not self.event_type or len(self.event_type) > 120:
            raise ValueError("event_type must be 1..120 characters")
        if self.occurred_at.tzinfo is None:
            raise ValueError("occurred_at must be timezone-aware")
        if self.status is not None and self.status not in CANONICAL_STATUSES:
            raise ValueError("status outside the canonical set")
        if self.user_id is not None and not _UUID_RE.match(self.user_id):
            raise ValueError("user_id must be a UUID")
        if self.provider_subscription_id is not None and (not self.provider_subscription_id or len(self.provider_subscription_id) > 200):
            raise ValueError("provider_subscription_id must be 1..200 characters")
        if self.provider_subscription_id is not None and (self.product_id is None or self.status is None or self.paid_through is None):
            raise ValueError("a subscription change needs product, status and paid_through")
        if self.paid_through is not None and self.paid_through.tzinfo is None:
            raise ValueError("paid_through must be timezone-aware")
        if self.in_trial is not None and not isinstance(self.in_trial, bool):
            raise ValueError("in_trial must be a boolean or None")

    def grants(self) -> bool:
        return self.provider_subscription_id is not None

    def rpc(self) -> Tuple[str, Dict[str, Any]]:
        """``(function_name, named_parameters)`` ready for a PostgREST ``rpc`` call."""
        return APPLY_EVENT_RPC, {
            "provider": self.provider,
            "event_id": self.event_id,
            "event_type": self.event_type,
            "occurred_at": iso(self.occurred_at),
            "payload": self.payload,
            "user_id": self.user_id,
            "provider_subscription_id": self.provider_subscription_id,
            "product_id": self.product_id,
            "status": self.status,
            "paid_through": iso(self.paid_through) if self.paid_through else None,
            "cancel_at_period_end": bool(self.cancel_at_period_end),
            "ledger": [entry.as_json() for entry in self.ledger],
            "in_trial": self.in_trial,
        }


SQLExecutor = Callable[[str, Mapping[str, Any]], Mapping[str, Any]]
"""``executor(function_name, parameters) -> jsonb result as a dict``. The
deployment binds it to the service role; it is never reachable from a client."""


def iso(when: _dt.datetime) -> str:
    return when.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def from_epoch(value: Any, *, millis: bool) -> Optional[_dt.datetime]:
    if value is None or isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    seconds = float(value) / (1000.0 if millis else 1.0)
    if seconds <= 0 or seconds > 4_102_444_800:  # year 2100 guard against garbage
        return None
    return _dt.datetime.fromtimestamp(seconds, _dt.timezone.utc)


def as_uuid(value: Any) -> Optional[str]:
    if not isinstance(value, str) or not _UUID_RE.match(value):
        return None
    return str(uuid.UUID(value))


def apply_event(executor: SQLExecutor, call: ApplyEventCall) -> dict:
    """Run the one database call and shape the HTTP result. Duplicate and
    ignored outcomes are 200 so the provider stops retrying; the record explains why."""
    name, params = call.rpc()
    try:
        result = executor(name, params)
    except Exception:
        # The provider will retry; nothing was granted. Detail stays in private logs.
        raise ContractError(500, "database unavailable") from None
    if not isinstance(result, Mapping):
        raise ContractError(500, "database unavailable")
    if result.get("error"):
        raise ContractError(500, "event rejected by the database")
    if result.get("duplicate"):
        return {"received": True, "duplicate": True, "event_id": call.event_id}
    body = {"received": True, "duplicate": False, "event_id": call.event_id,
            "outcome": result.get("outcome", "applied"), "granted": bool(result.get("subscription"))}
    if result.get("note"):
        body["note"] = result["note"]
    return body


def execute_and_respond(executor: SQLExecutor, call: ApplyEventCall) -> "Response":
    return Response(200, apply_event(executor, call))


@dataclass
class Response:
    status: int
    body: dict

    def json(self) -> str:
        return json.dumps(self.body, separators=(",", ":"), sort_keys=True)


def header(headers: Mapping[str, str], name: str) -> str:
    wanted = name.lower()
    for key, value in headers.items():
        if key.lower() == wanted:
            return value
    return ""


def parse_json_object(raw: bytes, max_bytes: int) -> dict:
    if len(raw) > max_bytes:
        raise ContractError(413, "request too large")
    try:
        body = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ContractError(400, "malformed json") from None
    if not isinstance(body, dict):
        raise ContractError(400, "malformed request")
    return body


# Keys that may carry card, bank, address or contact data in provider payloads.
# They are dropped before the payload is stored in provider_events.
REDACTED_KEYS = frozenset({
    "payment_method_details", "payment_method", "payment_method_options", "source", "sources", "card", "bank_account",
    "billing_details", "customer_details", "customer_email", "customer_name", "customer_address", "customer_shipping",
    "customer_phone", "shipping", "receipt_email", "receipt_url", "hosted_invoice_url", "invoice_pdf", "last4",
    "fingerprint", "exp_month", "exp_year", "email", "phone", "address", "name", "tax_ids", "account_name",
    "account_holder_name", "client_secret", "url",
})


def redact(value: Any, depth: int = 0) -> Any:
    """Recursively drop keys that may carry card or contact data. Depth-bounded."""
    if depth > 12:
        return None
    if isinstance(value, Mapping):
        return {k: redact(v, depth + 1) for k, v in value.items() if k not in REDACTED_KEYS}
    if isinstance(value, (list, tuple)):
        return [redact(item, depth + 1) for item in value[:200]]
    return value


def ledger_from(entries: Sequence[Tuple[str, str, Any, Any]]) -> List[LedgerEntry]:
    """Build ledger rows from provider amounts, skipping entries whose amount or
    currency is missing rather than inventing values."""
    rows = []
    for ref, kind, amount, currency in entries:
        if not isinstance(amount, int) or isinstance(amount, bool) or not isinstance(currency, str):
            continue
        code = currency.upper()
        if not _CURRENCY_RE.match(code) or not ref:
            continue
        rows.append(LedgerEntry(ref=str(ref), kind=kind, amount_minor=amount, currency=code))
    return rows


# ── Spatter credit packs (owner decision 2026-10-15, later) ──────────────────
# Consumable store products that credit the Spatter ledger. 1 credit = 1 prompt.
# No price is carried: the stores own prices; Stripe uses a configured price id.
CREDIT_GRANT_RPC = "sdi_spatter_credits_grant"
CREDIT_REFUND_RPC = "sdi_spatter_credits_refund"


@dataclass(frozen=True)
class CreditPack:
    """One approved credit pack (``sdi_private.spatter_credit_packs``)."""

    product_id: str
    provider: str
    credits: int
    stripe_price_id: Optional[str] = None

    def __post_init__(self):
        if not self.product_id or len(self.product_id) > 200:
            raise ValueError("product_id must be 1..200 characters")
        if self.provider not in PROVIDERS:
            raise ValueError("provider must be apple or stripe (Google Play has no verification path yet)")
        if not isinstance(self.credits, int) or isinstance(self.credits, bool) or not 1 <= self.credits <= 100_000:
            raise ValueError("credits must be 1..100000")
        if self.provider == "stripe" and not (self.stripe_price_id or "").startswith("price_"):
            raise ValueError("stripe credit packs need a configured price id")
        if self.provider == "apple" and self.stripe_price_id is not None:
            raise ValueError("apple credit packs carry no stripe price id")


class CreditPackCatalog:
    """Approved credit packs the handlers may sell or grant. The database checks
    approval again on every grant, so a stale catalogue can never over-grant."""

    def __init__(self, packs: Iterable[CreditPack] = ()):
        self._by_id: Dict[Tuple[str, str], CreditPack] = {}
        self._by_price: Dict[str, CreditPack] = {}
        for pack in packs:
            key = (pack.provider, pack.product_id)
            if key in self._by_id:
                raise ValueError("duplicate credit pack %s" % pack.product_id)
            self._by_id[key] = pack
            if pack.stripe_price_id:
                if pack.stripe_price_id in self._by_price:
                    raise ValueError("duplicate stripe price id")
                self._by_price[pack.stripe_price_id] = pack

    @classmethod
    def from_rows(cls, rows: Iterable[Mapping[str, Any]], stripe_price_ids: Optional[Mapping[str, str]] = None) -> "CreditPackCatalog":
        packs = []
        for row in rows:
            if not row.get("approved") or row.get("provider") not in PROVIDERS:
                continue
            packs.append(CreditPack(product_id=str(row["product_id"]), provider=str(row["provider"]), credits=int(row["credits"]),
                                    stripe_price_id=(stripe_price_ids or {}).get(str(row["product_id"])) if row["provider"] == "stripe" else None))
        return cls(packs)

    def get(self, provider: str, product_id: Any) -> Optional[CreditPack]:
        if not isinstance(product_id, str) or not product_id:
            return None
        return self._by_id.get((provider, product_id))

    def by_stripe_price(self, price_id: Optional[str]) -> Optional[CreditPack]:
        return self._by_price.get(price_id) if price_id else None


def _credit_call(executor: SQLExecutor, name: str, params: Mapping[str, Any]) -> dict:
    try:
        result = executor(name, params)
    except Exception:
        raise ContractError(500, "database unavailable") from None
    if not isinstance(result, Mapping) or result.get("status") not in ("granted", "duplicate", "refused", "refunded", "ignored"):
        raise ContractError(500, "database unavailable")
    body = {"status": result["status"]}
    for key in ("credits", "credits_added", "clawed_back", "shortfall", "reason"):
        if key in result:
            body[key] = result[key]
    return body


def grant_credits(executor: SQLExecutor, user_id: str, provider: str, product_id: str, transaction_ref: str, livemode: bool) -> dict:
    """``public.sdi_spatter_credits_grant``: idempotent per (provider, transaction)."""
    if as_uuid(user_id) is None or provider not in PROVIDERS or not transaction_ref or len(transaction_ref) > 200:
        raise ContractError(400, "invalid credit grant")
    return _credit_call(executor, CREDIT_GRANT_RPC, {"p_user": as_uuid(user_id), "p_provider": provider, "p_product_id": product_id,
                                                     "p_transaction_ref": transaction_ref, "p_livemode": bool(livemode)})


def refund_credits(executor: SQLExecutor, provider: str, transaction_ref: str) -> dict:
    """``public.sdi_spatter_credits_refund``: claws back up to the balance, once."""
    if provider not in PROVIDERS or not transaction_ref or len(transaction_ref) > 200:
        raise ContractError(400, "invalid credit refund")
    return _credit_call(executor, CREDIT_REFUND_RPC, {"p_provider": provider, "p_transaction_ref": transaction_ref})

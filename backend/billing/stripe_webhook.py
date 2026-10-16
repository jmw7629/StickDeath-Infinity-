"""``stripe-webhook`` edge-function candidate.

Pure handler: verifies the ``Stripe-Signature`` header (Stripe's ``v1`` scheme:
HMAC-SHA256 over ``"{t}.{raw body}"`` with the endpoint secret, constant-time
comparison, timestamp tolerance) **before** the body is parsed, then maps the
event to one ``public.sdi_billing_apply_event`` call through the injected
executor. No Stripe API call is made here; the deployment injects the secret
from its secret store and never logs it.

Event handling:

* ``checkout.session.completed`` – recorded with the account link; it is not
  proof of payment, so no subscription fields are sent. Entitlement follows the
  signed subscription/invoice events. Exception: a one-time ``mode=payment``
  session for an approved Spatter credit pack (``metadata.sdi_credit_pack``)
  with ``payment_status == "paid"`` grants the pack through
  ``public.sdi_spatter_credits_grant`` keyed by its PaymentIntent id (also on
  ``checkout.session.async_payment_succeeded``), plus a ``charge`` ledger row
  from ``amount_total`` in live mode only.
* ``customer.subscription.created|updated|deleted`` – status, period end,
  ``cancel_at_period_end`` and the configured price id → approved product.
* ``invoice.paid`` – active through the paid line period, plus a ``charge``
  ledger row from ``amount_paid`` (live mode only).
* ``invoice.payment_failed`` – recorded only; Stripe's subsequent
  ``customer.subscription.updated`` carries the ``past_due`` status.
* ``charge.refunded`` – ``refund`` ledger rows per refund (live mode only); the
  subscription status is left to the subscription events. A fully refunded
  charge also claws back Spatter credits bought with its PaymentIntent
  (``public.sdi_spatter_credits_refund``; a non-credit charge is ignored there).
  Partial refunds do not claw back credits; the owner adjusts by hand.
* ``payout.paid`` – ``payout`` ledger row (live mode only).

Any other type is recorded without subscription fields. Replays are safe: the
database keeps one row per event id and older events never move a subscription
backwards. Test-mode (``livemode: false``) events are recorded but never produce
ledger rows, and a live/test mismatch with the configured mode is refused.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import hmac
from dataclasses import dataclass
from typing import Any, Callable, List, Mapping, Optional, Tuple

from .contract import (ApplyEventCall, ContractError, CreditPackCatalog, LedgerEntry, ProductCatalog, Response, SQLExecutor,
                       apply_event, as_uuid, from_epoch, grant_credits, header, ledger_from, parse_json_object, redact,
                       refund_credits)

MAX_BODY_BYTES = 512 * 1024
DEFAULT_TOLERANCE_SECONDS = 300
SUBSCRIPTION_EVENTS = ("customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted")
CREDIT_CHECKOUT_EVENTS = ("checkout.session.completed", "checkout.session.async_payment_succeeded")
HANDLED_EVENTS = SUBSCRIPTION_EVENTS + CREDIT_CHECKOUT_EVENTS + ("invoice.paid", "invoice.payment_failed",
                                                                 "charge.refunded", "payout.paid")

# Stripe subscription status -> canonical status. ``incomplete`` is unpaid and grants nothing.
_STATUS = {"active": "active", "trialing": "trialing", "past_due": "past_due", "canceled": "cancelled",
           "unpaid": "expired", "incomplete_expired": "expired", "paused": "expired"}


@dataclass(frozen=True)
class StripeConfig:
    livemode: bool = False
    tolerance_seconds: int = DEFAULT_TOLERANCE_SECONDS

    def __post_init__(self):
        if not 30 <= self.tolerance_seconds <= 3600:
            raise ValueError("tolerance must be between 30 seconds and one hour")


def verify_signature(raw_body: bytes, signature_header: str, secret: bytes, now: _dt.datetime,
                     tolerance_seconds: int = DEFAULT_TOLERANCE_SECONDS) -> None:
    """Stripe ``v1`` scheme. Raises ContractError(400) on any failure."""
    if not isinstance(secret, (bytes, bytearray)) or len(secret) < 16:
        raise ContractError(503, "webhook secret not configured")
    if not signature_header or len(signature_header) > 4096:
        raise ContractError(400, "missing signature")
    timestamp: Optional[int] = None
    candidates: List[str] = []
    for item in signature_header.split(","):
        key, sep, value = item.strip().partition("=")
        if not sep:
            continue
        if key == "t" and value.isdigit() and timestamp is None:
            timestamp = int(value)
        elif key == "v1" and len(value) == 64 and all(c in "0123456789abcdef" for c in value):
            candidates.append(value)
    if timestamp is None or not candidates:
        raise ContractError(400, "malformed signature")
    if abs(int(now.timestamp()) - timestamp) > tolerance_seconds:
        raise ContractError(400, "signature timestamp outside tolerance")
    expected = hmac.new(bytes(secret), ("%d." % timestamp).encode("ascii") + raw_body, hashlib.sha256).hexdigest()
    if not any(hmac.compare_digest(expected, candidate) for candidate in candidates):
        raise ContractError(400, "invalid signature")


def sign(raw_body: bytes, secret: bytes, timestamp: int) -> str:
    """Produce a ``Stripe-Signature`` header value. Used by tests and local tooling only."""
    digest = hmac.new(secret, ("%d." % timestamp).encode("ascii") + raw_body, hashlib.sha256).hexdigest()
    return "t=%d,v1=%s" % (timestamp, digest)


def _id(value: Any) -> Optional[str]:
    """Stripe references are either an id string or an expanded object with ``id``."""
    if isinstance(value, str) and 1 <= len(value) <= 200:
        return value
    if isinstance(value, Mapping) and isinstance(value.get("id"), str) and value["id"]:
        return value["id"][:200]
    return None


def _metadata_user(*holders: Any) -> Optional[str]:
    for holder in holders:
        if isinstance(holder, Mapping):
            meta = holder.get("metadata")
            if isinstance(meta, Mapping):
                user = as_uuid(meta.get("sdi_user_id"))
                if user:
                    return user
    return None


def _first_item(obj: Mapping[str, Any], key: str) -> Mapping[str, Any]:
    items = obj.get(key)
    data = items.get("data") if isinstance(items, Mapping) else items
    if isinstance(data, list) and data and isinstance(data[0], Mapping):
        return data[0]
    return {}


def _price_id(line: Mapping[str, Any]) -> Optional[str]:
    price = _id(line.get("price"))
    if price:
        return price
    pricing = line.get("pricing")
    if isinstance(pricing, Mapping):
        details = pricing.get("price_details")
        if isinstance(details, Mapping):
            return _id(details.get("price"))
    return None


def _period_end(sub: Mapping[str, Any]) -> Optional[_dt.datetime]:
    end = from_epoch(sub.get("current_period_end"), millis=False)
    if end is None:
        end = from_epoch(_first_item(sub, "items").get("current_period_end"), millis=False)
    return end


def _invoice_subscription(invoice: Mapping[str, Any]) -> Tuple[Optional[str], Mapping[str, Any]]:
    sub = _id(invoice.get("subscription"))
    details: Mapping[str, Any] = invoice.get("subscription_details") if isinstance(invoice.get("subscription_details"), Mapping) else {}
    parent = invoice.get("parent")
    if isinstance(parent, Mapping) and isinstance(parent.get("subscription_details"), Mapping):
        details = parent["subscription_details"]
        sub = sub or _id(details.get("subscription"))
    return sub, details


def _credit_purchase(obj: Mapping[str, Any], credit_packs: Optional[CreditPackCatalog]):
    """(user, pack, payment_intent) for a paid one-time credit-pack session, else None."""
    if credit_packs is None or obj.get("mode") != "payment" or obj.get("payment_status") != "paid":
        return None
    meta = obj.get("metadata") if isinstance(obj.get("metadata"), Mapping) else {}
    pack = credit_packs.get("stripe", meta.get("sdi_credit_pack"))
    user = as_uuid(obj.get("client_reference_id")) or _metadata_user(obj)
    intent = _id(obj.get("payment_intent"))
    if pack is None or user is None or intent is None:
        return None
    return user, pack, intent


def credit_action(event: Mapping[str, Any], credit_packs: Optional[CreditPackCatalog], executor: SQLExecutor) -> Optional[dict]:
    """Grant or claw back Spatter credits for a verified event; None when unrelated."""
    data = event.get("data")
    obj = data.get("object") if isinstance(data, Mapping) else None
    if credit_packs is None or not isinstance(obj, Mapping):
        return None
    if event.get("type") in CREDIT_CHECKOUT_EVENTS:
        purchase = _credit_purchase(obj, credit_packs)
        if purchase is None:
            return None
        user, pack, intent = purchase
        return grant_credits(executor, user, "stripe", pack.product_id, intent, livemode=bool(event.get("livemode")))
    if event.get("type") == "charge.refunded" and obj.get("refunded") is True:
        intent = _id(obj.get("payment_intent"))
        return refund_credits(executor, "stripe", intent) if intent else None
    return None


def map_event(event: Mapping[str, Any], catalog: ProductCatalog, config: StripeConfig,
              credit_packs: Optional[CreditPackCatalog] = None) -> ApplyEventCall:
    event_id = event.get("id")
    event_type = event.get("type")
    created = from_epoch(event.get("created"), millis=False)
    data = event.get("data")
    obj = data.get("object") if isinstance(data, Mapping) else None
    if not isinstance(event_id, str) or not event_id.startswith("evt_") or not isinstance(event_type, str) or created is None or not isinstance(obj, Mapping):
        raise ContractError(400, "incomplete event")
    livemode = event.get("livemode")
    if not isinstance(livemode, bool) or livemode != config.livemode:
        raise ContractError(400, "live mode mismatch")
    payload = {"livemode": livemode, "type": event_type, "object": redact(obj)}
    base = dict(provider="stripe", event_id=event_id, event_type=event_type, occurred_at=created, payload=payload)
    ledger: List[LedgerEntry] = []

    if event_type in CREDIT_CHECKOUT_EVENTS:
        user = as_uuid(obj.get("client_reference_id")) or _metadata_user(obj)
        payload["sdi_user_id"] = user
        purchase = _credit_purchase(obj, credit_packs)
        if purchase is not None:
            _user, pack, intent = purchase
            payload["credit_pack"] = pack.product_id
            payload["reason"] = "paid Spatter credit pack"
            if livemode:
                ledger = ledger_from([(intent, "charge", obj.get("amount_total"), obj.get("currency"))])
            return ApplyEventCall(**base, user_id=user, ledger=ledger)
        payload["subscription"] = _id(obj.get("subscription"))
        payload["reason"] = "checkout completion is not payment evidence"
        return ApplyEventCall(**base, user_id=user)

    if event_type in SUBSCRIPTION_EVENTS:
        sub_id = _id(obj.get("id"))
        product = catalog.by_stripe_price(_price_id(_first_item(obj, "items")))
        if product is None:
            payload["reason"] = "product not approved"
            return ApplyEventCall(**base)
        status = _STATUS.get(obj.get("status"))
        paid_through = _period_end(obj)
        cancel = bool(obj.get("cancel_at_period_end"))
        if event_type == "customer.subscription.deleted":
            status = "cancelled"
            paid_through = from_epoch(obj.get("ended_at"), millis=False) or paid_through or created
        if sub_id is None or status is None or paid_through is None:
            payload["reason"] = "subscription not payable or lacks a period end"
            return ApplyEventCall(**base)
        return ApplyEventCall(**base, user_id=_metadata_user(obj), provider_subscription_id=sub_id, product_id=product.product_id,
                              status=status, paid_through=paid_through, cancel_at_period_end=cancel)

    if event_type == "invoice.paid":
        sub_id, details = _invoice_subscription(obj)
        line = _first_item(obj, "lines")
        product = catalog.by_stripe_price(_price_id(line))
        period = line.get("period") if isinstance(line.get("period"), Mapping) else {}
        paid_through = from_epoch(period.get("end"), millis=False) or from_epoch(obj.get("period_end"), millis=False)
        if livemode and obj.get("status") == "paid":
            ledger = ledger_from([(_id(obj.get("id")), "charge", obj.get("amount_paid"), obj.get("currency"))])
        if product is None or sub_id is None or paid_through is None:
            payload["reason"] = "invoice has no approved subscription line"
            return ApplyEventCall(**base, ledger=ledger)
        return ApplyEventCall(**base, user_id=_metadata_user(details, obj), provider_subscription_id=sub_id,
                              product_id=product.product_id, status="active", paid_through=paid_through, ledger=ledger)

    if event_type == "charge.refunded" and livemode:
        refunds = obj.get("refunds")
        rows = refunds.get("data") if isinstance(refunds, Mapping) else refunds
        entries = []
        for refund in rows if isinstance(rows, list) else []:
            if isinstance(refund, Mapping) and refund.get("status") in (None, "succeeded"):
                amount = refund.get("amount")
                entries.append((_id(refund.get("id")), "refund", -amount if isinstance(amount, int) and not isinstance(amount, bool) else None, refund.get("currency")))
        if not entries:
            amount = obj.get("amount_refunded")
            entries.append((_id(obj.get("id")), "refund", -amount if isinstance(amount, int) and not isinstance(amount, bool) else None, obj.get("currency")))
        ledger = ledger_from(entries)
    elif event_type == "payout.paid" and livemode:
        ledger = ledger_from([(_id(obj.get("id")), "payout", obj.get("amount"), obj.get("currency"))])
    if event_type not in HANDLED_EVENTS:
        payload["reason"] = "event type recorded only"
    return ApplyEventCall(**base, ledger=ledger)


def handle(headers: Mapping[str, str], raw_body: bytes, *, executor: SQLExecutor, catalog: ProductCatalog, secret: bytes,
           config: StripeConfig = StripeConfig(), credit_packs: Optional[CreditPackCatalog] = None,
           now: Callable[[], _dt.datetime] = lambda: _dt.datetime.now(_dt.timezone.utc)) -> Response:
    """Process one Stripe webhook POST. The signature is checked before the body is read."""
    try:
        if len(raw_body) > MAX_BODY_BYTES:
            raise ContractError(413, "request too large")
        verify_signature(raw_body, header(headers, "Stripe-Signature"), secret, now(), config.tolerance_seconds)
        event = parse_json_object(raw_body, MAX_BODY_BYTES)
        call = map_event(event, catalog, config, credit_packs)
        body = apply_event(executor, call)
        # Also on a duplicate event: credit grants/refunds are idempotent per
        # PaymentIntent, so a retry completes a grant whose first attempt failed.
        credits = credit_action(event, credit_packs, executor)
        if credits is not None:
            body["credits"] = credits
        return Response(200, body)
    except ContractError as error:
        return Response(error.status, {"error": error.reason})

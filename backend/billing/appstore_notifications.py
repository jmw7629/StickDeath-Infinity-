"""``appstore-notifications`` edge-function candidate (App Store Server Notifications V2).

Pure handler: ``handle(headers, raw_body, ...)`` returns a ``Response``. It never
contacts Apple, the database or a secret store on its own. The deployment injects:

* ``verifier`` – validates the ``x5c`` certificate chain up to the pinned Apple
  root and checks the ES256 signature with the leaf certificate's key. Python's
  standard library has no ECDSA, so the cryptographic step is the runtime's
  (WebCrypto / ``cryptography``). This module performs the structural checks
  around it: three JWS segments, ``alg`` ES256, a 2–3 certificate ``x5c`` chain
  whose root byte-matches a configured trusted root, DER-shaped certificates, a
  64-byte raw signature, and the same verification for every nested JWS
  (``signedTransactionInfo``, ``signedRenewalInfo``). Without a verifier the
  handler fails closed (503) and never calls the database.
* ``executor`` – runs ``public.sdi_billing_apply_event`` with the service role.
* ``catalog`` – the owner's approved products; anything else grants nothing.

Idempotency is the notification's ``notificationUUID``: the database keeps one
row per ``(provider, event_id)`` and answers ``duplicate`` for replays, which this
handler returns as 200 so Apple stops retrying. Sandbox notifications are recorded
with ``payload.environment`` and never produce ledger (revenue) rows.

Spatter credit packs (consumables, owner decision 2026-10-15): when a
``credit_packs`` catalogue is injected, a ``REFUND`` for an approved pack also
claws the credits back through ``public.sdi_spatter_credits_refund`` and a
``ONE_TIME_CHARGE`` (if Apple sends one) grants through
``public.sdi_spatter_credits_grant`` for the ``appAccountToken`` account. Both
are idempotent per transaction id, so they are safe alongside the in-app
redemption in ``appstore_credits`` and on notification replays.
"""
from __future__ import annotations

import base64
import binascii
import datetime as _dt
import json
from dataclasses import dataclass, field
from typing import Any, Callable, List, Mapping, Optional, Protocol, Sequence, Tuple

from .contract import (ApplyEventCall, ContractError, CreditPackCatalog, LedgerEntry, ProductCatalog, Response, SQLExecutor,
                       apply_event, as_uuid, from_epoch, grant_credits, parse_json_object, refund_credits)

MAX_BODY_BYTES = 256 * 1024
ENVIRONMENTS = ("Sandbox", "Production")
SUBSCRIPTION_TYPE = "Auto-Renewable Subscription"
CONSUMABLE_TYPE = "Consumable"

# Status mapping by notificationType (and subtype where it matters).
_ACTIVE_TYPES = {"SUBSCRIBED", "DID_RENEW", "DID_CHANGE_RENEWAL_STATUS", "DID_CHANGE_RENEWAL_PREF", "OFFER_REDEEMED",
                 "RENEWAL_EXTENDED", "RENEWAL_EXTENSION", "REFUND_REVERSED"}
_RECORD_ONLY_TYPES = {"TEST", "CONSUMPTION_REQUEST", "PRICE_INCREASE", "REFUND_DECLINED", "ONE_TIME_CHARGE",
                      "EXTERNAL_PURCHASE_TOKEN"}
HANDLED_TYPES = _ACTIVE_TYPES | _RECORD_ONLY_TYPES | {"DID_FAIL_TO_RENEW", "GRACE_PERIOD_EXPIRED", "EXPIRED", "REFUND", "REVOKE"}

# ISO 4217 minor-unit exponents that differ from two. Apple reports ``price`` in
# milliunits; an amount is only converted when the exponent is known exactly.
_ZERO_DECIMAL = {"JPY", "KRW", "VND", "CLP", "ISK", "PYG", "UGX", "XAF", "XOF", "XPF", "RWF", "GNF", "DJF", "KMF", "BIF", "VUV"}
_THREE_DECIMAL = {"BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"}


class ChainVerifier(Protocol):
    def verify(self, chain: Sequence[bytes], signing_input: bytes, signature: bytes) -> bool:
        """Validate ``chain`` (leaf first) to the pinned root and the ES256 signature over ``signing_input``."""


@dataclass(frozen=True)
class AppStoreConfig:
    bundle_id: str
    environment: str
    trusted_roots: Tuple[bytes, ...] = field(default_factory=tuple)

    def __post_init__(self):
        if not self.bundle_id:
            raise ValueError("bundle_id is required")
        if self.environment not in ENVIRONMENTS:
            raise ValueError("environment must be Sandbox or Production")
        if not self.trusted_roots or any(not isinstance(root, bytes) or not root for root in self.trusted_roots):
            raise ValueError("at least one trusted root certificate (DER bytes) is required")


@dataclass
class DecodedJWS:
    header: dict
    payload: dict
    chain: List[bytes]
    signing_input: bytes
    signature: bytes


def _b64url_decode(segment: str) -> bytes:
    if not segment or not isinstance(segment, str) or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" for c in segment):
        raise ContractError(400, "malformed jws")
    try:
        return base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4))
    except (binascii.Error, ValueError):
        raise ContractError(400, "malformed jws") from None


def _der_sequence_length_ok(der: bytes) -> bool:
    """A certificate is one DER SEQUENCE whose encoded length covers the whole blob."""
    if len(der) < 4 or der[0] != 0x30:
        return False
    first = der[1]
    if first < 0x80:
        return 2 + first == len(der)
    count = first & 0x7F
    if count == 0 or count > 4 or len(der) < 2 + count:
        return False
    length = int.from_bytes(der[2:2 + count], "big")
    return 2 + count + length == len(der)


def decode_jws(token: Any, config: AppStoreConfig) -> DecodedJWS:
    """Structural decode of one compact JWS. Does not verify the signature."""
    if not isinstance(token, str) or len(token) > 64 * 1024:
        raise ContractError(400, "malformed jws")
    parts = token.split(".")
    if len(parts) != 3 or not all(parts):
        raise ContractError(400, "malformed jws")
    try:
        header = json.loads(_b64url_decode(parts[0]).decode("utf-8"))
        payload = json.loads(_b64url_decode(parts[1]).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ContractError(400, "malformed jws") from None
    if not isinstance(header, dict) or not isinstance(payload, dict):
        raise ContractError(400, "malformed jws")
    if header.get("alg") != "ES256":
        raise ContractError(400, "unsupported jws algorithm")
    x5c = header.get("x5c")
    if not isinstance(x5c, list) or not 2 <= len(x5c) <= 3 or not all(isinstance(c, str) and c for c in x5c):
        raise ContractError(400, "missing certificate chain")
    chain = []
    for cert in x5c:
        try:
            der = base64.b64decode(cert, validate=True)
        except (binascii.Error, ValueError):
            raise ContractError(400, "malformed certificate chain") from None
        if not _der_sequence_length_ok(der):
            raise ContractError(400, "malformed certificate chain")
        chain.append(der)
    if chain[-1] not in config.trusted_roots:
        raise ContractError(400, "untrusted certificate root")
    signature = _b64url_decode(parts[2])
    if len(signature) != 64:
        raise ContractError(400, "malformed signature")
    return DecodedJWS(header=header, payload=payload, chain=chain,
                      signing_input=(parts[0] + "." + parts[1]).encode("ascii"), signature=signature)


def verify_jws(token: Any, config: AppStoreConfig, verifier: Optional[ChainVerifier]) -> dict:
    decoded = decode_jws(token, config)
    if verifier is None:
        raise ContractError(503, "signature verifier not configured")
    try:
        ok = verifier.verify(decoded.chain, decoded.signing_input, decoded.signature)
    except Exception:
        ok = False
    if ok is not True:
        raise ContractError(400, "invalid signature")
    return decoded.payload


def _milliunits_to_minor(price: Any, currency: Any) -> Optional[Tuple[int, str]]:
    if not isinstance(price, int) or isinstance(price, bool) or price < 0 or not isinstance(currency, str):
        return None
    code = currency.upper()
    if len(code) != 3 or not code.isalpha():
        return None
    exponent = 0 if code in _ZERO_DECIMAL else 3 if code in _THREE_DECIMAL else 2
    scaled = price * (10 ** exponent)
    if scaled % 1000:
        return None
    return scaled // 1000, code


@dataclass
class Notification:
    notification_type: str
    subtype: Optional[str]
    notification_uuid: str
    signed_at: _dt.datetime
    environment: str
    bundle_id: str
    transaction: Optional[dict]
    renewal: Optional[dict]


def decode_notification(raw_body: bytes, config: AppStoreConfig, verifier: Optional[ChainVerifier]) -> Notification:
    body = parse_json_object(raw_body, MAX_BODY_BYTES)
    outer = verify_jws(body.get("signedPayload"), config, verifier)
    notification_type = outer.get("notificationType")
    uuid_value = as_uuid(outer.get("notificationUUID"))
    signed_at = from_epoch(outer.get("signedDate"), millis=True)
    data = outer.get("data") if isinstance(outer.get("data"), dict) else {}
    if not isinstance(notification_type, str) or not notification_type or uuid_value is None or signed_at is None:
        raise ContractError(400, "incomplete notification")
    environment = data.get("environment") or outer.get("environment")
    bundle_id = data.get("bundleId")
    if environment != config.environment:
        raise ContractError(400, "environment mismatch")
    if notification_type != "TEST" and bundle_id != config.bundle_id:
        raise ContractError(400, "bundle mismatch")
    transaction = verify_jws(data["signedTransactionInfo"], config, verifier) if data.get("signedTransactionInfo") else None
    renewal = verify_jws(data["signedRenewalInfo"], config, verifier) if data.get("signedRenewalInfo") else None
    for nested in (transaction, renewal):
        if nested is not None and (nested.get("environment", environment) != environment or nested.get("bundleId", bundle_id) != bundle_id):
            raise ContractError(400, "nested payload mismatch")
    subtype = outer.get("subtype") if isinstance(outer.get("subtype"), str) else None
    return Notification(notification_type=notification_type, subtype=subtype, notification_uuid=uuid_value, signed_at=signed_at,
                        environment=environment, bundle_id=bundle_id or "", transaction=transaction, renewal=renewal)


def map_notification(note: Notification, catalog: ProductCatalog) -> ApplyEventCall:
    """Map a verified notification to the one database call. Unknown products,
    non-subscription transactions and informational types record the event only."""
    payload = {
        "environment": note.environment, "bundleId": note.bundle_id, "notificationType": note.notification_type,
        "subtype": note.subtype, "signedDate": note.signed_at.isoformat(),
        "transaction": note.transaction, "renewal": note.renewal,
    }
    base = dict(provider="apple", event_id=note.notification_uuid, event_type=note.notification_type, occurred_at=note.signed_at, payload=payload)
    tx = note.transaction or {}
    if note.notification_type in _RECORD_ONLY_TYPES or not tx or tx.get("type") != SUBSCRIPTION_TYPE:
        payload["reason"] = "informational notification" if not tx or note.notification_type in _RECORD_ONLY_TYPES else "not a subscription transaction"
        return ApplyEventCall(**base)
    product = catalog.get("apple", tx.get("productId"))
    if product is None:
        payload["reason"] = "product not approved"
        return ApplyEventCall(**base)
    original_id = tx.get("originalTransactionId")
    expires = from_epoch(tx.get("expiresDate"), millis=True)
    revoked_at = from_epoch(tx.get("revocationDate"), millis=True)
    renewal = note.renewal or {}
    grace_until = from_epoch(renewal.get("gracePeriodExpiresDate"), millis=True)
    auto_renew = renewal.get("autoRenewStatus")
    cancel_at_period_end = auto_renew == 0 if isinstance(auto_renew, int) and not isinstance(auto_renew, bool) else False
    if note.notification_type == "DID_CHANGE_RENEWAL_STATUS" and note.subtype in ("AUTO_RENEW_DISABLED", "AUTO_RENEW_ENABLED"):
        cancel_at_period_end = note.subtype == "AUTO_RENEW_DISABLED"
    kind = note.notification_type
    ledger: List[LedgerEntry] = []
    if kind in _ACTIVE_TYPES:
        status, paid_through = ("active", expires)
        if expires is not None and expires <= note.signed_at and kind in ("DID_CHANGE_RENEWAL_STATUS", "DID_CHANGE_RENEWAL_PREF"):
            status = "expired"
    elif kind == "DID_FAIL_TO_RENEW":
        status, paid_through = ("grace", grace_until or expires) if note.subtype == "GRACE_PERIOD" else ("past_due", expires)
    elif kind in ("GRACE_PERIOD_EXPIRED", "EXPIRED"):
        status, paid_through = "expired", expires
    elif kind == "REFUND":
        status, paid_through = "refunded", revoked_at or note.signed_at
    elif kind == "REVOKE":
        status, paid_through = "revoked", revoked_at or note.signed_at
    else:  # pragma: no cover - HANDLED_TYPES is closed above
        status, paid_through = None, None
    if kind in ("REFUND", "REFUND_REVERSED") and note.environment == "Production":
        converted = _milliunits_to_minor(tx.get("price"), tx.get("currency"))
        ref = tx.get("transactionId")
        if converted and isinstance(ref, str) and ref:
            amount, code = converted
            ledger.append(LedgerEntry(ref=ref, kind="refund" if kind == "REFUND" else "adjustment",
                                      amount_minor=-amount if kind == "REFUND" else amount, currency=code))
    if not isinstance(original_id, str) or not original_id or status is None or paid_through is None:
        payload["reason"] = "transaction lacks original id or dates"
        return ApplyEventCall(**base, ledger=ledger)
    return ApplyEventCall(**base, user_id=as_uuid(tx.get("appAccountToken")), provider_subscription_id=original_id,
                          product_id=product.product_id, status=status, paid_through=paid_through,
                          cancel_at_period_end=cancel_at_period_end, ledger=ledger)


def credit_action(note: Notification, credit_packs: Optional[CreditPackCatalog], executor: SQLExecutor) -> Optional[dict]:
    """Grant or claw back Spatter credits for a verified consumable notification."""
    tx = note.transaction or {}
    if credit_packs is None or tx.get("type") != CONSUMABLE_TYPE:
        return None
    pack = credit_packs.get("apple", tx.get("productId"))
    ref = tx.get("transactionId")
    if pack is None or not isinstance(ref, str) or not ref or len(ref) > 200:
        return None
    if note.notification_type == "REFUND":
        return refund_credits(executor, "apple", ref)
    if note.notification_type == "ONE_TIME_CHARGE":
        user = as_uuid(tx.get("appAccountToken"))
        if user is not None and tx.get("revocationDate") is None:
            return grant_credits(executor, user, "apple", pack.product_id, ref, livemode=note.environment == "Production")
    return None


def handle(headers: Mapping[str, str], raw_body: bytes, *, executor: SQLExecutor, catalog: ProductCatalog,
           config: AppStoreConfig, verifier: Optional[ChainVerifier] = None,
           credit_packs: Optional[CreditPackCatalog] = None,
           now: Callable[[], _dt.datetime] = lambda: _dt.datetime.now(_dt.timezone.utc)) -> Response:
    """Process one POST from App Store Server Notifications V2."""
    try:
        note = decode_notification(raw_body, config, verifier)
        if note.signed_at > now() + _dt.timedelta(minutes=5):
            raise ContractError(400, "notification from the future")
        call = map_notification(note, catalog)
        body = apply_event(executor, call)
        # Also on a duplicate notification: the credit calls are idempotent and
        # this completes a replay whose first attempt failed after recording.
        credits = credit_action(note, credit_packs, executor)
        if credits is not None:
            body["credits"] = credits
        return Response(200, body)
    except ContractError as error:
        return Response(error.status, {"error": error.reason})

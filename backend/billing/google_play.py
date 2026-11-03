"""Authenticated, read-only Google Play subscription verification foundation (#289).

An inspected Publisher snapshot is NOT a durable entitlement grant. This module
has no SQL executor, acknowledge, refund, consume or purchase operation. The
existing Apple/Stripe provider contract and Android disabled verifier are kept
unchanged until durable token ownership, atomic linked-token reconciliation,
RTDN/voided-order processing and post-commit acknowledgement are delivered.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import json
import math
import re
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping

from .contract import ContractError, Response, TIERS, as_uuid, iso
from .google_play_transport import (GooglePublisher, HttpTransport, PACKAGE, PublisherAccessToken,
    SecretStore, json_object, read_secret, validate_purchase_token)
from .stripe_checkout import _bearer, _member

MAX_BODY_BYTES = 8 * 1024
_PRODUCT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,199}\Z")
_STATES = frozenset({"PENDING", "ACTIVE", "PAUSED", "IN_GRACE_PERIOD", "ON_HOLD", "CANCELED", "EXPIRED", "PENDING_PURCHASE_CANCELED"})
_ACK = frozenset({"ACKNOWLEDGEMENT_STATE_PENDING", "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED"})


@dataclass(frozen=True)
class ApprovedPlayProduct:
    product_id: str
    base_plan_id: str
    tier: str

    def __post_init__(self):
        if not isinstance(self.product_id, str) or _PRODUCT.fullmatch(self.product_id) is None:
            raise ValueError("invalid approved Google product")
        if not isinstance(self.base_plan_id, str) or _PRODUCT.fullmatch(self.base_plan_id) is None:
            raise ValueError("invalid approved Google base plan")
        if self.tier not in TIERS:
            raise ValueError("Google product needs an approved tier")
        # Monthly approval is explicit deployment configuration; no annual,
        # prepaid, multi-item or installment offer is inferred from a product id.


@dataclass(frozen=True)
class PlayVerificationConfig:
    package_name: str
    products: tuple[ApprovedPlayProduct, ...] = ()
    enabled: bool = False
    allow_test_purchases: bool = False
    service_account_secret: str | None = field(default=None, repr=False)
    account_binding_secret: str | None = field(default=None, repr=False)

    def __post_init__(self):
        if not isinstance(self.package_name, str) or len(self.package_name) > 200 or PACKAGE.fullmatch(self.package_name) is None:
            raise ValueError("invalid Google package")
        if not isinstance(self.enabled, bool) or not isinstance(self.allow_test_purchases, bool):
            raise ValueError("Google verification switches must be boolean")
        if not isinstance(self.products, tuple) or len(self.products) > 32 or not all(isinstance(p, ApprovedPlayProduct) for p in self.products):
            raise ValueError("invalid approved Google catalogue")
        keys = [(p.product_id, p.base_plan_id) for p in self.products]
        if len(keys) != len(set(keys)):
            raise ValueError("duplicate approved Google offer")
        for value in (self.service_account_secret, self.account_binding_secret):
            if value is not None and (not isinstance(value, str) or not 1 <= len(value) <= 200 or any(ord(c) < 33 or ord(c) > 126 for c in value)):
                raise ValueError("invalid server secret reference")


def account_binding(user_id: str, package_name: str, secret: bytes) -> str:
    """Stable 64-character HMAC for future setObfuscatedAccountId integration.

    Server-created only, domain-separated by app/package and canonical member
    UUID; never an email, raw user id, auth token or caller-supplied mapping.
    Rotation requires a versioned binding migration before purchases resume.
    """
    user = as_uuid(user_id)
    if user is None or not isinstance(package_name, str) or PACKAGE.fullmatch(package_name) is None or not isinstance(secret, bytes) or not 32 <= len(secret) <= 64:
        raise ContractError(503, "Google account binding unavailable")
    return hmac.new(secret, ("sdi:google-play:account:v1\0" + package_name + "\0" + user).encode("ascii"), hashlib.sha256).hexdigest()


def _timestamp(value: Any) -> dt.datetime | None:
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > 40 or re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})", value) is None:
        raise ContractError(502, "Google purchase has an invalid expiry")
    try:
        result = dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
        if not 2000 <= result.year < 2100:
            raise ValueError("expiry outside supported range")
        return result
    except ValueError:
        raise ContractError(502, "Google purchase has an invalid expiry") from None


def _trial(item: Mapping[str, Any]) -> bool | None:
    phase = item.get("offerPhase")
    if phase is None:
        return None  # Missing phase must never be promoted to paid Spatter access.
    if not isinstance(phase, dict) or len(phase) != 1:
        raise ContractError(502, "Google purchase has an invalid offer phase")
    name, detail = next(iter(phase.items()))
    if not isinstance(detail, dict):
        raise ContractError(502, "Google purchase has an invalid offer phase")
    if name == "freeTrial":
        return True
    if name in ("basePrice", "introductoryPrice"):
        return False
    if name == "prorationPeriod":
        # Not a normal paid renewal: preserve unknown until linked-plan/period
        # reconciliation is implemented; a prorated old trial is not guessed paid.
        return None
    raise ContractError(502, "Google purchase has an unsupported offer phase")


@dataclass(frozen=True)
class SubscriptionObservation:
    product: ApprovedPlayProduct
    state: str
    expiry: dt.datetime | None
    in_trial: bool | None
    acknowledgement_pending: bool
    test_purchase: bool
    auto_renewing: bool
    linked_reconciliation_required: bool
    snapshot_access: bool
    token_reference: str = field(repr=False)
    # Observation equality only, NOT a durable event id: A->B->A can repeat
    # a snapshot. Future RTDN delivery ids + atomic token locks own idempotency.
    fingerprint: str

    def public_result(self) -> dict:
        return {"verificationOnly": True, "purchaseVerified": True,
            "entitlementApplied": False, "acknowledgementPerformed": False,
            "reconciliationAvailable": False, "subscriptionState": self.state,
            "productId": self.product.product_id, "basePlanId": self.product.base_plan_id,
            "observedTier": self.product.tier, "expiresAt": iso(self.expiry) if self.expiry else None,
            "inTrial": self.in_trial, "acknowledgementPending": self.acknowledgement_pending,
            "testPurchase": self.test_purchase, "autoRenewing": self.auto_renewing,
            "linkedReconciliationRequired": self.linked_reconciliation_required,
            "snapshotAccess": self.snapshot_access,
            "notice": "Inspection only. Google Play entitlement reconciliation and purchases remain unavailable."}


class GooglePlayVerifier:
    def __init__(self, config: PlayVerificationConfig, secrets: SecretStore | None = None,
                 transport: HttpTransport | None = None, clock: Callable[[], float] = time.time):
        self.config, self._secrets, self._clock = config, secrets, clock
        self._publisher = (GooglePublisher(PublisherAccessToken(secrets, config.service_account_secret, transport, clock), transport)
            if secrets is not None and transport is not None and config.service_account_secret else None)
        self._products = {(p.product_id, p.base_plan_id): p for p in config.products}

    @property
    def configured(self) -> bool:
        return bool(self.config.enabled and self._products and self._publisher is not None
                    and self.config.account_binding_secret and self._secrets is not None)

    def inspect(self, user_id: str, purchase_token: str) -> SubscriptionObservation:
        if not self.configured:
            raise ContractError(503, "Google Play verification is not configured")
        user = as_uuid(user_id)
        if user is None:
            raise ContractError(401, "unauthorized")
        token = validate_purchase_token(purchase_token)
        binding_secret = read_secret(self._secrets, self.config.account_binding_secret, 32, 64)
        expected = account_binding(user, self.config.package_name, binding_secret)
        resource = self._publisher.subscription(self.config.package_name, token)
        identifiers = resource.get("externalAccountIdentifiers")
        actual = identifiers.get("obfuscatedExternalAccountId") if isinstance(identifiers, dict) else None
        if not isinstance(actual, str) or re.fullmatch(r"[0-9a-f]{64}", actual) is None or not hmac.compare_digest(actual, expected):
            raise ContractError(403, "purchase is not bound to this account")
        test = "testPurchase" in resource
        if test and (not isinstance(resource["testPurchase"], dict) or not self.config.allow_test_purchases):
            raise ContractError(409, "test purchases are not accepted by this verifier")
        items = resource.get("lineItems")
        if not isinstance(items, list) or len(items) != 1 or not isinstance(items[0], dict):
            raise ContractError(409, "multi-item or incomplete Google subscriptions need reconciliation")
        item = items[0]
        offer = item.get("offerDetails")
        product_id = item.get("productId")
        base_plan = offer.get("basePlanId") if isinstance(offer, dict) else None
        if not isinstance(product_id, str) or not isinstance(base_plan, str):
            raise ContractError(502, "Google purchase has no approved offer identity")
        product = self._products.get((product_id, base_plan))
        if product is None:
            raise ContractError(409, "unknown or unapproved Google offer")
        renewal = item.get("autoRenewingPlan")
        if not isinstance(renewal, dict) or "prepaidPlan" in item or "installmentDetails" in renewal:
            raise ContractError(409, "prepaid or installment subscriptions are unavailable")
        auto_renew = renewal.get("autoRenewEnabled", False)  # protobuf omits false defaults
        if not isinstance(auto_renew, bool):
            raise ContractError(502, "Google purchase has invalid renewal settings")
        wire_state = resource.get("subscriptionState")
        state = wire_state[len("SUBSCRIPTION_STATE_"):] if isinstance(wire_state, str) and wire_state.startswith("SUBSCRIPTION_STATE_") else ""
        if state not in _STATES:
            raise ContractError(502, "Google purchase has an unsupported state")
        if (state in ("ACTIVE", "IN_GRACE_PERIOD") and not auto_renew) or (state == "CANCELED" and auto_renew):
            raise ContractError(502, "Google purchase has inconsistent renewal state")
        expiry = _timestamp(item.get("expiryTime"))
        if state not in ("PENDING", "PENDING_PURCHASE_CANCELED") and expiry is None:
            raise ContractError(502, "Google purchase has no verified expiry")
        ack = resource.get("acknowledgementState")
        if (not isinstance(ack, str) or ack not in _ACK) and state not in ("PENDING", "PENDING_PURCHASE_CANCELED"):
            raise ContractError(502, "Google purchase has an unsupported acknowledgement state")
        trial = _trial(item)
        linked = resource.get("linkedPurchaseToken")
        if linked is not None:
            validate_purchase_token(linked)
        requires_link = linked is not None or any(k in item for k in ("itemReplacement", "deferredItemReplacement", "deferredItemRemoval"))
        now = self._clock()
        if not isinstance(now, (int, float)) or isinstance(now, bool) or not math.isfinite(now) or now <= 0:
            raise ContractError(503, "Google verification clock unavailable")
        access = bool(state in ("ACTIVE", "IN_GRACE_PERIOD", "CANCELED") and expiry is not None
            and expiry.timestamp() > now and trial is not None and not requires_link)
        # EXPIRED includes revocations/chargebacks: never carry access just
        # because an old date is future. Refund money/reason cannot be inferred
        # from this resource alone; authenticated RTDN + voided/orders are gates.
        reference = "gp:" + hashlib.sha256(token.encode("ascii")).hexdigest()
        canonical = {"token": reference, "binding": expected, "product": product_id, "plan": base_plan,
            "state": state, "expiry": iso(expiry) if expiry else None, "trial": trial,
            "ack": ack, "test": test, "renew": auto_renew, "linked": requires_link}
        fingerprint = hashlib.sha256(json.dumps(canonical, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        return SubscriptionObservation(product, state, expiry, trial, ack == "ACKNOWLEDGEMENT_STATE_PENDING",
            test, auto_renew, requires_link, access, reference, fingerprint)


def handle(headers: Mapping[str, str], raw_body: bytes, *, verify_jwt: Callable[[str], Mapping[str, Any]],
           account_active: Callable[[str], bool], verifier: GooglePlayVerifier,
           permit_query: Callable[[str], bool] | None = None,
           now: Callable[[], dt.datetime] = lambda: dt.datetime.now(dt.timezone.utc)) -> Response:
    """Candidate POST inspect handler; no route/deployment or entitlement response.

    JWT signature/issuer verification, account activity and a durable per-member
    query limiter are runtime injections. Body contains ONLY purchase_token;
    user/tier/package/phase/expiry/provider claims are never client-authoritative.
    No injection or the disabled default => no Google/secret request.
    """
    try:
        bearer = _bearer(headers)
        try:
            claims = verify_jwt(bearer)
        except Exception:
            raise ContractError(401, "unauthorized") from None
        if (not isinstance(claims, Mapping) or claims.get("role") != "authenticated"
            or isinstance(claims.get("exp"), bool) or not isinstance(claims.get("exp"), (int, float))
            or not math.isfinite(claims["exp"])):
            raise ContractError(401, "unauthorized")
        user = _member(claims, now())
        try:
            if account_active(user) is not True:
                raise ContractError(403, "account is not active")
        except ContractError:
            raise
        except Exception:
            raise ContractError(503, "account status unavailable") from None
        if not verifier.configured or permit_query is None:
            raise ContractError(503, "Google Play verification is not configured")
        try:
            body = json_object(raw_body, MAX_BODY_BYTES)
        except ContractError:
            raise ContractError(413 if len(raw_body) > MAX_BODY_BYTES else 400, "invalid purchase request") from None
        if set(body) != {"purchase_token"}:
            raise ContractError(400, "purchase request accepts only a purchase token")
        token = validate_purchase_token(body["purchase_token"])
        try:
            if permit_query(user) is not True:
                raise ContractError(429, "purchase verification rate limit")
        except ContractError:
            raise
        except Exception:
            raise ContractError(503, "purchase verification rate limiter unavailable") from None
        observation = verifier.inspect(user, token)
        # Recheck eligibility after the remote operation; a disabled/deleted
        # account must not receive a fresh observation or future grant input.
        try:
            if account_active(user) is not True:
                raise ContractError(403, "account is not active")
        except ContractError:
            raise
        except Exception:
            raise ContractError(503, "account status unavailable") from None
        return Response(200, observation.public_result())
    except ContractError as error:
        return Response(error.status, {"error": error.reason, "entitlementApplied": False, "acknowledgementPerformed": False})

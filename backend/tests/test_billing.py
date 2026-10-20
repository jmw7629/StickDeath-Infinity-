"""Offline tests for backend/billing: the three edge-function candidates mapped onto
``sdi_billing_apply_event`` through a recording executor. No network, no secrets,
no provider SDK. Run from the repository root:

    python3 -m unittest discover -s backend/tests -t .
"""
import base64
import datetime as dt
import json
import re
import unittest
import uuid
from pathlib import Path

from backend.billing import appstore_notifications as apple
from backend.billing import stripe_checkout as checkout
from backend.billing import stripe_webhook as stripe
from backend.billing.contract import (APPLY_EVENT_RPC, ApplyEventCall, ApprovedProduct, ContractError, LedgerEntry,
                                      ProductCatalog, apply_event, ledger_from, redact)

REPO = Path(__file__).resolve().parents[2]
NOW = dt.datetime(2026, 10, 12, 12, 0, 0, tzinfo=dt.timezone.utc)
USER = "0f3b1d2a-5c6e-4f70-8a91-b2c3d4e5f607"
MS = 1000

# DER-shaped blobs: one SEQUENCE whose encoded length covers the whole value.
ROOT = b"\x30\x03\x02\x01\x01"
INTERMEDIATE = b"\x30\x03\x02\x01\x02"
LEAF = b"\x30\x03\x02\x01\x03"
OTHER_ROOT = b"\x30\x03\x02\x01\x09"

CATALOG = ProductCatalog([
    ApprovedProduct("sdi.creator.monthly", "apple", "creator", "monthly"),
    ApprovedProduct("sdi.pro.monthly", "apple", "pro", "monthly"),
    ApprovedProduct("com.willisbmb.StickDeathInfinity.unlimited.monthly", "apple", "unlimited", "monthly"),
    ApprovedProduct("sdi.creator.monthly.web", "stripe", "creator", "monthly", stripe_price_id="price_creator"),
    ApprovedProduct("sdi.pro.monthly.web", "stripe", "pro", "monthly", stripe_price_id="price_pro"),
    ApprovedProduct("sdi.pro.annual.web", "stripe", "pro", "annual", stripe_price_id="price_annual", owner_configured=True),
])


class RecordingExecutor:
    """Stands in for the service-role database call. Records every call."""

    def __init__(self, result=None, raise_error=None):
        self.calls = []
        self.result = result if result is not None else {"event": str(uuid.uuid4()), "outcome": "applied", "note": "", "subscription": None}
        self.raise_error = raise_error

    def __call__(self, name, params):
        self.calls.append((name, params))
        if self.raise_error:
            raise self.raise_error
        return self.result

    @property
    def only(self):
        assert len(self.calls) == 1, self.calls
        return self.calls[0][1]


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def jws(payload: dict, chain=(LEAF, INTERMEDIATE, ROOT), alg="ES256", signature=b"\x01" * 64) -> str:
    header = {"alg": alg, "x5c": [base64.b64encode(c).decode("ascii") for c in chain]}
    return ".".join([b64url(json.dumps(header).encode()), b64url(json.dumps(payload).encode()), b64url(signature)])


class FakeVerifier:
    def __init__(self, ok=True):
        self.ok = ok
        self.calls = []

    def verify(self, chain, signing_input, signature):
        self.calls.append((list(chain), signing_input, signature))
        return self.ok


APPLE_CONFIG = apple.AppStoreConfig(bundle_id="com.stickdeath.infinity", environment="Production", trusted_roots=(ROOT,))


def notification(notification_type, transaction=None, renewal=None, subtype=None, environment="Production",
                 bundle_id="com.stickdeath.infinity", signed_at=NOW, notification_uuid=None, chain=(LEAF, INTERMEDIATE, ROOT)):
    data = {"environment": environment, "bundleId": bundle_id}
    if transaction is not None:
        data["signedTransactionInfo"] = jws(dict(transaction, environment=environment, bundleId=bundle_id), chain)
    if renewal is not None:
        data["signedRenewalInfo"] = jws(dict(renewal, environment=environment, bundleId=bundle_id), chain)
    outer = {"notificationType": notification_type, "notificationUUID": notification_uuid or str(uuid.uuid4()),
             "signedDate": int(signed_at.timestamp() * MS), "data": data}
    if subtype:
        outer["subtype"] = subtype
    return json.dumps({"signedPayload": jws(outer, chain)}).encode()


def transaction(**overrides):
    base = {"type": apple.SUBSCRIPTION_TYPE, "productId": "sdi.creator.monthly", "originalTransactionId": "orig-100",
            "transactionId": "tx-200", "appAccountToken": USER, "purchaseDate": int((NOW - dt.timedelta(days=1)).timestamp() * MS),
            "expiresDate": int((NOW + dt.timedelta(days=29)).timestamp() * MS), "price": 4990, "currency": "USD"}
    base.update(overrides)
    return base


def apple_handle(body, executor=None, verifier=None, config=APPLE_CONFIG, now=NOW):
    executor = executor or RecordingExecutor()
    verifier = FakeVerifier() if verifier is None else verifier
    response = apple.handle({}, body, executor=executor, catalog=CATALOG, config=config, verifier=verifier, now=lambda: now)
    return response, executor


class ContractTests(unittest.TestCase):
    def test_rpc_parameter_names_match_the_sql_function(self):
        sql = (REPO / "backend/sql/billing.sql").read_text()
        match = re.search(r"create function sdi_private\.billing_apply_event\((.*?)\) returns jsonb", sql, re.S)
        self.assertIsNotNone(match, "billing_apply_event signature not found")
        names = [p.strip().split()[0] for p in match.group(1).split(",")]
        call = ApplyEventCall(provider="apple", event_id="e", event_type="t", occurred_at=NOW, payload={})
        rpc_name, params = call.rpc()
        self.assertEqual(rpc_name, APPLY_EVENT_RPC)
        self.assertEqual(list(params), names)
        self.assertIn("public.sdi_billing_apply_event", sql)

    def test_approved_product_rules(self):
        with self.assertRaises(ValueError):
            ApprovedProduct("x.annual", "apple", "pro", "annual")            # annual needs owner configuration
        with self.assertRaises(ValueError):
            ApprovedProduct("x", "stripe", "pro", "monthly")                 # stripe needs a price id
        with self.assertRaises(ValueError):
            ApprovedProduct("x", "apple", "pro", "monthly", stripe_price_id="price_x")
        with self.assertRaises(ValueError):
            ApprovedProduct("x", "apple", "studio", "monthly")              # no fourth tier
        ApprovedProduct("x.annual", "apple", "pro", "annual", owner_configured=True)
        ApprovedProduct("x.unlimited", "apple", "unlimited", "monthly")    # owner decision 2026-10-20

    def test_three_tiers_all_have_the_trial(self):
        from backend.billing.contract import TIERS, TRIAL_TIERS
        self.assertEqual(TIERS, ("creator", "pro", "unlimited"))
        self.assertEqual(TRIAL_TIERS, TIERS)
        sql = (REPO / "backend/sql/billing.sql").read_text()
        self.assertIn("check(tier in('creator','pro','unlimited'))", sql)
        self.assertIn("tier not in('creator','pro','unlimited')", sql)

    def test_in_trial_is_sent_and_validated(self):
        call = ApplyEventCall(provider="apple", event_id="e", event_type="t", occurred_at=NOW, payload={}, in_trial=True)
        self.assertIs(call.rpc()[1]["in_trial"], True)
        self.assertIsNone(ApplyEventCall(provider="apple", event_id="e", event_type="t", occurred_at=NOW, payload={}).rpc()[1]["in_trial"])
        with self.assertRaises(ValueError):
            ApplyEventCall(provider="apple", event_id="e", event_type="t", occurred_at=NOW, payload={}, in_trial="yes")

    def test_catalog_from_rows_ignores_unapproved_and_maps_prices(self):
        rows = [
            {"product_id": "a", "provider": "apple", "tier": "creator", "period": "monthly", "approved": True, "owner_configured_at": "2026-10-01"},
            {"product_id": "b", "provider": "apple", "tier": "pro", "period": "monthly", "approved": False, "owner_configured_at": None},
            {"product_id": "c", "provider": "stripe", "tier": "pro", "period": "monthly", "approved": True, "owner_configured_at": "2026-10-01"},
        ]
        catalog = ProductCatalog.from_rows(rows, {"c": "price_c"})
        self.assertIsNotNone(catalog.get("apple", "a"))
        self.assertIsNone(catalog.get("apple", "b"))
        self.assertEqual(catalog.by_stripe_price("price_c").product_id, "c")
        self.assertEqual([p.product_id for p in catalog.monthly("stripe")], ["c"])
        with self.assertRaises(ValueError):
            ProductCatalog([ApprovedProduct("a", "apple", "pro", "monthly"), ApprovedProduct("a", "apple", "pro", "monthly")])

    def test_apply_event_call_validation(self):
        with self.assertRaises(ValueError):
            ApplyEventCall(provider="apple", event_id="e", event_type="t", occurred_at=NOW, payload={}, provider_subscription_id="s")
        with self.assertRaises(ValueError):
            ApplyEventCall(provider="apple", event_id="e", event_type="t", occurred_at=NOW, payload={}, status="lifetime")
        with self.assertRaises(ValueError):
            ApplyEventCall(provider="apple", event_id="e", event_type="t", occurred_at=NOW.replace(tzinfo=None), payload={})
        with self.assertRaises(ValueError):
            ApplyEventCall(provider="apple", event_id="e", event_type="t", occurred_at=NOW, payload={}, user_id="not-a-uuid")
        call = ApplyEventCall(provider="stripe", event_id="evt_1", event_type="t", occurred_at=NOW, payload={}, user_id=USER,
                              provider_subscription_id="sub_1", product_id="p", status="active", paid_through=NOW)
        self.assertTrue(call.grants())
        self.assertEqual(call.rpc()[1]["paid_through"], "2026-10-12T12:00:00.000Z")

    def test_apply_event_shapes_results(self):
        call = ApplyEventCall(provider="apple", event_id="e", event_type="t", occurred_at=NOW, payload={})
        self.assertEqual(apply_event(RecordingExecutor({"duplicate": True}), call), {"received": True, "duplicate": True, "event_id": "e"})
        body = apply_event(RecordingExecutor({"outcome": "ignored", "note": "Product is not an approved offer.", "subscription": None}), call)
        self.assertEqual((body["outcome"], body["granted"], body["note"]), ("ignored", False, "Product is not an approved offer."))
        with self.assertRaises(ContractError) as refused:
            apply_event(RecordingExecutor({"error": "Provider, event id, type, time and payload are required."}), call)
        self.assertEqual(refused.exception.status, 500)
        with self.assertRaises(ContractError) as down:
            apply_event(RecordingExecutor(raise_error=OSError("connection refused")), call)
        self.assertEqual(down.exception.status, 500)
        self.assertNotIn("connection", down.exception.reason)

    def test_redaction_and_ledger_helpers(self):
        cleaned = redact({"id": "ch_1", "customer_email": "x@example.test", "payment_method_details": {"card": {"last4": "4242"}},
                          "billing_details": {"name": "A"}, "lines": [{"price": "price_1", "receipt_url": "https://x"}]})
        self.assertEqual(cleaned, {"id": "ch_1", "lines": [{"price": "price_1"}]})
        rows = ledger_from([("in_1", "charge", 499, "usd"), ("bad", "charge", "499", "usd"), ("bad2", "charge", 499, "us"), ("", "charge", 1, "USD")])
        self.assertEqual([r.as_json() for r in rows], [{"ref": "in_1", "kind": "charge", "amount_minor": 499, "currency": "USD"}])
        with self.assertRaises(ValueError):
            LedgerEntry("r", "tip", 1, "USD")


class AppStoreNotificationTests(unittest.TestCase):
    def test_config_requires_trusted_root(self):
        with self.assertRaises(ValueError):
            apple.AppStoreConfig(bundle_id="b", environment="Production")
        with self.assertRaises(ValueError):
            apple.AppStoreConfig(bundle_id="b", environment="Staging", trusted_roots=(ROOT,))

    def test_malformed_requests_never_reach_the_database(self):
        for body in (b"not json", b"[]", json.dumps({"signedPayload": "a.b"}).encode(),
                     json.dumps({"signedPayload": jws({"notificationType": "TEST"}, alg="HS256")}).encode(),
                     json.dumps({"signedPayload": jws({"notificationType": "TEST"}, signature=b"\x01" * 63)}).encode()):
            response, executor = apple_handle(body)
            self.assertEqual(response.status, 400, body[:40])
            self.assertEqual(executor.calls, [])

    def test_untrusted_root_and_failed_signature_are_refused(self):
        response, executor = apple_handle(notification("SUBSCRIBED", transaction(), chain=(LEAF, INTERMEDIATE, OTHER_ROOT)))
        self.assertEqual((response.status, response.body["error"]), (400, "untrusted certificate root"))
        response, executor = apple_handle(notification("SUBSCRIBED", transaction()), verifier=FakeVerifier(ok=False))
        self.assertEqual((response.status, response.body["error"]), (400, "invalid signature"))
        self.assertEqual(executor.calls, [])

    def test_missing_verifier_fails_closed(self):
        executor = RecordingExecutor()
        response = apple.handle({}, notification("SUBSCRIBED", transaction()), executor=executor, catalog=CATALOG, config=APPLE_CONFIG, verifier=None)
        self.assertEqual(response.status, 503)
        self.assertEqual(executor.calls, [])

    def test_subscribed_grants_active_through_expires_date(self):
        verifier = FakeVerifier()
        response, executor = apple_handle(notification("SUBSCRIBED", transaction(), notification_uuid="11111111-2222-4333-8444-555555555555"), verifier=verifier)
        self.assertEqual(response.status, 200)
        self.assertTrue(response.body["received"])
        params = executor.only
        self.assertEqual(executor.calls[0][0], APPLY_EVENT_RPC)
        self.assertEqual(params["provider"], "apple")
        self.assertEqual(params["event_id"], "11111111-2222-4333-8444-555555555555")
        self.assertEqual(params["event_type"], "SUBSCRIBED")
        self.assertEqual(params["user_id"], USER)
        self.assertEqual(params["provider_subscription_id"], "orig-100")
        self.assertEqual(params["product_id"], "sdi.creator.monthly")
        self.assertEqual(params["status"], "active")
        self.assertEqual(params["paid_through"], "2026-11-10T12:00:00.000Z")
        self.assertFalse(params["cancel_at_period_end"])
        self.assertEqual(params["ledger"], [])
        self.assertEqual(params["payload"]["environment"], "Production")
        self.assertEqual(len(verifier.calls), 2)   # outer payload and nested transaction

    def test_duplicate_notification_is_acknowledged_without_grant(self):
        response, _ = apple_handle(notification("DID_RENEW", transaction()), executor=RecordingExecutor({"duplicate": True}))
        self.assertEqual(response.status, 200)
        self.assertTrue(response.body["duplicate"])

    def test_unapproved_product_records_only(self):
        response, executor = apple_handle(notification("SUBSCRIBED", transaction(productId="sdi.studio.monthly")))
        self.assertEqual(response.status, 200)
        params = executor.only
        self.assertIsNone(params["provider_subscription_id"])
        self.assertIsNone(params["status"])
        self.assertEqual(params["payload"]["reason"], "product not approved")

    def test_consumable_and_informational_types_record_only(self):
        response, executor = apple_handle(notification("ONE_TIME_CHARGE", transaction(type="Consumable")))
        self.assertIsNone(executor.only["provider_subscription_id"])
        response, executor = apple_handle(notification("TEST"))
        self.assertEqual(response.status, 200)
        self.assertEqual(executor.only["event_type"], "TEST")
        self.assertIsNone(executor.only["provider_subscription_id"])

    def test_grace_period_uses_grace_expiry(self):
        grace_end = NOW + dt.timedelta(days=16)
        renewal = {"autoRenewStatus": 1, "gracePeriodExpiresDate": int(grace_end.timestamp() * MS), "autoRenewProductId": "sdi.creator.monthly"}
        _, executor = apple_handle(notification("DID_FAIL_TO_RENEW", transaction(), renewal=renewal, subtype="GRACE_PERIOD"))
        params = executor.only
        self.assertEqual(params["status"], "grace")
        self.assertEqual(params["paid_through"], "2026-10-28T12:00:00.000Z")
        _, executor = apple_handle(notification("DID_FAIL_TO_RENEW", transaction(), renewal=renewal))
        self.assertEqual(executor.only["status"], "past_due")

    def test_expiry_cancellation_refund_and_revoke(self):
        _, executor = apple_handle(notification("EXPIRED", transaction(expiresDate=int((NOW - dt.timedelta(hours=1)).timestamp() * MS)), subtype="VOLUNTARY"))
        self.assertEqual(executor.only["status"], "expired")
        _, executor = apple_handle(notification("DID_CHANGE_RENEWAL_STATUS", transaction(), renewal={"autoRenewStatus": 0}, subtype="AUTO_RENEW_DISABLED"))
        params = executor.only
        self.assertEqual(params["status"], "active")            # still paid through the period end
        self.assertTrue(params["cancel_at_period_end"])
        revoked_at = NOW - dt.timedelta(minutes=5)
        _, executor = apple_handle(notification("REFUND", transaction(revocationDate=int(revoked_at.timestamp() * MS))))
        params = executor.only
        self.assertEqual(params["status"], "refunded")
        self.assertEqual(params["paid_through"], "2026-10-12T11:55:00.000Z")
        self.assertEqual(params["ledger"], [{"ref": "tx-200", "kind": "refund", "amount_minor": -499, "currency": "USD"}])
        _, executor = apple_handle(notification("REVOKE", transaction(revocationDate=int(revoked_at.timestamp() * MS)), subtype=None))
        self.assertEqual(executor.only["status"], "revoked")
        self.assertEqual(executor.only["ledger"], [])

    def test_downgrade_keeps_current_product_until_renewal(self):
        renewal = {"autoRenewStatus": 1, "autoRenewProductId": "sdi.creator.monthly"}
        _, executor = apple_handle(notification("DID_CHANGE_RENEWAL_PREF", transaction(productId="sdi.pro.monthly"), renewal=renewal, subtype="DOWNGRADE"))
        params = executor.only
        self.assertEqual(params["product_id"], "sdi.pro.monthly")
        self.assertEqual(params["status"], "active")
        self.assertEqual(params["payload"]["renewal"]["autoRenewProductId"], "sdi.creator.monthly")

    def test_sandbox_configuration_never_writes_revenue(self):
        sandbox = apple.AppStoreConfig(bundle_id="com.stickdeath.infinity", environment="Sandbox", trusted_roots=(ROOT,))
        body = notification("REFUND", transaction(revocationDate=int(NOW.timestamp() * MS)), environment="Sandbox")
        _, executor = apple_handle(body, config=sandbox)
        self.assertEqual(executor.only["ledger"], [])
        self.assertEqual(executor.only["payload"]["environment"], "Sandbox")
        response, executor = apple_handle(body)        # production config refuses sandbox traffic
        self.assertEqual((response.status, response.body["error"]), (400, "environment mismatch"))
        self.assertEqual(executor.calls, [])

    def test_bundle_mismatch_future_date_and_missing_dates(self):
        response, executor = apple_handle(notification("SUBSCRIBED", transaction(), bundle_id="com.other.app"))
        self.assertEqual((response.status, response.body["error"]), (400, "bundle mismatch"))
        response, executor = apple_handle(notification("SUBSCRIBED", transaction(), signed_at=NOW + dt.timedelta(minutes=10)))
        self.assertEqual((response.status, response.body["error"]), (400, "notification from the future"))
        self.assertEqual(executor.calls, [])
        _, executor = apple_handle(notification("SUBSCRIBED", transaction(expiresDate=None)))
        self.assertIsNone(executor.only["provider_subscription_id"])
        self.assertEqual(executor.only["payload"]["reason"], "transaction lacks original id or dates")

    def test_milliunit_conversion_respects_currency_exponent(self):
        self.assertEqual(apple._milliunits_to_minor(4990, "USD"), (499, "USD"))
        self.assertEqual(apple._milliunits_to_minor(500000, "JPY"), (500, "JPY"))
        self.assertEqual(apple._milliunits_to_minor(1500, "KWD"), (1500, "KWD"))
        self.assertIsNone(apple._milliunits_to_minor(4995, "USD"))   # not representable in cents
        self.assertIsNone(apple._milliunits_to_minor(-1, "USD"))
        self.assertIsNone(apple._milliunits_to_minor(4990, "usd1"))


SECRET = b"whsec_test_secret_0123456789abcdef"
STRIPE_CONFIG = stripe.StripeConfig(livemode=False)
LIVE_CONFIG = stripe.StripeConfig(livemode=True)


def stripe_event(event_type, obj, livemode=False, event_id="evt_123", created=NOW):
    return {"id": event_id, "object": "event", "type": event_type, "livemode": livemode, "created": int(created.timestamp()),
            "data": {"object": obj}}


def subscription_object(status="active", price="price_creator", **overrides):
    period_end = NOW + dt.timedelta(days=30)
    obj = {"id": "sub_1", "object": "subscription", "status": status, "cancel_at_period_end": False,
           "current_period_end": int(period_end.timestamp()), "metadata": {"sdi_user_id": USER, "sdi_product_id": "sdi.creator.monthly.web"},
           "items": {"data": [{"price": {"id": price}}]}, "customer": "cus_1"}
    obj.update(overrides)
    return obj


def stripe_handle(event, executor=None, config=STRIPE_CONFIG, now=NOW, secret=SECRET, header_override=None):
    executor = executor or RecordingExecutor()
    raw = json.dumps(event).encode()
    signature = stripe.sign(raw, secret, int(now.timestamp())) if header_override is None else header_override
    response = stripe.handle({"Stripe-Signature": signature}, raw, executor=executor, catalog=CATALOG, secret=secret, config=config, now=lambda: now)
    return response, executor


class AppStoreTrialTests(unittest.TestCase):
    """Owner decision 2026-10-20: a 3-day free trial (introductory offer) on every tier."""

    def test_free_trial_transaction_maps_to_trialing(self):
        tx = transaction(productId="com.willisbmb.StickDeathInfinity.unlimited.monthly", offerType=1, offerDiscountType="FREE_TRIAL",
                         price=0, expiresDate=int((NOW + dt.timedelta(days=3)).timestamp() * MS))
        response, executor = apple_handle(notification("SUBSCRIBED", tx, subtype="INITIAL_BUY"))
        self.assertEqual(response.status, 200)
        params = executor.only
        self.assertEqual((params["product_id"], params["status"], params["in_trial"]),
                         ("com.willisbmb.StickDeathInfinity.unlimited.monthly", "trialing", True))
        self.assertEqual(params["paid_through"], "2026-10-15T12:00:00.000Z")

    def test_trial_detection_rules(self):
        cases = [
            ({"offerType": 1, "offerDiscountType": "FREE_TRIAL", "price": 0}, True),
            ({"offerType": 3, "offerDiscountType": "FREE_TRIAL"}, True),            # offer-code free trial is also unpaid
            ({"offerType": 1, "price": 0}, True),                                   # payload without offerDiscountType
            ({"offerType": 1, "price": None}, True),                                # no price reported
            ({"offerType": 1, "offerDiscountType": "PAY_AS_YOU_GO", "price": 990}, False),
            ({"offerType": 1, "price": 990}, False),                                # a paid introductory price
            ({"offerType": 2, "price": 0}, False),                                  # promotional without a trial discount type
            ({}, False),
            ({"offerType": True}, False),
        ]
        for fields, expected in cases:
            self.assertIs(apple.is_free_trial(transaction(**fields)), expected, fields)

    def test_paid_renewal_clears_the_trial(self):
        response, executor = apple_handle(notification("DID_RENEW", transaction()))
        self.assertEqual((executor.only["status"], executor.only["in_trial"]), ("active", False))

    def test_billing_retry_after_an_unpaid_trial_keeps_the_trial(self):
        tx = transaction(offerType=1, offerDiscountType="FREE_TRIAL", price=0)
        grace = NOW + dt.timedelta(days=6)
        renewal = {"autoRenewStatus": 1, "gracePeriodExpiresDate": int(grace.timestamp() * MS)}
        _, executor = apple_handle(notification("DID_FAIL_TO_RENEW", tx, renewal=renewal, subtype="GRACE_PERIOD"))
        self.assertEqual((executor.only["status"], executor.only["in_trial"]), ("grace", True))

    def test_renewal_info_offer_does_not_make_a_paid_period_a_trial(self):
        renewal = {"autoRenewStatus": 1, "offerType": 1, "offerDiscountType": "FREE_TRIAL"}
        _, executor = apple_handle(notification("DID_CHANGE_RENEWAL_PREF", transaction(), renewal=renewal))
        self.assertEqual((executor.only["status"], executor.only["in_trial"]), ("active", False))


class StripeWebhookTests(unittest.TestCase):
    def test_signature_is_checked_before_the_body(self):
        event = stripe_event("customer.subscription.created", subscription_object())
        for header in ("", "t=abc,v1=00", "v1=" + "0" * 64, "t=%d,v1=%s" % (int(NOW.timestamp()), "0" * 64)):
            response, executor = stripe_handle(event, header_override=header)
            self.assertEqual(response.status, 400, header)
            self.assertEqual(executor.calls, [])
        stale = stripe.sign(json.dumps(event).encode(), SECRET, int((NOW - dt.timedelta(minutes=10)).timestamp()))
        response, executor = stripe_handle(event, header_override=stale)
        self.assertEqual(response.body["error"], "signature timestamp outside tolerance")
        response, executor = stripe_handle(event, secret=b"short")
        self.assertEqual(response.status, 503)
        self.assertEqual(executor.calls, [])
        tampered = json.dumps(event).encode()
        header = stripe.sign(tampered, SECRET, int(NOW.timestamp()))
        response = stripe.handle({"stripe-signature": header}, tampered.replace(b"sub_1", b"sub_2"), executor=RecordingExecutor(), catalog=CATALOG, secret=SECRET, now=lambda: NOW)
        self.assertEqual(response.body["error"], "invalid signature")

    def test_subscription_created_grants_active(self):
        response, executor = stripe_handle(stripe_event("customer.subscription.created", subscription_object()))
        self.assertEqual(response.status, 200)
        params = executor.only
        self.assertEqual(params["provider"], "stripe")
        self.assertEqual(params["event_id"], "evt_123")
        self.assertEqual(params["user_id"], USER)
        self.assertEqual(params["provider_subscription_id"], "sub_1")
        self.assertEqual(params["product_id"], "sdi.creator.monthly.web")
        self.assertEqual(params["status"], "active")
        self.assertEqual(params["paid_through"], "2026-11-11T12:00:00.000Z")
        self.assertEqual(params["payload"]["livemode"], False)
        self.assertNotIn("customer_email", json.dumps(params["payload"]))

    def test_subscription_states_map_to_the_canonical_set(self):
        cases = {"trialing": "trialing", "past_due": "past_due", "canceled": "cancelled", "unpaid": "expired", "paused": "expired"}
        for stripe_status, expected in cases.items():
            _, executor = stripe_handle(stripe_event("customer.subscription.updated", subscription_object(status=stripe_status)))
            self.assertEqual(executor.only["status"], expected, stripe_status)
        _, executor = stripe_handle(stripe_event("customer.subscription.updated", subscription_object(status="incomplete")))
        self.assertIsNone(executor.only["provider_subscription_id"])
        self.assertEqual(executor.only["payload"]["reason"], "subscription not payable or lacks a period end")

    def test_trial_applies_to_every_paid_plan(self):
        from backend.billing.contract import TIERS, TRIAL_TIERS
        self.assertEqual(TRIAL_TIERS, TIERS)
        for price, product in (("price_creator", "sdi.creator.monthly.web"), ("price_pro", "sdi.pro.monthly.web")):
            _, executor = stripe_handle(stripe_event("customer.subscription.created", subscription_object(status="trialing", price=price)))
            self.assertEqual((executor.only["status"], executor.only["product_id"], executor.only["in_trial"]), ("trialing", product, True))
        _, executor = stripe_handle(stripe_event("customer.subscription.updated", subscription_object(status="active")))
        self.assertEqual((executor.only["status"], executor.only["in_trial"]), ("active", False))

    def test_zero_amount_trial_start_invoice_keeps_the_trial(self):
        period_end = NOW + dt.timedelta(days=3)
        invoice = {"id": "in_t", "object": "invoice", "status": "paid", "amount_paid": 0, "currency": "usd", "subscription": "sub_1",
                   "billing_reason": "subscription_create", "subscription_details": {"metadata": {"sdi_user_id": USER}},
                   "lines": {"data": [{"price": {"id": "price_pro"}, "period": {"start": int(NOW.timestamp()), "end": int(period_end.timestamp())}}]}}
        _, executor = stripe_handle(stripe_event("invoice.paid", invoice))
        self.assertEqual((executor.only["status"], executor.only["in_trial"]), ("trialing", True))
        paid = dict(invoice, amount_paid=999, billing_reason="subscription_cycle")
        _, executor = stripe_handle(stripe_event("invoice.paid", paid))
        self.assertEqual((executor.only["status"], executor.only["in_trial"]), ("active", False))

    def test_cancel_at_period_end_downgrade_and_deletion(self):
        _, executor = stripe_handle(stripe_event("customer.subscription.updated", subscription_object(cancel_at_period_end=True)))
        self.assertTrue(executor.only["cancel_at_period_end"])
        self.assertEqual(executor.only["status"], "active")
        _, executor = stripe_handle(stripe_event("customer.subscription.updated", subscription_object(price="price_pro")))
        self.assertEqual(executor.only["product_id"], "sdi.pro.monthly.web")
        ended = NOW - dt.timedelta(minutes=1)
        _, executor = stripe_handle(stripe_event("customer.subscription.deleted", subscription_object(status="canceled", ended_at=int(ended.timestamp()))))
        self.assertEqual(executor.only["status"], "cancelled")
        self.assertEqual(executor.only["paid_through"], "2026-10-12T11:59:00.000Z")

    def test_unapproved_or_annual_price_grants_nothing(self):
        _, executor = stripe_handle(stripe_event("customer.subscription.created", subscription_object(price="price_unknown")))
        self.assertIsNone(executor.only["provider_subscription_id"])
        self.assertEqual(executor.only["payload"]["reason"], "product not approved")
        # Annual is only in the catalogue because the owner configured it explicitly; a webhook for it is applied as such.
        _, executor = stripe_handle(stripe_event("customer.subscription.created", subscription_object(price="price_annual")))
        self.assertEqual(executor.only["product_id"], "sdi.pro.annual.web")

    def test_invoice_paid_writes_a_charge_only_in_live_mode(self):
        period_end = NOW + dt.timedelta(days=30)
        invoice = {"id": "in_1", "object": "invoice", "status": "paid", "amount_paid": 499, "currency": "usd", "subscription": "sub_1",
                   "customer_email": "x@example.test", "hosted_invoice_url": "https://pay.example", "subscription_details": {"metadata": {"sdi_user_id": USER}},
                   "lines": {"data": [{"price": {"id": "price_creator"}, "period": {"start": int(NOW.timestamp()), "end": int(period_end.timestamp())}}]}}
        _, executor = stripe_handle(stripe_event("invoice.paid", invoice, livemode=True), config=LIVE_CONFIG)
        params = executor.only
        self.assertEqual(params["status"], "active")
        self.assertEqual(params["user_id"], USER)
        self.assertEqual(params["ledger"], [{"ref": "in_1", "kind": "charge", "amount_minor": 499, "currency": "USD"}])
        self.assertNotIn("hosted_invoice_url", params["payload"]["object"])
        _, executor = stripe_handle(stripe_event("invoice.paid", invoice))
        self.assertEqual(executor.only["ledger"], [])
        self.assertEqual(executor.only["status"], "active")

    def test_payment_failure_is_recorded_without_status_change(self):
        invoice = {"id": "in_2", "object": "invoice", "status": "open", "subscription": "sub_1", "amount_due": 499, "currency": "usd"}
        _, executor = stripe_handle(stripe_event("invoice.payment_failed", invoice))
        self.assertIsNone(executor.only["provider_subscription_id"])
        self.assertEqual(executor.only["event_type"], "invoice.payment_failed")

    def test_refunds_and_payouts_become_ledger_rows(self):
        charge = {"id": "ch_1", "object": "charge", "amount_refunded": 499, "currency": "usd",
                  "refunds": {"data": [{"id": "re_1", "amount": 499, "currency": "usd", "status": "succeeded"}, {"id": "re_2", "amount": 100, "currency": "usd", "status": "failed"}]}}
        _, executor = stripe_handle(stripe_event("charge.refunded", charge, livemode=True), config=LIVE_CONFIG)
        self.assertEqual(executor.only["ledger"], [{"ref": "re_1", "kind": "refund", "amount_minor": -499, "currency": "USD"}])
        _, executor = stripe_handle(stripe_event("charge.refunded", charge))
        self.assertEqual(executor.only["ledger"], [])
        payout = {"id": "po_1", "object": "payout", "amount": 12345, "currency": "usd", "status": "paid"}
        _, executor = stripe_handle(stripe_event("payout.paid", payout, livemode=True), config=LIVE_CONFIG)
        self.assertEqual(executor.only["ledger"], [{"ref": "po_1", "kind": "payout", "amount_minor": 12345, "currency": "USD"}])

    def test_checkout_completion_links_account_but_grants_nothing(self):
        session = {"id": "cs_1", "object": "checkout.session", "client_reference_id": USER, "subscription": "sub_9", "customer_details": {"email": "x@example.test"}}
        _, executor = stripe_handle(stripe_event("checkout.session.completed", session))
        params = executor.only
        self.assertEqual(params["user_id"], USER)
        self.assertIsNone(params["provider_subscription_id"])
        self.assertEqual(params["payload"]["subscription"], "sub_9")
        self.assertNotIn("customer_details", params["payload"]["object"])

    def test_mode_mismatch_unknown_type_and_malformed_event(self):
        response, executor = stripe_handle(stripe_event("customer.subscription.created", subscription_object(), livemode=True))
        self.assertEqual((response.status, response.body["error"]), (400, "live mode mismatch"))
        self.assertEqual(executor.calls, [])
        _, executor = stripe_handle(stripe_event("customer.created", {"id": "cus_1", "object": "customer", "email": "x@example.test"}))
        self.assertEqual(executor.only["payload"]["reason"], "event type recorded only")
        self.assertNotIn("email", executor.only["payload"]["object"])
        response, executor = stripe_handle({"id": "nope", "type": "x"})
        self.assertEqual(response.status, 400)
        self.assertEqual(executor.calls, [])

    def test_database_failure_returns_500_so_stripe_retries(self):
        response, _ = stripe_handle(stripe_event("customer.subscription.created", subscription_object()), executor=RecordingExecutor(raise_error=RuntimeError("down")))
        self.assertEqual(response.status, 500)
        self.assertEqual(response.body, {"error": "database unavailable"})

    def test_oversized_body_is_refused(self):
        raw = b"{" + b" " * stripe.MAX_BODY_BYTES + b"}"
        response = stripe.handle({"Stripe-Signature": stripe.sign(raw, SECRET, int(NOW.timestamp()))}, raw, executor=RecordingExecutor(), catalog=CATALOG, secret=SECRET, now=lambda: NOW)
        self.assertEqual(response.status, 413)


CHECKOUT_CONFIG = checkout.CheckoutConfig(website_origin="https://www.example.test")


def claims(**overrides):
    base = {"sub": USER, "aud": "authenticated", "role": "authenticated", "exp": NOW.timestamp() + 600}
    base.update(overrides)
    return base


def checkout_handle(body, token_claims=None, account_active=lambda user: True, customer_for_user=None, headers=None, verify=None):
    def verify_jwt(token):
        if verify:
            return verify(token)
        if token != "good-token":
            raise ValueError("bad token")
        return token_claims if token_claims is not None else claims()
    headers = {"Authorization": "Bearer good-token"} if headers is None else headers
    raw = body if isinstance(body, bytes) else json.dumps(body).encode()
    return checkout.handle(headers, raw, verify_jwt=verify_jwt, account_active=account_active, catalog=CATALOG, config=CHECKOUT_CONFIG,
                           customer_for_user=customer_for_user, now=lambda: NOW)


class StripeCheckoutTests(unittest.TestCase):
    def test_config_requires_an_https_origin(self):
        for origin in ("http://www.example.test", "https://www.example.test/shop", "https://user@www.example.test", "https://www.example.test/?x=1"):
            with self.assertRaises(ValueError, msg=origin):
                checkout.CheckoutConfig(website_origin=origin)

    def test_authentication_failures(self):
        self.assertEqual(checkout_handle({"action": "checkout"}, headers={}).status, 401)
        self.assertEqual(checkout_handle({"action": "checkout"}, headers={"Authorization": "Bearer other"}).status, 401)
        self.assertEqual(checkout_handle({"action": "checkout"}, token_claims=claims(is_anonymous=True)).status, 403)
        self.assertEqual(checkout_handle({"action": "checkout"}, token_claims=claims(exp=NOW.timestamp() - 1)).status, 401)
        self.assertEqual(checkout_handle({"action": "checkout"}, token_claims=claims(role="service_role")).status, 403)
        self.assertEqual(checkout_handle({"action": "checkout"}, token_claims=claims(aud="anon")).status, 401)
        response = checkout_handle({"action": "checkout"}, account_active=lambda user: False)
        self.assertEqual((response.status, response.body["error"]), (403, "account is not active"))

    def test_return_url_must_be_on_the_website_origin(self):
        for url in ("http://www.example.test/account", "https://evil.example/account", "https://www.example.test/a#frag",
                    "https://www.example.test.evil/", "https://user@www.example.test/", "", None, "https://www.example.test/ spaced"):
            response = checkout_handle({"action": "checkout", "product_id": "sdi.creator.monthly.web", "return_url": url})
            self.assertEqual(response.status, 400, url)

    def test_checkout_request_uses_configured_price_and_no_amount(self):
        response = checkout_handle({"action": "checkout", "product_id": "sdi.pro.monthly.web", "return_url": "https://www.example.test/account.html?tab=plan"})
        self.assertEqual(response.status, 200, response.body)
        self.assertFalse(response.body["livemode"])
        request = response.body["stripe_request"]
        self.assertEqual(request["path"], "/v1/checkout/sessions")
        form = request["form"]
        self.assertEqual(form["mode"], "subscription")
        self.assertEqual(form["line_items[0][price]"], "price_pro")
        self.assertEqual(form["client_reference_id"], USER)
        self.assertEqual(form["metadata[sdi_user_id]"], USER)
        self.assertEqual(form["subscription_data[metadata][sdi_product_id]"], "sdi.pro.monthly.web")
        self.assertTrue(form["success_url"].startswith("https://www.example.test/account.html?"))
        self.assertIn("session_id={CHECKOUT_SESSION_ID}", form["success_url"])
        self.assertIn("checkout=success", form["success_url"])
        self.assertIn("checkout=cancelled", form["cancel_url"])
        self.assertIn("tab=plan", form["cancel_url"])
        self.assertFalse(any("amount" in key or "price_data" in key for key in form))
        self.assertNotIn("sk_", json.dumps(response.body))
        again = checkout_handle({"action": "checkout", "product_id": "sdi.pro.monthly.web", "return_url": "https://www.example.test/account.html?tab=plan"})
        self.assertEqual(again.body["stripe_request"]["idempotency_key"], request["idempotency_key"])

    def test_unknown_and_annual_products_are_refused(self):
        response = checkout_handle({"action": "checkout", "product_id": "sdi.studio.monthly.web", "return_url": "https://www.example.test/"})
        self.assertEqual((response.status, response.body["error"]), (400, "unknown or unapproved product"))
        response = checkout_handle({"action": "checkout", "product_id": "sdi.creator.monthly", "return_url": "https://www.example.test/"})
        self.assertEqual(response.status, 400)   # an Apple product id is not a Stripe offer
        response = checkout_handle({"action": "checkout", "product_id": "sdi.pro.annual.web", "return_url": "https://www.example.test/"})
        self.assertEqual((response.status, response.body["error"]), (400, "annual offers are not available"))

    def test_portal_requires_a_known_customer(self):
        response = checkout_handle({"action": "portal", "return_url": "https://www.example.test/account.html"})
        self.assertEqual(response.status, 404)
        response = checkout_handle({"action": "portal", "return_url": "https://www.example.test/account.html"}, customer_for_user=lambda user: "cus_42")
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body["stripe_request"]["path"], "/v1/billing_portal/sessions")
        self.assertEqual(response.body["stripe_request"]["form"], {"customer": "cus_42", "return_url": "https://www.example.test/account.html"})

    def test_bad_bodies_and_actions(self):
        self.assertEqual(checkout_handle(b"nope").status, 400)
        self.assertEqual(checkout_handle(b"{" + b" " * checkout.MAX_BODY_BYTES + b"}").status, 413)
        response = checkout_handle({"action": "refund", "return_url": "https://www.example.test/"})
        self.assertEqual((response.status, response.body["error"]), (400, "unsupported action"))

    def test_client_response_exposes_only_the_hosted_url(self):
        self.assertEqual(checkout.client_response({"id": "cs_1", "url": "https://checkout.stripe.com/c/pay/cs_1", "client_secret": "x"}), {"url": "https://checkout.stripe.com/c/pay/cs_1"})
        with self.assertRaises(ContractError):
            checkout.client_response({"id": "cs_1"})


if __name__ == "__main__":
    unittest.main()

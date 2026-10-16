"""Offline tests for Spatter credit packs in backend/billing (owner decision
2026-10-15): Apple in-app redemption, Apple REFUND / ONE_TIME_CHARGE
notifications, Stripe one-time Checkout and the webhook grant/refund path. A
routing fake executor stands in for the database. No network, no secrets.

    python3 -m unittest discover -s backend/tests -t .
"""
import datetime as dt
import json
import re
import unittest
import uuid

from backend.billing import appstore_credits as credits_api
from backend.billing import appstore_notifications as apple
from backend.billing import stripe_checkout as checkout
from backend.billing import stripe_webhook as stripe
from backend.billing.contract import (CREDIT_GRANT_RPC, CREDIT_REFUND_RPC, APPLY_EVENT_RPC, ContractError, CreditPack,
                                      CreditPackCatalog, grant_credits, refund_credits)
from backend.tests.test_billing import (APPLE_CONFIG, CATALOG, CHECKOUT_CONFIG, LIVE_CONFIG, NOW, REPO, SECRET, STRIPE_CONFIG, USER,
                                        FakeVerifier, claims, jws, notification, stripe_event)

OTHER_USER = "11111111-2222-4333-8444-555555555555"
PACKS = CreditPackCatalog([
    CreditPack("sdi.credits.50", "apple", 50),
    CreditPack("sdi.credits.50.web", "stripe", 50, stripe_price_id="price_credits_50"),
])
MS = 1000


class CreditDB:
    """Routes the service-role RPCs: records every call and answers like the SQL."""

    def __init__(self, grant=None, refund=None, apply=None, fail=None):
        self.calls = []
        self.grant = grant or {"status": "granted", "credits_added": 50, "credits": 50, "livemode": True}
        self.refund = refund or {"status": "refunded", "clawed_back": 49, "shortfall": 1, "credits": 0}
        self.apply = apply or {"event": str(uuid.uuid4()), "outcome": "applied", "note": "", "subscription": None}
        self.fail = fail

    def __call__(self, name, params):
        self.calls.append((name, params))
        if self.fail == name:
            raise RuntimeError("database down")
        return {CREDIT_GRANT_RPC: self.grant, CREDIT_REFUND_RPC: self.refund}.get(name, self.apply)

    def named(self, name):
        return [params for called, params in self.calls if called == name]


def consumable(**overrides):
    base = {"type": "Consumable", "productId": "sdi.credits.50", "transactionId": "2000000001", "originalTransactionId": "2000000001",
            "appAccountToken": USER, "purchaseDate": int((NOW - dt.timedelta(minutes=1)).timestamp() * MS),
            "bundleId": APPLE_CONFIG.bundle_id, "environment": APPLE_CONFIG.environment, "price": 1990, "currency": "USD"}
    base.update(overrides)
    return base


def redeem(tx=None, db=None, token_claims=None, verifier=None, config=APPLE_CONFIG, active=True, raw=None):
    db = db or CreditDB()
    body = raw if raw is not None else json.dumps({"signedTransaction": jws(tx if tx is not None else consumable())}).encode()
    response = credits_api.handle({"Authorization": "Bearer good"}, body, verify_jwt=lambda _t: token_claims or claims(),
                                  account_active=lambda _u: active, executor=db, packs=PACKS, config=config,
                                  verifier=FakeVerifier() if verifier is None else verifier, now=lambda: NOW)
    return response, db


class ContractTests(unittest.TestCase):
    def test_rpc_parameters_match_the_sql_functions(self):
        sql = (REPO / "backend/sql/spatter-draft-jobs.sql").read_text()
        for name, call in ((CREDIT_GRANT_RPC, lambda db: grant_credits(db, USER, "apple", "p", "t", True)),
                           (CREDIT_REFUND_RPC, lambda db: refund_credits(db, "apple", "t"))):
            match = re.search(r"create function public\.%s\((.*?)\) returns jsonb" % name, sql, re.S)
            self.assertIsNotNone(match, name)
            names = [p.strip().split()[0] for p in match.group(1).split(",")]
            db = CreditDB()
            call(db)
            self.assertEqual(list(db.calls[0][1]), names)

    def test_pack_rules_and_catalogue(self):
        for bad in (dict(product_id="", provider="apple", credits=1), dict(product_id="x", provider="google", credits=1),
                    dict(product_id="x", provider="apple", credits=0), dict(product_id="x", provider="stripe", credits=5),
                    dict(product_id="x", provider="apple", credits=5, stripe_price_id="price_x")):
            with self.assertRaises(ValueError, msg=bad):
                CreditPack(**bad)
        catalog = CreditPackCatalog.from_rows([
            {"product_id": "a", "provider": "apple", "credits": 10, "approved": True},
            {"product_id": "b", "provider": "apple", "credits": 10, "approved": False},
            {"product_id": "g", "provider": "google", "credits": 10, "approved": True},
            {"product_id": "w", "provider": "stripe", "credits": 20, "approved": True}], {"w": "price_w"})
        self.assertIsNotNone(catalog.get("apple", "a"))
        self.assertIsNone(catalog.get("apple", "b"))
        self.assertIsNone(catalog.get("google", "g"))   # no Play verification path yet
        self.assertEqual(catalog.by_stripe_price("price_w").credits, 20)

    def test_database_failures_and_unknown_results_are_500(self):
        with self.assertRaises(ContractError) as caught:
            grant_credits(CreditDB(fail=CREDIT_GRANT_RPC), USER, "apple", "p", "t", True)
        self.assertEqual(caught.exception.status, 500)
        with self.assertRaises(ContractError):
            grant_credits(lambda _n, _p: {"status": "maybe"}, USER, "apple", "p", "t", True)
        with self.assertRaises(ContractError):
            grant_credits(CreditDB(), "not-a-user", "apple", "p", "t", True)


class AppleRedemptionTests(unittest.TestCase):
    def test_verified_consumable_is_granted_once_per_transaction(self):
        response, db = redeem()
        self.assertEqual(response.status, 200, response.body)
        self.assertEqual(response.body, {"status": "granted", "credits": 50, "credits_added": 50})
        self.assertEqual(db.named(CREDIT_GRANT_RPC), [{"p_user": USER, "p_provider": "apple", "p_product_id": "sdi.credits.50",
                                                        "p_transaction_ref": "2000000001", "p_livemode": True}])
        response, _ = redeem(db=CreditDB(grant={"status": "duplicate", "credits": 50}))
        self.assertEqual((response.status, response.body["status"], response.body["credits_added"]), (200, "duplicate", 0))

    def test_sandbox_is_granted_but_flagged(self):
        config = apple.AppStoreConfig(bundle_id=APPLE_CONFIG.bundle_id, environment="Sandbox", trusted_roots=APPLE_CONFIG.trusted_roots)
        _, db = redeem(consumable(environment="Sandbox"), config=config)
        self.assertFalse(db.named(CREDIT_GRANT_RPC)[0]["p_livemode"])

    def test_refusals_never_grant(self):
        cases = [
            (dict(tx=consumable(appAccountToken=OTHER_USER)), 403),
            (dict(tx=consumable(productId="sdi.credits.unknown")), 400),
            (dict(tx=consumable(type="Auto-Renewable Subscription")), 400),
            (dict(tx=consumable(bundleId="com.other.app")), 400),
            (dict(tx=consumable(environment="Sandbox")), 400),
            (dict(tx=consumable(revocationDate=int(NOW.timestamp() * MS))), 409),
            (dict(tx=consumable(transactionId=None)), 400),
            (dict(verifier=FakeVerifier(ok=False)), 400),
            (dict(raw=b'{"signedTransaction": "a.b"}'), 400),
            (dict(active=False), 403),
            (dict(token_claims=claims(exp=NOW.timestamp() - 1)), 401),
            (dict(token_claims=claims(is_anonymous=True)), 403),
        ]
        for kwargs, status in cases:
            response, db = redeem(**kwargs)
            self.assertEqual(response.status, status, (kwargs, response.body))
            self.assertEqual(db.named(CREDIT_GRANT_RPC), [], kwargs)
        response, _ = redeem(db=CreditDB(grant={"status": "refused", "reason": "Transaction was refunded."}))
        self.assertEqual(response.status, 409)

    def test_missing_verifier_fails_closed(self):
        response = credits_api.handle({"Authorization": "Bearer good"}, json.dumps({"signedTransaction": jws(consumable())}).encode(),
                                      verify_jwt=lambda _t: claims(), account_active=lambda _u: True, executor=CreditDB(), packs=PACKS,
                                      config=APPLE_CONFIG, verifier=None, now=lambda: NOW)
        self.assertEqual(response.status, 503)


class AppleNotificationCreditTests(unittest.TestCase):
    def run_note(self, kind, tx, packs=PACKS, db=None):
        db = db or CreditDB()
        response = apple.handle({}, notification(kind, transaction=tx), executor=db, catalog=CATALOG, config=APPLE_CONFIG,
                                verifier=FakeVerifier(), credit_packs=packs, now=lambda: NOW)
        return response, db

    def test_refund_claws_back_credits(self):
        response, db = self.run_note("REFUND", consumable(revocationDate=int(NOW.timestamp() * MS)))
        self.assertEqual(response.status, 200)
        self.assertEqual(db.named(CREDIT_REFUND_RPC), [{"p_provider": "apple", "p_transaction_ref": "2000000001"}])
        self.assertEqual(response.body["credits"]["clawed_back"], 49)
        self.assertEqual(len(db.named(APPLY_EVENT_RPC)), 1)   # the notification is still recorded

    def test_one_time_charge_grants_and_duplicates_still_settle(self):
        db = CreditDB(apply={"duplicate": True})
        response, db = self.run_note("ONE_TIME_CHARGE", consumable(), db=db)
        self.assertEqual(response.body["duplicate"], True)
        self.assertEqual(db.named(CREDIT_GRANT_RPC)[0]["p_user"], USER)

    def test_unrelated_or_unconfigured_notifications_touch_no_credits(self):
        for kind, tx, packs in (("REFUND", consumable(productId="sdi.other"), PACKS), ("REFUND", consumable(), None),
                                ("ONE_TIME_CHARGE", consumable(appAccountToken=None), PACKS)):
            _, db = self.run_note(kind, tx, packs=packs)
            self.assertEqual(db.named(CREDIT_GRANT_RPC) + db.named(CREDIT_REFUND_RPC), [], (kind, tx.get("productId"), packs))


def credit_session(**overrides):
    obj = {"id": "cs_credit", "object": "checkout.session", "mode": "payment", "payment_status": "paid", "client_reference_id": USER,
           "payment_intent": "pi_credit_1", "amount_total": 199, "currency": "usd", "metadata": {"sdi_user_id": USER, "sdi_credit_pack": "sdi.credits.50.web"},
           "customer_details": {"email": "x@example.test"}}
    obj.update(overrides)
    return obj


def webhook(event, db=None, config=STRIPE_CONFIG, packs=PACKS):
    db = db or CreditDB()
    raw = json.dumps(event).encode()
    response = stripe.handle({"Stripe-Signature": stripe.sign(raw, SECRET, int(NOW.timestamp()))}, raw, executor=db, catalog=CATALOG,
                             secret=SECRET, config=config, credit_packs=packs, now=lambda: NOW)
    return response, db


class StripeCreditTests(unittest.TestCase):
    def test_paid_session_grants_by_payment_intent_and_records_a_live_charge(self):
        response, db = webhook(stripe_event("checkout.session.completed", credit_session(), livemode=True), config=LIVE_CONFIG)
        self.assertEqual(response.status, 200)
        self.assertEqual(db.named(CREDIT_GRANT_RPC), [{"p_user": USER, "p_provider": "stripe", "p_product_id": "sdi.credits.50.web",
                                                        "p_transaction_ref": "pi_credit_1", "p_livemode": True}])
        applied = db.named(APPLY_EVENT_RPC)[0]
        self.assertEqual(applied["ledger"], [{"ref": "pi_credit_1", "kind": "charge", "amount_minor": 199, "currency": "USD"}])
        self.assertIsNone(applied["provider_subscription_id"])
        self.assertNotIn("customer_details", applied["payload"]["object"])
        self.assertEqual(response.body["credits"]["status"], "granted")

    def test_test_mode_grants_flagged_without_revenue_rows(self):
        _, db = webhook(stripe_event("checkout.session.completed", credit_session()))
        self.assertFalse(db.named(CREDIT_GRANT_RPC)[0]["p_livemode"])
        self.assertEqual(db.named(APPLY_EVENT_RPC)[0]["ledger"], [])

    def test_unpaid_unapproved_or_subscription_sessions_grant_nothing(self):
        for obj in (credit_session(payment_status="unpaid"), credit_session(metadata={"sdi_credit_pack": "sdi.credits.unknown"}),
                    credit_session(mode="subscription", subscription="sub_9"), credit_session(payment_intent=None),
                    credit_session(client_reference_id=None, metadata={"sdi_credit_pack": "sdi.credits.50.web"})):
            _, db = webhook(stripe_event("checkout.session.completed", obj))
            self.assertEqual(db.named(CREDIT_GRANT_RPC), [], obj)
        _, db = webhook(stripe_event("checkout.session.completed", credit_session()), packs=None)
        self.assertEqual(db.named(CREDIT_GRANT_RPC), [])

    def test_async_payment_success_grants(self):
        _, db = webhook(stripe_event("checkout.session.async_payment_succeeded", credit_session()))
        self.assertEqual(len(db.named(CREDIT_GRANT_RPC)), 1)

    def test_full_refund_claws_back_partial_does_not(self):
        charge = {"id": "ch_1", "object": "charge", "payment_intent": "pi_credit_1", "amount": 199, "amount_refunded": 199,
                  "refunded": True, "currency": "usd"}
        _, db = webhook(stripe_event("charge.refunded", charge))
        self.assertEqual(db.named(CREDIT_REFUND_RPC), [{"p_provider": "stripe", "p_transaction_ref": "pi_credit_1"}])
        _, db = webhook(stripe_event("charge.refunded", dict(charge, refunded=False, amount_refunded=50)))
        self.assertEqual(db.named(CREDIT_REFUND_RPC), [])

    def test_grant_failure_returns_500_so_stripe_retries(self):
        response, _ = webhook(stripe_event("checkout.session.completed", credit_session()), db=CreditDB(fail=CREDIT_GRANT_RPC))
        self.assertEqual((response.status, response.body), (500, {"error": "database unavailable"}))


class StripeCreditCheckoutTests(unittest.TestCase):
    def run_checkout(self, body, packs=PACKS):
        return checkout.handle({"Authorization": "Bearer good"}, json.dumps(body).encode(), verify_jwt=lambda _t: claims(),
                               account_active=lambda _u: True, catalog=CATALOG, config=CHECKOUT_CONFIG, credit_packs=packs, now=lambda: NOW)

    def test_one_time_payment_for_an_approved_pack_only(self):
        response = self.run_checkout({"action": "credits", "pack_id": "sdi.credits.50.web", "return_url": "https://www.example.test/account.html"})
        self.assertEqual(response.status, 200, response.body)
        form = response.body["stripe_request"]["form"]
        self.assertEqual((form["mode"], form["line_items[0][price]"], form["client_reference_id"]), ("payment", "price_credits_50", USER))
        self.assertEqual(form["metadata[sdi_credit_pack]"], "sdi.credits.50.web")
        self.assertEqual(form["payment_intent_data[metadata][sdi_user_id]"], USER)
        self.assertFalse(any("amount" in key or "price_data" in key or "subscription" in key for key in form))
        for pack_id, packs in (("sdi.creator.monthly.web", PACKS), ("sdi.credits.50", PACKS), ("sdi.credits.50.web", None), (7, PACKS)):
            response = self.run_checkout({"action": "credits", "pack_id": pack_id, "return_url": "https://www.example.test/"}, packs=packs)
            self.assertEqual((response.status, response.body["error"]), (400, "unknown or unapproved credit pack"), pack_id)


if __name__ == "__main__":
    unittest.main()

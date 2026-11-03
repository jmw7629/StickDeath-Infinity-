"""Offline production-handler/crypto boundaries. Never opens a socket or uses credentials."""
import base64
import copy
import datetime as dt
import hashlib
import json
import math
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs

from backend.billing.contract import ContractError, PROVIDERS
from backend.billing.google_play import (ApprovedPlayProduct, GooglePlayVerifier, PlayVerificationConfig, account_binding, handle)
from backend.billing.google_play_transport import (GoogleHttpsTransport, HttpResponse, MAX_RESPONSE_BYTES, PUBLISHER_SCOPE,
    PublisherAccessToken, TOKEN_URL, _NoRedirect, json_object)

USER = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
PACKAGE = "com.stickdeath.studio"
NOW = 1_793_664_000.0
BINDING = b"unit-test-only-account-binding-key"  # synthetic, not a provider secret
TOKEN = "synthetic-purchase-token"
PRODUCT = ApprovedPlayProduct("sdi.creator", "monthly", "creator")


def encoded(value):
    return json.dumps(value, separators=(",", ":")).encode()


def stamp(seconds):
    return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).isoformat().replace("+00:00", "Z")


def purchase(state="ACTIVE", phase="basePrice", expiry=NOW + 3600):
    item = {"productId": PRODUCT.product_id, "offerDetails": {"basePlanId": PRODUCT.base_plan_id},
            "autoRenewingPlan": {"autoRenewEnabled": state not in ("CANCELED", "EXPIRED")}}
    if expiry is not None:
        item["expiryTime"] = stamp(expiry)
    if phase is not None:
        item["offerPhase"] = {phase: {}}
    return {"kind": "androidpublisher#subscriptionPurchaseV2", "subscriptionState": "SUBSCRIPTION_STATE_" + state,
            "acknowledgementState": "ACKNOWLEDGEMENT_STATE_PENDING", "lineItems": [item],
            "externalAccountIdentifiers": {"obfuscatedExternalAccountId": account_binding(USER, PACKAGE, BINDING)}}


class Secrets:
    def __init__(self, account):
        self.values, self.reads = {"account": encoded(account), "binding": BINDING}, []
    def read(self, reference):
        self.reads.append(reference)
        return self.values[reference]


class Transport:
    def __init__(self, resource=None):
        self.resource = resource if resource is not None else purchase()
        self.requests = []
        self.status = 200
        self.on_get = None
        self.oauth = {"access_token": "synthetic-access-token", "token_type": "Bearer", "expires_in": 3600}
    def request(self, method, url, headers, body, timeout, maximum_bytes):
        self.requests.append((method, url, dict(headers), body, timeout, maximum_bytes))
        if url == TOKEN_URL:
            return HttpResponse(200, encoded(self.oauth))
        if self.on_get:
            self.on_get()
        return HttpResponse(self.status, encoded(self.resource))


class GooglePlayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives import serialization
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        cls.account = {"type": "service_account", "private_key_id": "synthetic-key-id",
            "private_key": cls.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode(),
            "client_email": "billing@synthetic-project.iam.gserviceaccount.com", "token_uri": TOKEN_URL}

    def fixture(self, resource=None, **config):
        secrets, transport = Secrets(self.account), Transport(resource)
        options = dict(products=(PRODUCT,), enabled=True, service_account_secret="account", account_binding_secret="binding")
        options.update(config)
        verifier = GooglePlayVerifier(PlayVerificationConfig(PACKAGE, **options), secrets, transport, lambda: NOW)
        return verifier, secrets, transport

    def response(self, verifier, raw=None, claims=None, active=None, permit=None, bearer="Bearer synthetic-member-jwt"):
        if claims is None:
            claims = {"sub": USER, "aud": "authenticated", "role": "authenticated", "exp": NOW + 60}
        return handle({"Authorization": bearer}, encoded({"purchase_token": TOKEN}) if raw is None else raw,
            verify_jwt=lambda _: claims, account_active=active or (lambda _: True), verifier=verifier,
            permit_query=permit or (lambda _: True), now=lambda: dt.datetime.fromtimestamp(NOW, dt.timezone.utc))

    def test_default_off_and_missing_runtime_never_read_secrets_or_call_google(self):
        v, secrets, transport = self.fixture(enabled=False)
        self.assertEqual(self.response(v).status, 503)
        self.assertFalse(secrets.reads); self.assertFalse(transport.requests)
        v, secrets, transport = self.fixture()
        result = handle({"Authorization": "Bearer test"}, encoded({"purchase_token": TOKEN}),
            verify_jwt=lambda _: {"sub": USER, "aud": "authenticated", "role": "authenticated", "exp": NOW + 10},
            account_active=lambda _: True, verifier=v, now=lambda: dt.datetime.fromtimestamp(NOW, dt.timezone.utc))
        self.assertEqual(result.status, 503); self.assertFalse(secrets.reads); self.assertFalse(transport.requests)
        v = GooglePlayVerifier(PlayVerificationConfig(PACKAGE))
        self.assertFalse(v.configured)
        self.assertEqual(PROVIDERS, ("apple", "stripe"))  # no accidental SQL/provider activation

    def test_auth_body_and_limiter_fail_closed_before_provider_or_secret(self):
        cases = [({"sub": USER, "aud": "authenticated", "role": "authenticated", "exp": math.inf}, None, 401),
                 ({"sub": USER, "aud": "authenticated", "role": "authenticated", "exp": True}, None, 401),
                 ({"sub": USER, "aud": "authenticated", "role": "service_role", "exp": NOW + 60}, None, 401),
                 ({"sub": USER, "aud": "authenticated", "role": "authenticated", "exp": NOW - 1}, None, 401),
                 ({"sub": USER, "aud": "authenticated", "role": "authenticated", "is_anonymous": True, "exp": NOW + 60}, None, 403),
                 (None, encoded({"purchase_token": TOKEN, "user_id": OTHER, "tier": "unlimited"}), 400),
                 (None, b'{"purchase_token":"one","purchase_token":"two"}', 400),
                 (None, encoded({"purchase_token": "unsafe\nvalue"}), 400),
                 (None, b"x" * 8193, 413)]
        for claims, raw, status in cases:
            with self.subTest(status=status, raw_size=len(raw or b"")):
                v, secrets, transport = self.fixture()
                self.assertEqual(self.response(v, raw=raw, claims=claims).status, status)
                self.assertFalse(transport.requests); self.assertFalse(secrets.reads)
        for options, status in [({"active": lambda _: False}, 403), ({"permit": lambda _: False}, 429), ({"bearer": ""}, 401)]:
            v, secrets, transport = self.fixture()
            self.assertEqual(self.response(v, **options).status, status)
            self.assertFalse(transport.requests); self.assertFalse(secrets.reads)

    def test_real_rs256_assertion_has_exact_publisher_scope_and_bounded_request(self):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import padding
        v, _, transport = self.fixture()
        first = v.inspect(USER, TOKEN); second = v.inspect(USER, TOKEN)
        self.assertEqual(first, second)
        self.assertEqual([r[0] for r in transport.requests], ["POST", "GET", "GET"])
        post = transport.requests[0]
        assertion = parse_qs(post[3].decode())["assertion"][0]
        a, b, signature = assertion.split(".")
        decode = lambda value: base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        self.key.public_key().verify(decode(signature), (a + "." + b).encode(), padding.PKCS1v15(), hashes.SHA256())
        header, claims = json.loads(decode(a)), json.loads(decode(b))
        self.assertEqual(header["alg"], "RS256"); self.assertEqual(claims["scope"], PUBLISHER_SCOPE)
        self.assertNotIn("firebase", claims["scope"]); self.assertNotIn("sub", claims)
        self.assertEqual(claims["aud"], TOKEN_URL); self.assertEqual(claims["exp"] - claims["iat"], 3600)
        get = transport.requests[1]
        self.assertEqual(get[1], "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/" + PACKAGE + "/purchases/subscriptionsv2/tokens/" + TOKEN)
        self.assertEqual(get[2]["Authorization"], "Bearer synthetic-access-token")
        self.assertIsNone(get[3]); self.assertEqual(get[4], 10); self.assertEqual(get[5], MAX_RESPONSE_BYTES)
        self.assertNotIn(TOKEN, repr(first)); self.assertNotIn(TOKEN, json.dumps(first.public_result()))

    def test_token_credentials_scope_responses_and_errors_are_sanitized(self):
        for change in [{"token_uri": "https://evil.invalid/token"}, {"type": "authorized_user"},
                       {"client_email": "person@example.test"}, {"private_key": "not a key"}]:
            v, secrets, transport = self.fixture(); account = dict(self.account); account.update(change); secrets.values["account"] = encoded(account)
            result = self.response(v)
            self.assertEqual(result.status, 503); self.assertFalse(transport.requests)
            self.assertNotIn("private_key", result.json()); self.assertNotIn("evil.invalid", result.json())
        for change in [{"token_type": None}, {"expires_in": True}, {"expires_in": 3601}, {"scope": "https://www.googleapis.com/auth/firebase.messaging"}, {"access_token": "bad\r\ntoken"}]:
            v, _, transport = self.fixture(); transport.oauth.update(change)
            self.assertEqual(self.response(v).status, 502)
            self.assertEqual(len(transport.requests), 1)

    def test_stable_package_bound_hmac_is_required_not_user_or_metadata(self):
        expected = account_binding(USER, PACKAGE, BINDING)
        self.assertEqual(len(expected), 64); self.assertEqual(expected, account_binding(USER.upper(), PACKAGE, BINDING))
        self.assertNotEqual(expected, account_binding(OTHER, PACKAGE, BINDING))
        self.assertNotEqual(expected, account_binding(USER, PACKAGE + ".other", BINDING))
        for bad in [OTHER, USER, "雪", "", None]:
            data = purchase(); data["externalAccountIdentifiers"]["obfuscatedExternalAccountId"] = bad
            v, _, _ = self.fixture(data); self.assertEqual(self.response(v).status, 403)
        data = purchase(); data.pop("externalAccountIdentifiers")
        data["subscribeWithGoogleInfo"] = {"emailAddress": "creator@example.test"}
        v, _, _ = self.fixture(data); self.assertEqual(self.response(v).status, 403)

    def test_trial_paid_phase_and_lifecycle_snapshots_never_grant_or_ack(self):
        for state, phase, expiry, access, trial in [
            ("ACTIVE", "freeTrial", NOW + 50, True, True), ("ACTIVE", "basePrice", NOW + 50, True, False),
            ("ACTIVE", "introductoryPrice", NOW + 50, True, False), ("ACTIVE", None, NOW + 50, False, None),
            ("ACTIVE", "prorationPeriod", NOW + 50, False, None), ("ACTIVE", "basePrice", NOW - 1, False, False),
            ("IN_GRACE_PERIOD", "basePrice", NOW + 50, True, False), ("CANCELED", "basePrice", NOW + 50, True, False),
            ("CANCELED", "freeTrial", NOW + 50, True, True), ("EXPIRED", "basePrice", NOW + 50, False, False),
            ("PAUSED", "basePrice", NOW + 50, False, False), ("ON_HOLD", "freeTrial", NOW + 50, False, True),
            ("PENDING", None, None, False, None), ("PENDING_PURCHASE_CANCELED", None, None, False, None)]:
            with self.subTest(state=state, phase=phase):
                v, _, transport = self.fixture(purchase(state, phase, expiry)); response = self.response(v)
                self.assertEqual(response.status, 200, response.body)
                self.assertEqual(response.body["inTrial"], trial); self.assertEqual(response.body["snapshotAccess"], access)
                self.assertFalse(response.body["entitlementApplied"]); self.assertFalse(response.body["acknowledgementPerformed"])
                self.assertFalse(response.body["reconciliationAvailable"]); self.assertTrue(response.body["verificationOnly"])
                self.assertEqual([r[0] for r in transport.requests], ["POST", "GET"])

    def test_unknown_offer_malformed_and_complex_provider_states_never_become_paid(self):
        changes = [lambda r: r.update(subscriptionState="ACTIVE"), lambda r: r.update(subscriptionState="SUBSCRIPTION_STATE_NEW"),
            lambda r: r.update(acknowledgementState={}), lambda r: r["lineItems"][0].update(expiryTime="not-a-date"),
            lambda r: r["lineItems"][0].update(offerPhase={"freeTrial": {}, "basePrice": {}}),
            lambda r: r["lineItems"][0].update(offerPhase={"invented": {}}),
            lambda r: r["lineItems"][0]["autoRenewingPlan"].update(autoRenewEnabled=False),
            lambda r: r["lineItems"][0].update(productId="unapproved"),
            lambda r: r["lineItems"][0]["offerDetails"].update(basePlanId="unapproved"),
            lambda r: r["lineItems"].append(copy.deepcopy(r["lineItems"][0])),
            lambda r: r["lineItems"][0].update(prepaidPlan={}),
            lambda r: r["lineItems"][0]["autoRenewingPlan"].update(installmentDetails={})]
        for mutate in changes:
            data = purchase(); mutate(data); v, _, _ = self.fixture(data)
            result = self.response(v); self.assertIn(result.status, (409, 502)); self.assertFalse(result.body["entitlementApplied"])

    def test_linked_token_and_deferred_replacements_require_atomic_reconciliation(self):
        for key in ["linkedPurchaseToken", "itemReplacement", "deferredItemReplacement", "deferredItemRemoval"]:
            data = purchase()
            if key == "linkedPurchaseToken": data[key] = "synthetic-old-token"
            else: data["lineItems"][0][key] = {}
            v, _, _ = self.fixture(data); observation = v.inspect(USER, TOKEN)
            self.assertTrue(observation.linked_reconciliation_required); self.assertFalse(observation.snapshot_access)
            self.assertNotIn("synthetic-old-token", repr(observation)); self.assertNotIn("synthetic-old-token", json.dumps(observation.public_result()))

    def test_test_purchase_separation_expiry_and_ack_state(self):
        data = purchase(); data["testPurchase"] = {}
        v, _, _ = self.fixture(data); self.assertEqual(self.response(v).status, 409)
        v, _, _ = self.fixture(data, allow_test_purchases=True)
        result = self.response(v); self.assertEqual(result.status, 200); self.assertTrue(result.body["testPurchase"])
        data = purchase(); data["acknowledgementState"] = "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED"
        v, _, _ = self.fixture(data); self.assertFalse(self.response(v).body["acknowledgementPending"])
        data["lineItems"][0]["expiryTime"] = stamp(NOW)
        v, _, _ = self.fixture(data); self.assertFalse(v.inspect(USER, TOKEN).snapshot_access)

    def test_no_automatic_retry_and_provider_401_invalidates_cached_token(self):
        v, _, transport = self.fixture(); transport.status = 401
        self.assertEqual(self.response(v).status, 502); self.assertEqual(len(transport.requests), 2)
        transport.status = 200
        self.assertEqual(self.response(v).status, 200)
        self.assertEqual([r[0] for r in transport.requests], ["POST", "GET", "POST", "GET"])
        for status in [403, 404, 410, 429, 500]:
            v, _, transport = self.fixture(); transport.status = status
            response = self.response(v); self.assertEqual(response.status, 409 if status in (404, 410) else 502)
            self.assertNotIn(TOKEN, response.json()); self.assertEqual(len(transport.requests), 2)

    def test_account_disabled_during_query_cannot_receive_inspection(self):
        v, _, transport = self.fixture(); active = [True]
        transport.on_get = lambda: active.__setitem__(0, False)
        response = self.response(v, active=lambda _: active[0])
        self.assertEqual(response.status, 403); self.assertFalse(response.body["entitlementApplied"])

    def test_snapshot_fingerprint_is_stable_private_and_changes_on_real_state(self):
        v, _, transport = self.fixture(); first = v.inspect(USER, TOKEN); repeated = v.inspect(USER, TOKEN)
        self.assertEqual(first.fingerprint, repeated.fingerprint)
        self.assertEqual(first.token_reference, "gp:" + hashlib.sha256(TOKEN.encode()).hexdigest())
        transport.resource["acknowledgementState"] = "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED"
        self.assertNotEqual(first.fingerprint, v.inspect(USER, TOKEN).fingerprint)
        self.assertNotIn(first.fingerprint, json.dumps(first.public_result()))
        self.assertNotIn(first.token_reference, json.dumps(first.public_result()))

    def test_json_budgets_redirect_refusal_and_transport_host_policy(self):
        for raw in [b'{"x":NaN}', b'{"x":1,"x":2}', b"[]", b"{" + b" " * 100 + b"}"]:
            with self.assertRaises(ContractError): json_object(raw, 80)
        nested = b'{"x":' * 20 + b"0" + b"}" * 20
        with self.assertRaises(ContractError): json_object(nested, 4096)
        self.assertIsNone(_NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.invalid"))
        sender = GoogleHttpsTransport()
        with patch("urllib.request.build_opener") as opener:
            for method, url in [("GET", "http://androidpublisher.googleapis.com/x"), ("GET", "https://evil.invalid/x"),
                ("GET", "https://androidpublisher.googleapis.com:443/x"), ("POST", "https://androidpublisher.googleapis.com/x"),
                ("DELETE", TOKEN_URL), ("GET", "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/com.test/purchases/subscriptionsv2/tokens/t?target=evil")]:
                with self.assertRaises(ContractError): sender.request(method, url, {}, None, 10, 1024)
            opener.assert_not_called()


    def test_https_adapter_bounds_read_and_never_follows_a_redirect(self):
        from unittest.mock import MagicMock
        sender = GoogleHttpsTransport()
        fake = MagicMock(); fake.status = 200; fake.read.return_value = b"x" * 1025
        opener = MagicMock(); opener.open.return_value.__enter__.return_value = fake
        with patch("urllib.request.build_opener", return_value=opener):
            with self.assertRaises(ContractError):
                sender.request("POST", TOKEN_URL, {}, b"fixture", 10, 1024)
            fake.read.assert_called_once_with(1025)
            self.assertEqual(opener.open.call_args.kwargs["timeout"], 10)

    def test_provider_profile_and_token_never_escape_in_public_result(self):
        data = purchase()
        data["subscribeWithGoogleInfo"] = {"emailAddress": "private@example.test", "profileName": "Private Person"}
        data["lineItems"][0]["autoRenewingPlan"]["recurringPrice"] = {"currencyCode": "USD", "units": "999"}
        v, _, _ = self.fixture(data); response = self.response(v)
        self.assertEqual(response.status, 200)
        for private in ["private@example.test", "Private Person", "999", TOKEN, "synthetic-access-token"]:
            self.assertNotIn(private, response.json())



if __name__ == "__main__":
    unittest.main()

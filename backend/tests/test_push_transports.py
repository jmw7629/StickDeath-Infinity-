"""APNs and FCM transport tests (#290). Keys are generated per test run; every
HTTP exchange goes to an in-memory fake sender. No network, device or provider."""
import base64
import json
import os
import tempfile
import unittest
import urllib.parse
from pathlib import Path

from backend.notifications import push
from backend.notifications.push import (ApnsTransport, FcmTransport, NotConfigured, PushBatchWorker, RoutingTransport,
                                        SinkTransport, transport_from_environment)

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
    from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
except ImportError:  # pragma: no cover
    ec = None

IOS_TOKEN = "ab" * 32
ANDROID_TOKEN = "fcm-registration-token-" + "x" * 40


def unb64(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class FakeSender:
    available = True

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def post(self, url, headers, body, timeout):
        self.requests.append({"url": url, "headers": dict(headers), "body": body})
        status, payload = self.responses.pop(0)
        return status, {}, json.dumps(payload).encode() if not isinstance(payload, bytes) else payload


class FakeAPI:
    def __init__(self, claim):
        self.claim = claim
        self.calls = []

    def call(self, operation, **payload):
        self.calls.append((operation, payload))
        if operation == "claim":
            return self.claim
        return {"sent": sum(r["ok"] for r in payload["results"]), "failed": sum(not r["ok"] for r in payload["results"])}


@unittest.skipIf(ec is None, "cryptography not installed")
class TransportTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        os.chmod(self.dir, 0o700)
        self.ec_key = ec.generate_private_key(ec.SECP256R1())
        (self.dir / "apns.p8").write_bytes(self.ec_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        self.rsa_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        pem = self.rsa_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
        (self.dir / "fcm.json").write_text(json.dumps({"type": "service_account", "client_email": "push@example-project.iam.gserviceaccount.com",
                                                       "private_key": pem, "token_uri": push.GOOGLE_TOKEN_URL}))
        self.clock = [1_800_000_000.0]
        self.env = {"SDI_APNS_KEY_ID": "KEYID12345", "SDI_APNS_TEAM_ID": "TEAMID1234", "SDI_APNS_KEY_FILE": str(self.dir / "apns.p8"),
                    "SDI_APNS_TOPIC": "com.example.stickdeath", "SDI_FCM_PROJECT_ID": "example-project",
                    "SDI_FCM_SERVICE_ACCOUNT_FILE": str(self.dir / "fcm.json")}

    def apns(self, responses):
        sender = FakeSender(responses)
        return ApnsTransport.from_environment(self.env, sender, clock=lambda: self.clock[0]), sender

    def fcm(self, responses):
        sender = FakeSender(responses)
        return FcmTransport.from_environment(self.env, sender, clock=lambda: self.clock[0]), sender

    def test_apns_request_shape_and_verifiable_es256_token(self):
        transport, sender = self.apns([(200, {})])
        self.assertTrue(transport.configured)
        self.assertEqual(transport.send("ios", "sandbox", IOS_TOKEN, "New challenge", "Starts today"), (True, ""))
        request = sender.requests[0]
        self.assertEqual(request["url"], "https://api.sandbox.push.apple.com/3/device/" + IOS_TOKEN)
        self.assertEqual(request["headers"]["apns-topic"], "com.example.stickdeath")
        self.assertEqual(request["headers"]["apns-push-type"], "alert")
        self.assertEqual(json.loads(request["body"])["aps"]["alert"], {"title": "New challenge", "body": "Starts today"})
        jwt = request["headers"]["authorization"].split(" ", 1)[1]
        header, claims, signature = jwt.split(".")
        self.assertEqual(json.loads(unb64(header)), {"alg": "ES256", "kid": "KEYID12345"})
        self.assertEqual(json.loads(unb64(claims)), {"iss": "TEAMID1234", "iat": 1_800_000_000})
        raw = unb64(signature)
        self.assertEqual(len(raw), 64)
        der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        self.ec_key.public_key().verify(der, ("%s.%s" % (header, claims)).encode(), ec.ECDSA(hashes.SHA256()))

    def test_apns_token_reused_then_refreshed_and_production_host(self):
        transport, sender = self.apns([(200, {}), (200, {}), (200, {})])
        transport.send("ios", "production", IOS_TOKEN, "a", "b")
        self.clock[0] += 60
        transport.send("ios", "production", IOS_TOKEN, "a", "b")
        self.clock[0] += 50 * 60
        transport.send("ios", "production", IOS_TOKEN, "a", "b")
        tokens = [r["headers"]["authorization"] for r in sender.requests]
        self.assertEqual(tokens[0], tokens[1])
        self.assertNotEqual(tokens[1], tokens[2])
        self.assertTrue(sender.requests[0]["url"].startswith("https://api.push.apple.com/3/device/"))

    def test_apns_failures_map_to_revocation_reasons(self):
        transport, sender = self.apns([(410, {"reason": "Unregistered"}), (400, {"reason": "BadDeviceToken"}),
                                       (403, {"reason": "ExpiredProviderToken"}), (200, {}), (429, {"reason": "TooManyRequests"})])
        self.assertEqual(transport.send("ios", "sandbox", IOS_TOKEN, "a", "b"), (False, "Unregistered"))
        self.assertEqual(transport.send("ios", "sandbox", IOS_TOKEN, "a", "b"), (False, "BadDeviceToken"))
        self.assertEqual(transport.send("ios", "sandbox", IOS_TOKEN, "a", "b"), (False, "apns status 403 ExpiredProviderToken"))
        transport.send("ios", "sandbox", IOS_TOKEN, "a", "b")
        self.assertEqual(transport.send("ios", "sandbox", IOS_TOKEN, "a", "b"), (False, "apns status 429 TooManyRequests"))
        # Expired provider token forces a new token on the next request (new iat not needed: cache cleared).
        self.assertEqual(len(sender.requests), 5)
        self.assertEqual(transport.send("android", "sandbox", IOS_TOKEN, "a", "b"), (False, "apns handles ios only"))
        self.assertEqual(transport.send("ios", "sandbox", "not-hex", "a", "b"), (False, "BadDeviceToken"))
        self.assertEqual(transport.send("ios", "sandbox", IOS_TOKEN, "x" * 5000, "b"), (False, "payload too large"))
        self.assertEqual(len(sender.requests), 5)

    def test_fcm_oauth_exchange_and_send(self):
        transport, sender = self.fcm([(200, {"access_token": "ya29.test-access", "expires_in": 3599}),
                                      (200, {"name": "projects/example-project/messages/1"}),
                                      (200, {"name": "projects/example-project/messages/2"})])
        self.assertTrue(transport.configured)
        self.assertEqual(transport.send("android", "production", ANDROID_TOKEN, "Hi", "There"), (True, ""))
        self.assertEqual(transport.send("android", "production", ANDROID_TOKEN, "Hi", "There"), (True, ""))
        exchange, first, second = sender.requests
        self.assertEqual(exchange["url"], push.GOOGLE_TOKEN_URL)
        form = urllib.parse.parse_qs(exchange["body"].decode())
        self.assertEqual(form["grant_type"], ["urn:ietf:params:oauth:grant-type:jwt-bearer"])
        header, claims, signature = form["assertion"][0].split(".")
        claim_data = json.loads(unb64(claims))
        self.assertEqual((claim_data["scope"], claim_data["aud"]), (push.FCM_SCOPE, push.GOOGLE_TOKEN_URL))
        self.rsa_key.public_key().verify(unb64(signature), ("%s.%s" % (header, claims)).encode(), padding.PKCS1v15(), hashes.SHA256())
        self.assertEqual(first["url"], "https://fcm.googleapis.com/v1/projects/example-project/messages:send")
        self.assertEqual(first["headers"]["Authorization"], "Bearer ya29.test-access")
        message = json.loads(first["body"])["message"]
        self.assertEqual((message["token"], message["notification"]), (ANDROID_TOKEN, {"title": "Hi", "body": "There"}))
        self.assertEqual(second["headers"]["Authorization"], "Bearer ya29.test-access")  # cached

    def test_fcm_error_mapping_and_token_refusal(self):
        unregistered = {"error": {"status": "NOT_FOUND", "details": [{"errorCode": "UNREGISTERED"}]}}
        invalid = {"error": {"status": "INVALID_ARGUMENT", "message": "The registration token is not a valid FCM registration token",
                             "details": [{"errorCode": "INVALID_ARGUMENT"}]}}
        quota = {"error": {"status": "RESOURCE_EXHAUSTED", "details": [{"errorCode": "QUOTA_EXCEEDED"}]}}
        transport, sender = self.fcm([(200, {"access_token": "t", "expires_in": 3599}), (404, unregistered), (400, invalid), (429, quota)])
        self.assertEqual(transport.send("android", "production", ANDROID_TOKEN, "a", "b"), (False, "unregistered"))
        self.assertEqual(transport.send("android", "production", ANDROID_TOKEN, "a", "b"), (False, "invalid_token"))
        self.assertEqual(transport.send("android", "production", ANDROID_TOKEN, "a", "b"), (False, "fcm status 429 QUOTA_EXCEEDED"))
        refused, _ = self.fcm([(400, {"error": "invalid_grant"})])
        with self.assertRaises(RuntimeError):
            refused.send("android", "production", ANDROID_TOKEN, "a", "b")

    def test_not_configured_names_missing_settings_only(self):
        env = dict(self.env)
        del env["SDI_APNS_KEY_FILE"], env["SDI_FCM_PROJECT_ID"]
        routing = transport_from_environment(env, http2=FakeSender([]), https=FakeSender([]))
        self.assertFalse(routing.configured)
        self.assertIn("SDI_APNS_KEY_FILE", routing.reason)
        self.assertIn("SDI_FCM_PROJECT_ID", routing.reason)
        self.assertNotIn(str(self.dir), routing.reason)
        with self.assertRaises(NotConfigured):
            routing.send("ios", "sandbox", IOS_TOKEN, "a", "b")

    def test_apns_without_http2_sender_is_not_configured(self):
        class Unavailable:
            available = False
        transport = ApnsTransport.from_environment(self.env, Unavailable())
        self.assertFalse(transport.configured)
        self.assertIn("HTTP/2", transport.reason)

    def test_unreadable_key_never_leaks_path(self):
        env = dict(self.env, SDI_APNS_KEY_FILE=str(self.dir / "missing.p8"))
        transport, _ = ApnsTransport.from_environment(env, FakeSender([])), None
        with self.assertRaises(NotConfigured) as error:
            transport.send("ios", "sandbox", IOS_TOKEN, "a", "b")
        self.assertNotIn("missing.p8", str(error.exception))


@unittest.skipIf(ec is None, "cryptography not installed")
class WorkerTests(unittest.TestCase):
    def test_worker_refuses_to_claim_when_not_configured(self):
        api = FakeAPI({"deliveries": []})
        routing = transport_from_environment({}, http2=FakeSender([]), https=FakeSender([]))
        result = PushBatchWorker(api, routing).run_once()
        self.assertEqual(result["state"], "not_configured")
        self.assertEqual(api.calls, [])

    def test_routing_sends_each_platform_to_its_transport(self):
        ios, android = SinkTransport(), SinkTransport({ANDROID_TOKEN: "unregistered"})
        api = FakeAPI({"announcement": "a1", "complete": True, "deliveries": [
            {"delivery": "d1", "platform": "ios", "environment": "sandbox", "token": IOS_TOKEN, "title": "t", "body": "b"},
            {"delivery": "d2", "platform": "android", "environment": "production", "token": ANDROID_TOKEN, "title": "t", "body": "b"}]})
        result = PushBatchWorker(api, RoutingTransport(ios, android)).run_once()
        self.assertEqual((result["sent"], result["failed"]), (1, 1))
        self.assertEqual(len(ios.sent), 1)
        self.assertEqual(api.calls[-1][1]["results"][1], {"delivery": "d2", "ok": False, "reason": "unregistered"})

    def test_cli_is_disabled_by_default_and_refuses_unconfigured(self):
        self.assertEqual(push.main([], environment={}), 2)
        self.assertEqual(push.main([], environment={"SDI_PUSH_ENABLED": "1"},
                                   transport_factory=lambda env: transport_from_environment(env, http2=FakeSender([]), https=FakeSender([]))), 2)


if __name__ == "__main__":
    unittest.main()

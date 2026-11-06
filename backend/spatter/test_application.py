"""Offline WSGI-to-handler tests; no listeners, provider SDK, SQL or external API."""
import datetime as dt
import io
import json
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

from backend.ingestion.store import IntakeError
from backend.spatter import application, handler
from backend.spatter.metering import Decision

USER = "11111111-2222-3333-4444-555555555555"
ENDPOINT = "https://spatter.example.test/v1/advice"
BODY = json.dumps({"schemaVersion": 1, "messages": [{"role": "user", "content": "animate a step"}],
                   "max_tokens": 500, "temperature": 0.8}).encode()


class Provider:
    configured = True

    def __init__(self):
        self.calls = []

    def complete(self, messages):
        self.calls.append(messages)
        return "Hold the pose.", 7


class Meter:
    def __init__(self):
        self.reserved, self.settled = [], []

    def reserve(self, user, suggested_prompt=None):
        self.reserved.append((user, suggested_prompt))
        return Decision(True, reservation="reservation", plan="creator", remaining=249, funding="allowance")

    def settle(self, *args):
        self.settled.append(args)
        return True


class ApplicationTests(unittest.TestCase):
    def setUp(self):
        self.provider, self.meter, self.authorized = Provider(), Meter(), []
        self.claims = {"sub": USER, "role": "authenticated", "aud": "authenticated", "exp": dt.datetime.now(dt.timezone.utc).timestamp() + 600}
        self.app = application.SpatterApplication(ENDPOINT, verify_jwt=lambda _: self.claims,
            authorize=self.authorize, meter=self.meter, provider=self.provider)

    def authorize(self, token):
        self.authorized.append(token)
        return USER

    def request(self, app=None, body=BODY, **overrides):
        env = {"wsgi.url_scheme": "https", "HTTP_HOST": "spatter.example.test", "PATH_INFO": "/v1/advice",
               "REQUEST_METHOD": "POST", "CONTENT_TYPE": "application/json", "CONTENT_LENGTH": str(len(body)),
               "HTTP_AUTHORIZATION": "Bearer private-test-token", "wsgi.input": io.BytesIO(body)}
        env.update(overrides)
        captured = []
        result = b"".join((app or self.app)(env, lambda status, headers: captured.append((status, dict(headers)))))
        self.assertEqual(int(captured[0][1]["Content-Length"]), len(result))
        self.assertEqual(captured[0][1]["Cache-Control"], "no-store")
        self.assertNotIn(b"private-test-token", result)
        return int(captured[0][0].split()[0]), json.loads(result)

    def test_authenticated_request_reaches_existing_handler_and_settles_once(self):
        status, result = self.request()
        self.assertEqual((status, result["reply"], result["usage"]), (200, "Hold the pose.", {"units": 7}))
        self.assertEqual(self.authorized, ["Bearer private-test-token"])
        self.assertEqual(self.meter.reserved, [(USER, None)])
        self.assertEqual(self.meter.settled, [("reservation", "commit", 7)])
        self.assertEqual(len(self.provider.calls), 1)

    def test_missing_auth_and_unconfigured_factory_never_call_provider_or_read_secrets(self):
        self.assertEqual(self.request(HTTP_AUTHORIZATION="")[0], 401)
        with patch.object(application, "_secret_file", side_effect=AssertionError("unexpected secret read")):
            app = application.create_application({"SDI_SPATTER_URL": ENDPOINT}, provider=self.provider)
            self.assertEqual(self.request(app=app)[0], 503)
            app = application.create_application({"SDI_SPATTER_URL": ENDPOINT}, verify_jwt=lambda _: self.claims, provider=self.provider)
            self.assertEqual(self.request(app=app)[0], 503)
            app = application.create_application({"SDI_SPATTER_URL": ENDPOINT}, verify_jwt=lambda _: self.claims)
            self.assertEqual(self.request(app=app)[0], 503)
        self.assertEqual((self.authorized, self.provider.calls, self.meter.reserved), ([], [], []))

    def test_expiry_roles_revocation_and_actor_mismatch_stop_before_provider(self):
        for claim, value, expected in (("role", "service_role", 403), ("aud", "anon", 401), ("exp", 1, 401)):
            original = self.claims[claim]
            self.claims[claim] = value
            self.assertEqual(self.request()[0], expected)
            self.claims[claim] = original
        self.app.authorize = lambda _: "another-user"
        self.assertEqual(self.request()[0], 401)
        for error, expected in ((IntakeError("private auth detail", 403), 403), (IntakeError("private outage", 503), 503), (OSError("private credential"), 503)):
            def reject(_, error=error):
                raise error
            self.app.authorize = reject
            status, result = self.request()
            self.assertEqual(status, expected)
            self.assertNotIn("private", json.dumps(result))
        self.assertEqual((self.provider.calls, self.meter.reserved), ([], []))

    def test_origin_route_method_and_framing_are_bounded(self):
        for overrides, expected in (({"wsgi.url_scheme": "http", "HTTP_X_FORWARDED_PROTO": "https"}, 421),
            ({"HTTP_HOST": "attacker.example.test"}, 421), ({"PATH_INFO": "/admin"}, 404),
            ({"QUERY_STRING": "token=private"}, 404), ({"REQUEST_METHOD": "GET"}, 405),
            ({"CONTENT_TYPE": "text/plain"}, 415), ({"HTTP_CONTENT_ENCODING": "gzip"}, 415),
            ({"CONTENT_LENGTH": ""}, 413), ({"CONTENT_LENGTH": "131073"}, 413),
            ({"CONTENT_LENGTH": "9999999999999999999999999"}, 413), ({"HTTP_TRANSFER_ENCODING": "chunked"}, 413),
            ({"CONTENT_LENGTH": str(len(BODY) + 1)}, 400)):
            self.assertEqual(self.request(**overrides)[0], expected, overrides)
        self.assertEqual((self.provider.calls, self.authorized), ([], []))

    def test_schema_commands_and_handler_message_limits_are_enforced(self):
        payload = json.loads(BODY)
        for value in (dict(payload, commands=[{"shell": "anything"}]), dict(payload, max_tokens=501),
                      dict(payload, max_tokens=True), dict(payload, temperature=float("nan")),
                      dict(payload, schemaVersion=True), dict(payload, messages=[{"role": "tool", "content": "x"}]),
                      dict(payload, messages=[{"role": "user", "content": "x", "admin": True}]),
                      dict(payload, messages=[{"role": "user", "content": "x"}] * 42),
                      dict(payload, messages=[{"role": "user", "content": "x" * 32769}])):
            self.assertEqual(self.request(body=json.dumps(value).encode())[0], 400)
        self.assertEqual(self.request(body=b'{"schemaVersion":1,"schemaVersion":0}')[0], 400)
        self.assertEqual(self.request(body=b"{" + b" " * 131072 + b"}")[0], 413)
        self.assertEqual((self.provider.calls, self.meter.reserved), ([], []))

    def test_capacity_is_released_after_refusal_and_does_not_queue(self):
        self.app.capacity.acquire()
        self.app.capacity.acquire()
        self.assertEqual(self.request()[0], 503)
        self.app.capacity.release()
        self.app.capacity.release()
        self.assertEqual(self.request(body=b"invalid")[0], 400)
        self.assertEqual(self.request()[0], 200)

    def test_signature_and_provider_failures_preserve_handler_security_and_refund(self):
        def reject(_):
            raise ValueError("private signature detail")
        self.app.verify_jwt = reject
        self.assertEqual(self.request()[0], 401)
        self.assertEqual((self.authorized, self.meter.reserved, self.provider.calls), ([], [], []))
        self.app.verify_jwt = lambda _: self.claims
        self.provider.complete = reject
        status, result = self.request()
        self.assertEqual(status, 502)
        self.assertNotIn("private", json.dumps(result))
        self.assertEqual(self.meter.settled, [("reservation", "release")])

    def test_encoded_reply_is_bounded_for_native_transport(self):
        self.provider.complete = lambda _: ("\x01" * handler.MAX_REPLY_BYTES, 1)
        status, result = self.request()
        self.assertEqual(status, 502)
        self.assertEqual(result["error"], "provider response too large")

    def test_factory_builds_live_authorization_and_service_only_meter_without_network(self):
        with tempfile.TemporaryDirectory() as root:
            secret = Path(root) / "service.key"
            secret.write_text("private-test-service-credential")
            secret.chmod(0o600)
            app = application.create_application({"SDI_SPATTER_URL": ENDPOINT,
                "SDI_BACKEND_URL": "https://backend.example.test/native-review-api", "SDI_BACKEND_PUBLISHABLE_KEY": "publishable",
                "SDI_BACKEND_SERVICE_KEY_FILE": str(secret)}, verify_jwt=lambda _: self.claims, provider=self.provider)
            self.assertIsInstance(app.authorize, application.AccountAuthorizer)
            self.assertIsInstance(app.meter, application.SqlMeter)
            self.assertEqual(app.meter._rpc.url, "https://backend.example.test/native-review-api/rest/v1/rpc/sdi_spatter_usage_meter")

    def test_meter_transport_limits_endpoint_response_and_does_not_disclose_key(self):
        rpc = application.MeterRPC("https://backend.example.test/native-review-api", "private-test-service-credential", "publishable")
        with patch.object(application.urllib.request, "build_opener") as build:
            response = build.return_value.open.return_value.__enter__.return_value
            response.read.return_value = b'{"allowed":false,"code":"global_limit"}'
            result = rpc("sdi_spatter_usage_meter", {"action": "reserve", "p_user": USER})
            self.assertEqual(result["code"], "global_limit")
            request = build.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, rpc.url)
            self.assertEqual(request.get_header("Apikey"), "publishable")
            self.assertEqual(request.get_header("Authorization"), "Bearer private-test-service-credential")
            self.assertNotIn("private-test-service-credential", request.full_url)
            response.read.assert_called_once_with(16385)
            response.read.return_value = b"x" * 16385
            with self.assertRaises(ValueError):
                rpc("sdi_spatter_usage_meter", {})
            with self.assertRaises(ValueError):
                rpc("arbitrary_admin_rpc", {})
        with self.assertRaises(ValueError):
            application.MeterRPC("https://backend.example.test", "same-key", "same-key")


if __name__ == "__main__":
    unittest.main()

"""#209 metering, provider routing and HS256 verification with fakes only.

No socket, provider, database or real credential is used. The HS256 key is
generated per test run; the fake provider "key" is a random marker that must
never appear in any response.
"""
import base64
import datetime as dt
import hashlib
import hmac
import json
import os
import threading
import unittest

from backend.spatter import handler, jwt_hs256, metering, providers

NOW = dt.datetime(2026, 10, 14, 9, 30, 15, tzinfo=dt.timezone.utc)
USER = "11111111-2222-3333-4444-555555555555"
PAID = dt.datetime(2026, 11, 1, 0, 0, tzinfo=dt.timezone.utc)


def claims(**overrides):
    base = {"sub": USER, "aud": "authenticated", "role": "authenticated", "exp": NOW.timestamp() + 600}
    base.update(overrides)
    return base


def body(text="animate a step"):
    return json.dumps({"schemaVersion": 1, "messages": [{"role": "user", "content": text}]}).encode()


class FakeAdapter:
    def __init__(self, outcomes):
        self.outcomes = list(outcomes)
        self.calls = []

    def complete(self, model, messages):
        self.calls.append(model)
        outcome = self.outcomes.pop(0) if self.outcomes else ("ok", 1)
        if isinstance(outcome, BaseException):
            raise outcome
        if callable(outcome):
            return outcome()
        return outcome


def router(adapter, **config):
    defaults = {"provider": "fake", "model": "fake-model-a", "timeout_seconds": 1.0, "max_attempts": 2}
    defaults.update(config)
    return providers.ProviderRouter({"fake": adapter}, providers.RouteConfig(**defaults), sleep=lambda _s: None)


def meter(**kwargs):
    controls = metering.Controls(global_daily_cap=1000, user_per_minute_cap=100)
    for key, value in kwargs.pop("controls", {}).items():
        setattr(controls, key, value)
    return metering.InMemoryMeter(now=lambda: NOW, controls=controls, **kwargs)


def run(meter_, provider, verifier=None, headers=None, raw=None):
    return handler.handle(headers or {"Authorization": "Bearer test-session"}, raw or body(),
                          verify_jwt=verifier or (lambda _t: claims()), meter=meter_, provider=provider, now=lambda: NOW)


class MeteringRuleTests(unittest.TestCase):
    def test_global_ceiling_defaults_closed(self):
        m = metering.InMemoryMeter(now=lambda: NOW)
        self.assertEqual(m.reserve(USER).code, "global_limit")
        self.assertEqual(m.reservations, {})

    def test_free_plan_is_five_one_time_prompts(self):
        m = meter()
        for expected in (4, 3, 2, 1, 0):
            decision = m.reserve(USER)
            self.assertTrue(decision.allowed)
            self.assertEqual((decision.plan, decision.period, decision.remaining, decision.resets_at), ("free", "one_time", expected, None))
            self.assertTrue(m.settle(decision.reservation, "commit", 3))
        refused = m.reserve(USER)
        self.assertEqual((refused.allowed, refused.code, refused.upgrade), (False, "plan_allowance_exhausted", "creator_or_pro"))

    def test_creator_period_resets_on_renewal(self):
        state = {"paid": PAID}
        m = meter(entitlement=lambda _u: ("creator", state["paid"]))
        for _ in range(15):
            self.assertTrue(m.settle(m.reserve(USER).reservation, "commit", 1))
        refused = m.reserve(USER)
        self.assertEqual((refused.code, refused.upgrade, refused.resets_at), ("plan_allowance_exhausted", "pro", PAID))
        state["paid"] = PAID + dt.timedelta(days=30)
        renewed = m.reserve(USER)
        self.assertEqual((renewed.allowed, renewed.remaining, renewed.period), (True, 14, "billing_period"))

    def test_pro_is_unlimited_by_plan_but_obeys_safety_cap(self):
        m = meter(entitlement=lambda _u: ("pro", PAID), controls={"user_daily_safety_cap": 2})
        first = m.reserve(USER)
        self.assertEqual((first.allowed, first.plan, first.remaining), (True, "pro", None))
        m.reserve(USER)
        refused = m.reserve(USER)
        self.assertEqual(refused.code, "daily_safety_limit")
        self.assertEqual(refused.resets_at, dt.datetime(2026, 10, 15, tzinfo=dt.timezone.utc))

    def test_rate_limit_restricted_accounts_and_emergency_stop(self):
        m = meter(controls={"user_per_minute_cap": 1})
        self.assertTrue(m.reserve(USER).allowed)
        limited = m.reserve(USER)
        self.assertEqual((limited.code, limited.retry_after_seconds), ("rate_limited", 45))
        self.assertEqual(meter(account_state=lambda _u: "suspended").reserve(USER).code, "account_restricted")
        self.assertEqual(meter(account_state=lambda _u: None).reserve(USER).code, "unauthorized")
        stopped = meter(controls={"emergency_stop": True})
        self.assertEqual(stopped.reserve(USER).code, "emergency_stop")

    def test_release_refunds_once(self):
        m = meter()
        decision = m.reserve(USER)
        self.assertTrue(m.settle(decision.reservation, "release"))
        self.assertFalse(m.settle(decision.reservation, "commit", 5))
        self.assertEqual(m.plan(USER)["remaining"], 5)
        self.assertEqual(m.global_used[NOW.date()], 0)


class SqlMeterDecodeTests(unittest.TestCase):
    def test_rpc_contract_and_strict_decode(self):
        calls = []

        def rpc(name, params):
            calls.append((name, params))
            if params["action"] == "reserve":
                return {"allowed": True, "reservation": "r-1", "plan": "creator", "period": "billing_period",
                        "remaining": 14, "resets_at": "2026-11-01T00:00:00+00:00"}
            return {"status": "confirmed", "state": "committed"}

        m = metering.SqlMeter(rpc)
        decision = m.reserve(USER)
        self.assertEqual((decision.allowed, decision.remaining, decision.resets_at), (True, 14, PAID))
        self.assertTrue(m.settle("r-1", "commit", 7))
        self.assertEqual(calls[0], ("sdi_spatter_usage_meter", {"action": "reserve", "p_user": USER}))
        self.assertEqual(calls[1][1], {"action": "settle", "p_reservation": "r-1", "p_outcome": "commit", "p_units": 7})

    def test_malformed_rpc_results_are_refusals(self):
        for payload in [None, {}, {"allowed": "true"}, {"allowed": True}, {"allowed": True, "reservation": "r", "plan": "gold", "remaining": 1},
                        {"allowed": True, "reservation": "r", "plan": "free", "remaining": -1},
                        {"allowed": True, "reservation": "r", "plan": "free"}, {"allowed": False, "code": "made_up"}]:
            decision = metering.decision_from_rpc(payload or {})
            self.assertFalse(decision.allowed, payload)
        self.assertEqual(metering.decision_from_rpc({"allowed": False, "code": "global_limit"}).code, "global_limit")


class MeteredHandlerTests(unittest.TestCase):
    def test_success_carries_allowance_not_a_daily_budget(self):
        m = meter()
        response = run(m, router(FakeAdapter([("hold the pose", 9)])))
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body, {"schemaVersion": 1, "reply": "hold the pose", "usage": {"units": 9},
                                         "allowance": {"plan": "free", "period": "one_time", "remaining": 4, "resetsAt": None}})
        self.assertNotIn("budget", response.body)
        (reservation,) = m.reservations.values()
        self.assertEqual((reservation.state, reservation.units), ("committed", 9))

    def test_unconfigured_router_is_503_and_consumes_nothing(self):
        m = meter()
        response = run(m, providers.ProviderRouter({"fake": FakeAdapter([])}))
        self.assertEqual((response.status, response.body["error"]), (503, "not configured"))
        self.assertEqual(m.reservations, {})

    def test_refusal_codes_map_to_honest_statuses(self):
        cases = [
            (meter(controls={"global_daily_cap": 0}), 503, "global_limit"),
            (meter(controls={"emergency_stop": True}), 503, "emergency_stop"),
            (meter(account_state=lambda _u: "banned"), 403, "account_restricted"),
        ]
        for m, status, code in cases:
            adapter = FakeAdapter([])
            response = run(m, router(adapter))
            self.assertEqual((response.status, response.body["code"]), (status, code))
            self.assertEqual(adapter.calls, [])
        m = meter(controls={"free_prompts": 0})
        response = run(m, router(FakeAdapter([])))
        self.assertEqual(response.status, 429)
        self.assertEqual(response.body["code"], "plan_allowance_exhausted")
        self.assertEqual(response.body["upgrade"], "creator_or_pro")
        self.assertEqual(response.body["allowance"], {"plan": "free", "period": "one_time", "remaining": 0, "resetsAt": None})
        m = meter(controls={"user_per_minute_cap": 1})
        run(m, router(FakeAdapter([])))
        limited = run(m, router(FakeAdapter([])))
        self.assertEqual((limited.status, limited.body["code"], limited.body["retryAfterSeconds"]), (429, "rate_limited", 45))

    def test_provider_failure_refunds_and_hides_credentials(self):
        marker = "sk-test-" + os.urandom(12).hex()
        m = meter()
        response = run(m, router(FakeAdapter([RuntimeError("401 invalid api key " + marker)])))
        self.assertEqual((response.status, response.body["code"], response.body["retryable"]), (502, "provider_unavailable", False))
        self.assertNotIn(marker, response.json())
        self.assertEqual(m.plan(USER)["remaining"], 5)
        self.assertEqual([r.state for r in m.reservations.values()], ["released"])

    def test_meter_outage_is_503_without_provider_call(self):
        class Broken:
            def reserve(self, _user):
                raise ConnectionError("db down")

            def settle(self, *_args):
                raise AssertionError("not reached")

        adapter = FakeAdapter([])
        response = run(Broken(), router(adapter))
        self.assertEqual((response.status, response.body["code"]), (503, "unavailable"))
        self.assertEqual(adapter.calls, [])

    def test_expired_token_is_refused_before_metering(self):
        m = meter()
        response = run(m, router(FakeAdapter([])), verifier=lambda _t: claims(exp=NOW.timestamp() - 1))
        self.assertEqual(response.status, 401)
        self.assertEqual(m.reservations, {})


class ProviderRouterTests(unittest.TestCase):
    def test_transient_failure_retries_once_and_charges_once(self):
        adapter = FakeAdapter([providers.ProviderUnavailable(transient=True), ("second try", 4)])
        m = meter()
        response = run(m, router(adapter))
        self.assertEqual((response.status, response.body["reply"]), (200, "second try"))
        self.assertEqual(len(adapter.calls), 2)
        self.assertEqual(len(m.reservations), 1)

    def test_permanent_failure_is_not_retried(self):
        adapter = FakeAdapter([providers.ProviderUnavailable(transient=False), ("never", 1)])
        with self.assertRaises(providers.ProviderUnavailable) as caught:
            router(adapter).complete([{"role": "user", "content": "x"}])
        self.assertFalse(caught.exception.transient)
        self.assertEqual(len(adapter.calls), 1)

    def test_timeout_is_transient_and_bounded(self):
        gate = threading.Event()

        def slow():
            gate.wait(2)
            return ("late", 1)

        adapter = FakeAdapter([slow, slow])
        with self.assertRaises(providers.ProviderUnavailable) as caught:
            router(adapter, timeout_seconds=0.05, max_attempts=2).complete([{"role": "user", "content": "x"}])
        gate.set()
        self.assertTrue(caught.exception.transient)
        self.assertEqual(len(adapter.calls), 2)

    def test_model_switch_is_validated_and_applies_to_next_request(self):
        adapter = FakeAdapter([("a", 1), ("b", 1)])
        r = router(adapter)
        r.complete([{"role": "user", "content": "x"}])
        r.switch(providers.RouteConfig(provider="fake", model="fake-model-b"))
        r.complete([{"role": "user", "content": "x"}])
        self.assertEqual(adapter.calls, ["fake-model-a", "fake-model-b"])
        for bad in [providers.RouteConfig(provider="other", model="m"), providers.RouteConfig(provider="fake", model="bad model"),
                    providers.RouteConfig(provider="fake", model="m", timeout_seconds=0), providers.RouteConfig(provider="fake", model="m", max_attempts=9)]:
            with self.assertRaises(ValueError):
                r.switch(bad)
        self.assertEqual(r.route.model, "fake-model-b")
        r.disable()
        self.assertFalse(r.configured)


def _b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def sign(secret, payload, header=None):
    head = _b64(json.dumps(header or {"alg": "HS256", "typ": "JWT"}).encode())
    body_ = _b64(json.dumps(payload).encode())
    sig = _b64(hmac.new(secret, f"{head}.{body_}".encode(), hashlib.sha256).digest())
    return f"{head}.{body_}.{sig}"


class HS256VerifierTests(unittest.TestCase):
    ISS = "https://project.example/auth/v1"

    def setUp(self):
        self.secret = os.urandom(32)
        self.verify = jwt_hs256.make_hs256_verifier(self.secret, self.ISS, now=lambda: NOW.timestamp())

    def test_valid_token_returns_claims(self):
        token = sign(self.secret, claims(iss=self.ISS))
        self.assertEqual(self.verify(token)["sub"], USER)
        response = handler.handle({"Authorization": "Bearer " + token}, body(), verify_jwt=self.verify, meter=meter(),
                                   provider=router(FakeAdapter([("ok", 1)])), now=lambda: NOW)
        self.assertEqual(response.status, 200)
        self.assertNotIn(token, response.json())

    def test_rejections(self):
        good = claims(iss=self.ISS)
        bad_tokens = [
            sign(os.urandom(32), good),                                   # wrong key
            sign(self.secret, good, {"alg": "none"}),                     # alg none
            sign(self.secret, good, {"alg": "RS256"}),                    # asymmetric not handled here
            sign(self.secret, claims(iss=self.ISS, exp=NOW.timestamp() - 31)),
            sign(self.secret, claims(iss="https://other.example/auth/v1")),
            sign(self.secret, claims(iss=self.ISS, aud="anon")),
            sign(self.secret, claims(iss=self.ISS, nbf=NOW.timestamp() + 600)),
            sign(self.secret, {k: v for k, v in good.items() if k != "exp"}),
            "a.b", "", "x" * 20000,
        ]
        tampered = sign(self.secret, good).split(".")
        tampered[1] = _b64(json.dumps(claims(iss=self.ISS, sub="someone-else")).encode())
        bad_tokens.append(".".join(tampered))
        for token in bad_tokens:
            with self.assertRaises(jwt_hs256.TokenRejected):
                self.verify(token)

    def test_short_secret_and_missing_issuer_refused(self):
        with self.assertRaises(ValueError):
            jwt_hs256.make_hs256_verifier(b"short", self.ISS)
        with self.assertRaises(ValueError):
            jwt_hs256.make_hs256_verifier(os.urandom(32), "")


if __name__ == "__main__":
    unittest.main()

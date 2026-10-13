"""Contract tests for the Spatter advice handler using fakes only (no network, provider or database)."""
import datetime as dt
import json
import unittest

from backend.spatter import handler


NOW = dt.datetime(2026, 10, 12, 15, 30, tzinfo=dt.timezone.utc)
USER = "11111111-2222-3333-4444-555555555555"


def claims(**overrides):
    base = {"sub": USER, "aud": "authenticated", "role": "authenticated", "exp": NOW.timestamp() + 600, "iss": "https://project.example/auth/v1"}
    base.update(overrides)
    return base


class FakeVerifier:
    def __init__(self, result):
        self.result = result
        self.tokens = []

    def __call__(self, token):
        self.tokens.append(token)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


class FakeProvider:
    name = "fake"

    def __init__(self, reply="hold the pose", units=7, error=None):
        self.reply, self.units, self.error, self.calls = reply, units, error, 0

    def complete(self, messages):
        self.calls += 1
        if self.error:
            raise self.error
        return self.reply, self.units


def body(messages=None, version=1):
    if messages is None:
        messages = [{"role": "user", "content": "animate a step"}]
    payload = {"messages": messages, "max_tokens": 500, "temperature": 0.8}
    if version is not None:
        payload["schemaVersion"] = version
    return json.dumps(payload).encode()


def run(headers=None, raw=None, verifier=None, budget=None, provider=None):
    if headers is None:
        headers = {"Authorization": "Bearer test-session"}
    return handler.handle(headers, raw or body(),
                          verify_jwt=verifier or FakeVerifier(claims()),
                          budget=budget or handler.InMemoryBudget(3, lambda: NOW),
                          provider=provider or handler.NullProvider(), now=lambda: NOW)


class HandlerContractTests(unittest.TestCase):
    def test_null_provider_is_503_and_consumes_no_budget(self):
        budget = handler.InMemoryBudget(3, lambda: NOW)
        response = run(budget=budget)
        self.assertEqual(response.status, 503)
        self.assertEqual(response.body, {"schemaVersion": 1, "error": "not configured"})
        self.assertEqual(budget.remaining(USER), 3)

    def test_success_envelope_matches_client_contract(self):
        budget = handler.InMemoryBudget(3, lambda: NOW)
        provider = FakeProvider()
        response = run(budget=budget, provider=provider)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body, {
            "schemaVersion": 1, "reply": "hold the pose", "usage": {"units": 7},
            "budget": {"remaining": 2, "resetsAt": "2026-10-13T00:00:00Z"}})
        self.assertEqual(provider.calls, 1)
        self.assertNotIn("test-session", response.json())

    def test_budget_exhaustion_is_429_without_provider_call(self):
        budget = handler.InMemoryBudget(1, lambda: NOW)
        provider = FakeProvider()
        self.assertEqual(run(budget=budget, provider=provider).status, 200)
        second = run(budget=budget, provider=provider)
        self.assertEqual(second.status, 429)
        self.assertEqual(second.body["error"], "daily budget exhausted")
        self.assertEqual(provider.calls, 1)

    def test_provider_failure_refunds_budget(self):
        budget = handler.InMemoryBudget(2, lambda: NOW)
        response = run(budget=budget, provider=FakeProvider(error=handler.ProviderUnavailable()))
        self.assertEqual(response.status, 502)
        self.assertEqual(budget.remaining(USER), 2)
        empty = run(budget=budget, provider=FakeProvider(reply="   "))
        self.assertEqual(empty.status, 502)
        self.assertEqual(budget.remaining(USER), 2)

    def test_missing_or_malformed_bearer_is_401_before_verification(self):
        verifier = FakeVerifier(claims())
        for headers in [{}, {"Authorization": "Basic abc"}, {"Authorization": "Bearer "}, {"Authorization": "Bearer bad\ntoken"}]:
            response = run(headers=headers, verifier=verifier, provider=FakeProvider())
            self.assertEqual(response.status, 401, headers)
        self.assertEqual(verifier.tokens, [])

    def test_invalid_expired_and_wrong_role_tokens_are_refused(self):
        provider = FakeProvider()
        self.assertEqual(run(verifier=FakeVerifier(ValueError("bad signature")), provider=provider).status, 401)
        self.assertEqual(run(verifier=FakeVerifier(claims(exp=NOW.timestamp() - 1)), provider=provider).status, 401)
        self.assertEqual(run(verifier=FakeVerifier(claims(aud="anon")), provider=provider).status, 401)
        self.assertEqual(run(verifier=FakeVerifier(claims(role="service_role")), provider=provider).status, 403)
        self.assertEqual(run(verifier=FakeVerifier(claims(sub="")), provider=provider).status, 401)
        self.assertEqual(provider.calls, 0)

    def test_request_bounds_and_schema_versions(self):
        provider = FakeProvider()
        self.assertEqual(run(raw=b"not json", provider=provider).status, 400)
        self.assertEqual(run(raw=body(version=2), provider=provider).status, 400)
        self.assertEqual(run(raw=body(version=None), provider=provider).status, 200)  # legacy client
        self.assertEqual(run(raw=body(messages=[]), provider=provider).status, 400)
        self.assertEqual(run(raw=body(messages=[{"role": "user", "content": " "}]), provider=provider).status, 400)
        self.assertEqual(run(raw=body(messages=[{"role": "tool", "content": "x"}]), provider=provider).status, 400)
        self.assertEqual(run(raw=body(messages=[{"role": "assistant", "content": "x"}]), provider=provider).status, 400)
        self.assertEqual(run(raw=body(messages=[{"role": "user", "content": "x"}] * 42), provider=provider).status, 400)
        self.assertEqual(run(raw=body(messages=[{"role": "user", "content": "x" * 32_769}]), provider=provider).status, 400)
        self.assertEqual(run(raw=b"{" + b" " * (128 * 1024) + b"}", provider=provider).status, 413)
        self.assertEqual(provider.calls, 1)

    def test_budget_resets_on_the_next_utc_day(self):
        clock = {"now": NOW}
        budget = handler.InMemoryBudget(1, lambda: clock["now"])
        provider = FakeProvider()
        self.assertEqual(handler.handle({"Authorization": "Bearer t"}, body(), verify_jwt=FakeVerifier(claims(exp=NOW.timestamp() + 10**6)),
                                        budget=budget, provider=provider, now=lambda: clock["now"]).status, 200)
        self.assertEqual(handler.handle({"Authorization": "Bearer t"}, body(), verify_jwt=FakeVerifier(claims(exp=NOW.timestamp() + 10**6)),
                                        budget=budget, provider=provider, now=lambda: clock["now"]).status, 429)
        clock["now"] = NOW + dt.timedelta(days=1)
        self.assertEqual(handler.handle({"Authorization": "Bearer t"}, body(), verify_jwt=FakeVerifier(claims(exp=NOW.timestamp() + 10**6)),
                                        budget=budget, provider=provider, now=lambda: clock["now"]).status, 200)


if __name__ == "__main__":
    unittest.main()

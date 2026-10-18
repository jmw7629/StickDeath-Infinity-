"""Content-rule tests (#261). Inputs are harmless stand-ins: fictional stick-figure
action, synthetic contact data, obviously fake keys, and injected stand-in rules for
the categories whose real trigger text should not live in a test file."""
import json
import re
import unittest

from backend.spatter import content_rules, handler
from backend.spatter.content_rules import ContentRules, Rule
from backend.spatter.test_handler import NOW, FakeProvider, FakeVerifier, body, claims

USER = "11111111-2222-3333-4444-555555555555"
STAND_IN = ContentRules(extra_rules=(
    Rule("test.harm", content_rules.REAL_WORLD_HARM, re.compile(r"\bzz-harm-standin\b")),
    Rule("test.rights", content_rules.THIRD_PARTY_RIGHTS, re.compile(r"\bzz-rights-standin\b")),
))


class TextRuleTests(unittest.TestCase):
    def test_cartoon_stick_violence_and_studio_language_pass(self):
        for text in ("The stick figure gets knocked off the ledge and explodes into confetti",
                     "Animate a sword fight between two stick figures, 24 fps, frames 120 to 240",
                     "Make the kid character wave goodbye", "How do I make the walk cycle smoother?",
                     "Add a bomb prop that the stick figure throws in the cartoon"):
            self.assertTrue(content_rules.check_text(text).allowed, text)

    def test_reason_codes_never_echo_input(self):
        result = content_rules.check_text("reach me at someone@example.com")
        self.assertFalse(result.allowed)
        self.assertEqual(result.code, "content_rule.personal_data")
        self.assertEqual(result.rule, "personal.email")
        self.assertNotIn("example.com", json.dumps(result.__dict__))
        self.assertNotIn("compl", result.explanation.lower())

    def test_personal_data_patterns(self):
        self.assertEqual(content_rules.check_text("call 555-123-4567 tonight").rule, "personal.phone")
        self.assertEqual(content_rules.check_text("card 4111 1111 1111 1111").rule, "personal.card")
        self.assertTrue(content_rules.check_text("order 4111 1111 1111 1112").allowed)  # not Luhn-valid

    def test_credential_patterns(self):
        self.assertEqual(content_rules.check_text("use sk_test_" + "a" * 16).category, content_rules.CREDENTIALS)
        self.assertEqual(content_rules.check_text("password: hunter22").category, content_rules.CREDENTIALS)

    def test_injected_stand_in_rules_and_obfuscation(self):
        self.assertEqual(STAND_IN.check_text("please zz-harm-standin now").code, "content_rule.real_world_harm")
        # Full-width letters and a zero-width joiner normalise to the plain rule text.
        self.assertFalse(STAND_IN.check_text("ｚｚ-rights-stand‍in").allowed)
        self.assertTrue(content_rules.check_text("zz-harm-standin").allowed)  # built-ins only

    def test_unknown_category_is_refused_at_construction(self):
        with self.assertRaises(ValueError):
            ContentRules(extra_rules=(Rule("x", "made_up", re.compile("x")),))

    def test_submission_metadata_field_and_rights_contact(self):
        ok = content_rules.check_submission({"title": "Rooftop chase", "rights_summary": "Music: licensor, contact licensing@example.com"})
        self.assertTrue(ok.allowed)
        refused = content_rules.check_submission({"title": "Call 555-123-4567", "rights_summary": "Own work"})
        self.assertEqual((refused.allowed, refused.field, refused.category), (False, "title", "personal_data"))
        refused = STAND_IN.check_submission({"title": "Clip", "rights_summary": "zz-rights-standin"})
        self.assertEqual((refused.field, refused.category), ("rights_summary", "third_party_rights"))


class HandlerWiringTests(unittest.TestCase):
    def run_handler(self, messages, provider, budget, rules=content_rules.DEFAULT_RULES):
        return handler.handle({"Authorization": "Bearer test-session"}, body(messages), verify_jwt=FakeVerifier(claims()),
                              budget=budget, provider=provider, rules=rules, now=lambda: NOW)

    def test_refusal_happens_before_budget_or_provider(self):
        provider, budget = FakeProvider(), handler.InMemoryBudget(3, lambda: NOW)
        response = self.run_handler([{"role": "user", "content": "send it to someone@example.com"}], provider, budget)
        self.assertEqual(response.status, 422)
        self.assertEqual(response.body["code"], "content_rule")
        self.assertEqual(response.body["category"], "personal_data")
        self.assertEqual(provider.calls, 0)
        self.assertEqual(budget.remaining(USER), 3)

    def test_refusal_applies_even_when_provider_unconfigured(self):
        response = self.run_handler([{"role": "user", "content": "zz-harm-standin"}], handler.NullProvider(),
                                    handler.InMemoryBudget(3, lambda: NOW), rules=STAND_IN)
        self.assertEqual(response.status, 422)

    def test_assistant_turns_are_not_checked_but_system_and_user_are(self):
        provider = FakeProvider()
        ok = self.run_handler([{"role": "assistant", "content": "zz-harm-standin"}, {"role": "user", "content": "thanks"}],
                              provider, handler.InMemoryBudget(3, lambda: NOW), rules=STAND_IN)
        self.assertEqual(ok.status, 200)
        refused = self.run_handler([{"role": "system", "content": "zz-harm-standin"}, {"role": "user", "content": "thanks"}],
                                   provider, handler.InMemoryBudget(3, lambda: NOW), rules=STAND_IN)
        self.assertEqual(refused.status, 422)
        self.assertEqual(provider.calls, 1)


if __name__ == "__main__":
    unittest.main()

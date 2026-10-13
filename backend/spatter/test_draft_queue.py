"""Deterministic planner and worker state-machine tests (#212) with fakes only: no network, provider, renderer or database."""
import datetime as dt
import re
import unittest

from backend.spatter import draft_queue as dq


NOW = dt.datetime(2026, 10, 13, 9, 0, tzinfo=dt.timezone.utc)
TODAY = NOW.date()
SHA = "ab" * 32
DIGEST = "cd" * 32


class FakeRenderer:
    def __init__(self, passes=True, error=None):
        self.passes, self.error, self.calls = passes, error, 0

    def render(self, plan, heartbeat):
        self.calls += 1
        heartbeat()
        if self.error:
            raise self.error
        quality = {"passes": self.passes, "failures": [] if self.passes else ["1 blank frame(s); limit 0."]}
        return dq.RenderResult(sha256=SHA, storyboard={"schema": "spatter_storyboard", "version": 1, "brief": plan.brief, "seed": plan.seed},
                               quality=quality, source_project_digest=DIGEST, preview_url="https://private.example/draft.mp4")


class PlannerTests(unittest.TestCase):
    def test_plan_is_deterministic_and_in_the_app_grammar(self):
        first, second = dq.plan_brief(TODAY), dq.plan_brief(TODAY)
        self.assertEqual(first, second)
        self.assertEqual(first.seed, dq.seed_for(TODAY))
        self.assertTrue(dq.BRIEF_PATTERN.match(first.brief.lower()), first.brief)
        self.assertTrue(first.brief.endswith(f"; seed {first.seed}."))
        self.assertIn(first.actors, (1, 2, 3))
        self.assertTrue(3 <= first.seconds <= 8)
        self.assertNotEqual(first.brief, dq.plan_brief(TODAY + dt.timedelta(days=1)).brief)
        self.assertLess(first.seed, 1 << 63)

    def test_sixty_days_of_plans_are_distinct_valid_and_terminal_last(self):
        seen = set()
        for offset in range(60):
            plan = dq.plan_brief(TODAY + dt.timedelta(days=offset))
            self.assertNotIn(plan.brief, seen)
            seen.add(plan.brief)
            for segment in plan.brief.rstrip(".").split("; ")[:-2]:
                clauses = segment.split(" stick figure ", 1)[1].split(", then ")
                for clause in clauses[:-1]:
                    self.assertNotIn(clause.split(" ")[0], dq.TERMINAL_ACTIONS, plan.brief)
                self.assertTrue(all(re.fullmatch(r"[a-z]+( left to right| right to left)?", c) for c in clauses), plan.brief)
            self.assertLessEqual(plan.brief.count("falls") + plan.brief.count("explodes"), 1)
            self.assertLessEqual(len(plan.brief.encode()), 1024)


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.clock = {"now": NOW}
        self.gate = {"reason": None}
        self.store = dq.InMemoryStore(now=lambda: self.clock["now"], gate=lambda: self.gate["reason"])

    def run_once(self, renderer=None, owner="worker-a", day=None):
        return dq.run_once(self.store, owner=owner, reviewer="owner-uuid", now=lambda: self.clock["now"], renderer=renderer, target_date=day)

    def test_without_a_renderer_the_job_fails_with_the_owner_gate_message(self):
        outcome = self.run_once()
        self.assertTrue(outcome.claimed)
        self.assertEqual(outcome.state, "failed")
        self.assertIn("OWNER-GATED", outcome.reason)
        self.assertEqual(self.store.jobs[TODAY]["state"], "failed")
        self.assertEqual(self.store.reviews, [])

    def test_agent_gate_refusal_claims_nothing(self):
        self.gate["reason"] = "Agent is paused."
        outcome = self.run_once(FakeRenderer())
        self.assertFalse(outcome.claimed)
        self.assertEqual(outcome.reason, "Agent is paused.")
        self.assertEqual(self.store.jobs[TODAY]["state"], "planned")

    def test_successful_render_submits_a_private_review_and_is_not_reclaimable(self):
        renderer = FakeRenderer()
        outcome = self.run_once(renderer)
        self.assertEqual((outcome.state, outcome.attempt, renderer.calls), ("review_pending", 1, 1))
        review = self.store.reviews[0]
        self.assertEqual((review["render_digest"], review["source_project_digest"], review["state"], review["destinations"]), (SHA, DIGEST, "pending", []))
        self.assertEqual(review["storyboard"]["seed"], outcome.plan.seed)
        again = self.run_once(renderer)
        self.assertFalse(again.claimed)
        self.assertEqual(again.reason, "Job is review_pending.")
        self.assertEqual(renderer.calls, 1)

    def test_failures_retry_up_to_three_attempts_then_stop(self):
        renderer = FakeRenderer(error=RuntimeError("encoder refused"))
        for attempt in (1, 2, 3):
            outcome = self.run_once(renderer)
            self.assertEqual((outcome.state, outcome.attempt), ("failed", attempt))
            self.assertIn("encoder refused", outcome.reason)
        blocked = self.run_once(renderer)
        self.assertFalse(blocked.claimed)
        self.assertEqual(blocked.reason, "Retry limit reached (3 attempts).")
        self.assertEqual(renderer.calls, 3)

    def test_failing_quality_gate_records_the_finding_instead_of_a_review(self):
        outcome = self.run_once(FakeRenderer(passes=False))
        self.assertEqual(outcome.state, "failed")
        self.assertIn("blank frame", outcome.reason)
        self.assertEqual(self.store.reviews, [])
        self.assertEqual(self.store.jobs[TODAY]["quality"]["passes"], False)

    def test_second_worker_cannot_duplicate_or_progress_the_job(self):
        first = self.store.claim(TODAY, "worker-a", 1, dq.BRIEF_VERSION, {"text": "x"})
        second = self.store.claim(TODAY, "worker-b", 2, dq.BRIEF_VERSION, {"text": "y"})
        self.assertTrue(first["claimed"]); self.assertFalse(second["claimed"])
        self.assertEqual(len(self.store.jobs), 1)
        self.assertEqual(self.store.jobs[TODAY]["planner_seed"], 1)
        self.assertEqual(self.store.progress(first["job"], "worker-b", "rendering")["status"], "refused")

    def test_expired_lease_returns_to_planned_and_missed_days_are_shown(self):
        claim = self.store.claim(TODAY, "worker-a", 1, dq.BRIEF_VERSION, {"text": "x"})
        self.clock["now"] = NOW + dt.timedelta(minutes=16)
        self.assertEqual(self.store.progress(claim["job"], "worker-a", "rendering")["status"], "refused")
        reclaimed = self.store.claim(TODAY, "worker-c", 1, dq.BRIEF_VERSION, {"text": "x"})
        self.assertTrue(reclaimed["claimed"]); self.assertEqual(reclaimed["attempt"], 2)
        self.store.jobs[TODAY - dt.timedelta(days=2)] = {"id": "old", "target_date": TODAY - dt.timedelta(days=2), "state": "planned", "attempts": 0,
            "planner_seed": 5, "brief_version": dq.BRIEF_VERSION, "brief": {}, "error": "", "lease_owner": None, "lease_expires_at": None,
            "review_id": None, "storyboard": None, "quality": None, "sha256": None}
        report = dq.status_report(self.store, TODAY - dt.timedelta(days=3), TODAY)
        self.assertEqual([d["state"] for d in report], ["missed", "missed", "missed", "claimed"])
        past = self.run_once(FakeRenderer(), day=TODAY - dt.timedelta(days=1))
        self.assertFalse(past.claimed)
        self.assertIn("recorded as missed", past.reason)

    def test_outcome_dict_is_public_safe(self):
        outcome = self.run_once(FakeRenderer()).as_dict()
        self.assertEqual(set(outcome), {"date", "claimed", "state", "reason", "job", "review", "attempt"})
        self.assertNotIn("preview", outcome["reason"].lower())


if __name__ == "__main__":
    unittest.main()

"""Deterministic daily-draft planner and worker loop (#212).

The planner turns a calendar date into a brief in the app's multi-clause grammar
(`SpatterMultiClauseBrief` in StickDeathInfinity/Models/SpatterMotionRecipe.swift):
same date → same seed → same brief, replayable from `planner_seed`. The worker
claims the day's job through the SQL contract in `backend/sql/spatter-draft-jobs.sql`
(behind the owner's `spatter_daily_video` agent gate), asks an injected renderer
for the private draft and either submits it to the owner's review queue or records
the failure. Nothing here renders, publishes, schedules itself, buys capacity or
contacts a provider; without a renderer every job is marked failed with an
explicit OWNER-GATED capacity message.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import json
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping, Optional, Protocol

BRIEF_VERSION = "briefs.v2"
ACTIONS = ("walks", "runs", "jumps", "waves", "punches", "kicks", "sits", "ducks", "throws")
TERMINAL_ACTIONS = ("falls", "explodes")
COLORS = ("red", "blue", "green", "black", "orange", "purple", "cyan", "magenta")
DIRECTIONS = ("left to right", "right to left")
TRAVELLING = {"walks", "runs", "jumps"}
CAPACITY_NOT_CONFIGURED = "Render capacity is not configured (OWNER-GATED). No draft was rendered; nothing was purchased."

BRIEF_PATTERN = re.compile(
    r"^(?:a|an) (?P<color>[a-z]+) stick figure (?P<clauses>[a-z ,0-9.]+?)(?:; (?:a|an) [a-z]+ stick figure [a-z ,0-9.]+?)*; "
    r"(?P<seconds>[0-9]+(?:\.[0-9]+)?) seconds; seed (?P<seed>[0-9]+)\.$"
)


class SplitMix64:
    """Same generator as `SpatterDeterministicRandom` so seeds mean the same thing on both sides."""

    MASK = (1 << 64) - 1

    def __init__(self, seed: int):
        self.state = seed & self.MASK

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & self.MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & self.MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & self.MASK
        return z ^ (z >> 31)

    def unit(self) -> float:
        return (self.next() >> 11) / 9007199254740992.0

    def choice(self, items):
        return items[int(self.unit() * len(items)) % len(items)]


def fnv1a(text: str) -> int:
    hash_ = 0xCBF29CE484222325
    for byte in text.encode("utf-8"):
        hash_ ^= byte
        hash_ = (hash_ * 0x100000001B3) & ((1 << 64) - 1)
    return hash_


def seed_for(target_date: _dt.date, version: str = BRIEF_VERSION) -> int:
    """Deterministic, replayable seed. bigint-compatible (63 bits)."""
    return fnv1a(f"{version}:{target_date.isoformat()}") >> 1


@dataclass(frozen=True)
class Plan:
    target_date: _dt.date
    seed: int
    brief: str
    actors: int
    seconds: float
    version: str = BRIEF_VERSION

    def as_record(self) -> dict:
        return {"text": self.brief, "actors": self.actors, "seconds": self.seconds, "seed": self.seed, "version": self.version}


def plan_brief(target_date: _dt.date, version: str = BRIEF_VERSION) -> Plan:
    """One original brief per day: 1–3 actors, 2–4 clauses each, 3–8 seconds, a
    terminal action on at most one actor, written in the app grammar with an
    explicit seed so the app reproduces exactly this plan."""
    seed = seed_for(target_date, version)
    random = SplitMix64(seed)
    actors = 1 + int(random.unit() * 3) % 3
    seconds = 3 + int(random.unit() * 6)  # 3…8 whole seconds keeps every plan within the element budget at 24 FPS
    segments = []
    used_colors: list[str] = []
    terminal_used = False
    for _ in range(actors):
        color = random.choice([c for c in COLORS if c not in used_colors])
        used_colors.append(color)
        clause_count = 2 + int(random.unit() * 3) % 3
        clauses = []
        for index in range(clause_count):
            action = random.choice(ACTIONS)
            if action in TRAVELLING:
                action += " " + random.choice(DIRECTIONS)
            clauses.append(action)
        if not terminal_used and random.unit() < 0.5:
            clauses.append(random.choice(TERMINAL_ACTIONS))
            terminal_used = True
        segments.append(f"a {color} stick figure " + ", then ".join(clauses))
    text = "; ".join(segments) + f"; {seconds} seconds; seed {seed}."
    text = text[0].upper() + text[1:]
    assert BRIEF_PATTERN.match(text.lower()), text
    return Plan(target_date=target_date, seed=seed, brief=text, actors=actors, seconds=float(seconds), version=version)


# --- Worker ---------------------------------------------------------------

class Store(Protocol):
    """The SQL contract (`sdi_spatter_draft_claim` / `sdi_spatter_draft_progress`), service role only."""

    def claim(self, target_date: _dt.date, owner: str, seed: int, version: str, brief: Mapping[str, Any]) -> Mapping[str, Any]: ...

    def progress(self, job: str, owner: str, state: str, *, storyboard: Optional[Mapping[str, Any]] = None,
                 quality: Optional[Mapping[str, Any]] = None, sha256: Optional[str] = None,
                 error: str = "", review: Optional[Mapping[str, Any]] = None) -> Mapping[str, Any]: ...


@dataclass(frozen=True)
class RenderResult:
    """What a real renderer must hand back: measured, never estimated."""
    sha256: str
    storyboard: Mapping[str, Any]
    quality: Mapping[str, Any]
    source_project_digest: str
    preview_url: str


class Renderer(Protocol):
    def render(self, plan: Plan, heartbeat: Callable[[], None]) -> RenderResult: ...


@dataclass
class RunOutcome:
    target_date: _dt.date
    claimed: bool
    state: str
    reason: str = ""
    job: Optional[str] = None
    review: Optional[str] = None
    attempt: Optional[int] = None
    plan: Optional[Plan] = field(default=None, repr=False)

    def as_dict(self) -> dict:
        return {"date": self.target_date.isoformat(), "claimed": self.claimed, "state": self.state, "reason": self.reason,
                "job": self.job, "review": self.review, "attempt": self.attempt}


def run_once(store: Store, *, owner: str, reviewer: str, now: Callable[[], _dt.datetime],
             renderer: Optional[Renderer] = None, target_date: Optional[_dt.date] = None) -> RunOutcome:
    """One worker pass for one day. Idempotent: a re-run after a crash either
    reclaims (within three attempts) or reports why not. Never raises on refusal."""
    day = target_date or now().astimezone(_dt.timezone.utc).date()
    plan = plan_brief(day)
    claim = store.claim(day, owner, plan.seed, plan.version, plan.as_record())
    if not claim.get("claimed"):
        return RunOutcome(day, False, "not_claimed", str(claim.get("reason", "")), claim.get("job"), plan=plan)
    job = str(claim["job"])
    attempt = claim.get("attempt")
    if renderer is None:
        store.progress(job, owner, "failed", error=CAPACITY_NOT_CONFIGURED)
        return RunOutcome(day, True, "failed", CAPACITY_NOT_CONFIGURED, job, attempt=attempt, plan=plan)
    started = store.progress(job, owner, "rendering")
    if started.get("status") != "confirmed":
        return RunOutcome(day, True, "refused", str(started.get("reason", "")), job, attempt=attempt, plan=plan)
    try:
        result = renderer.render(plan, lambda: store.progress(job, owner, "rendering"))
    except Exception as error:  # the renderer's own message is public-safe by contract; never a traceback
        reason = f"Render failed: {type(error).__name__}: {error}"[:2000]
        store.progress(job, owner, "failed", error=reason)
        return RunOutcome(day, True, "failed", reason, job, attempt=attempt, plan=plan)
    if not result.quality.get("passes"):
        reason = "Quality gate failed: " + "; ".join(str(f) for f in result.quality.get("failures", []))[:1900]
        store.progress(job, owner, "failed", quality=result.quality, error=reason)
        return RunOutcome(day, True, "failed", reason, job, attempt=attempt, plan=plan)
    submitted = store.progress(job, owner, "review_pending", storyboard=result.storyboard, quality=result.quality, sha256=result.sha256,
                               review={"creator": reviewer, "preview_url": result.preview_url, "source_project_digest": result.source_project_digest,
                                       "title": f"Spatter daily draft {day.isoformat()}", "source_revision": f"draft:{day.isoformat()}:seed:{plan.seed}"})
    if submitted.get("status") != "confirmed":
        return RunOutcome(day, True, "refused", str(submitted.get("reason", "")), job, attempt=attempt, plan=plan)
    return RunOutcome(day, True, "review_pending", "Private draft submitted to the owner's review queue; nothing is released.",
                      job, review=str(submitted.get("review")), attempt=attempt, plan=plan)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class InMemoryStore:
    """Reference implementation of the SQL state machine for tests and local previews.
    It mirrors the candidate's rules: unique target_date, forward-only transitions,
    lease ownership, three attempts, past dates become missed."""

    def __init__(self, now: Callable[[], _dt.datetime], gate: Callable[[], Optional[str]] = lambda: None):
        self.now = now
        self.gate = gate  # returns a refusal reason, or None when the agent gate allows a run
        self.jobs: dict = {}
        self.reviews: list = []
        self._counter = 0

    def _today(self) -> _dt.date:
        return self.now().astimezone(_dt.timezone.utc).date()

    def sweep(self) -> None:
        for job in self.jobs.values():
            if job["state"] in ("planned", "claimed", "rendering", "failed") and job["target_date"] < self._today():
                job["state"] = "missed"; job["lease_owner"] = None
            elif job["state"] in ("claimed", "rendering") and job["lease_expires_at"] < self.now():
                job["state"] = "planned"; job["lease_owner"] = None; job["error"] = "Lease expired before the render finished."

    def claim(self, target_date, owner, seed, version, brief):
        self.sweep()
        if target_date < self._today():
            return {"claimed": False, "reason": "The target date has passed; it is recorded as missed, not back-filled."}
        job = self.jobs.get(target_date)
        if job is None:
            self._counter += 1
            job = self.jobs[target_date] = {"id": f"job-{self._counter}", "target_date": target_date, "state": "planned", "attempts": 0,
                                             "planner_seed": seed, "brief_version": version, "brief": dict(brief), "error": "",
                                             "lease_owner": None, "lease_expires_at": None, "review_id": None, "storyboard": None, "quality": None, "sha256": None}
        if job["state"] not in ("planned", "failed"):
            return {"claimed": False, "reason": f"Job is {job['state']}.", "job": job["id"]}
        if job["attempts"] >= 3:
            return {"claimed": False, "reason": "Retry limit reached (3 attempts).", "job": job["id"]}
        refusal = self.gate()
        if refusal:
            return {"claimed": False, "reason": refusal, "job": job["id"]}
        job.update(state="claimed", attempts=job["attempts"] + 1, lease_owner=owner, lease_expires_at=self.now() + _dt.timedelta(minutes=15), error="")
        return {"claimed": True, "job": job["id"], "attempt": job["attempts"], "brief": job["brief"], "planner_seed": job["planner_seed"]}

    def _job(self, job_id):
        return next((j for j in self.jobs.values() if j["id"] == job_id), None)

    def progress(self, job, owner, state, *, storyboard=None, quality=None, sha256=None, error="", review=None):
        record = self._job(job)
        if record is None or record["lease_owner"] != owner or record["lease_expires_at"] < self.now():
            return {"status": "refused", "reason": "Not the current lease holder."}
        if state == "rendering" and record["state"] in ("claimed", "rendering"):
            record["state"] = "rendering"; record["lease_expires_at"] = self.now() + _dt.timedelta(minutes=15)
            if storyboard is not None: record["storyboard"] = storyboard
            return {"status": "confirmed", "state": "rendering"}
        if state == "failed" and record["state"] in ("claimed", "rendering"):
            record.update(state="failed", error=error[:2000], lease_owner=None, lease_expires_at=None)
            if quality is not None: record["quality"] = quality
            return {"status": "confirmed", "state": "failed", "attempts": record["attempts"]}
        if state == "review_pending" and record["state"] == "rendering":
            if not (sha256 and re.fullmatch(r"[a-f0-9]{64}", sha256) and storyboard is not None and quality is not None and review
                    and review.get("creator") and review.get("preview_url") and re.fullmatch(r"[a-f0-9]{64}", str(review.get("source_project_digest", "")))):
                return {"status": "refused", "reason": "A review needs the render digest, storyboard, quality report, source digest, creator and private preview URL."}
            if not quality.get("passes"):
                return {"status": "refused", "reason": "The quality report did not pass; mark the job failed with the finding instead."}
            review_id = f"review-{len(self.reviews) + 1}"
            self.reviews.append({"id": review_id, "render_digest": sha256, "storyboard": storyboard, "source_project_digest": review["source_project_digest"],
                                 "state": "pending", "spatter_generated": True, "destinations": []})
            record.update(state="review_pending", storyboard=storyboard, quality=quality, sha256=sha256, review_id=review_id, lease_owner=None, lease_expires_at=None)
            return {"status": "confirmed", "state": "review_pending", "review": review_id}
        return {"status": "refused", "reason": f"Transition {record['state']} → {state} is not allowed."}


def status_report(store: InMemoryStore, start: _dt.date, end: _dt.date) -> list:
    """Owner-facing day list: missed and failed days are shown, never summarized as success."""
    store.sweep()
    days = []
    day = start
    while day <= end:
        job = store.jobs.get(day)
        state = job["state"] if job else ("missed" if day < store._today() else "unplanned")
        days.append({"date": day.isoformat(), "state": state, "attempts": job["attempts"] if job else 0, "error": job["error"] if job else ""})
        day += _dt.timedelta(days=1)
    return days


if __name__ == "__main__":  # pragma: no cover - manual inspection only
    today = _dt.datetime.now(_dt.timezone.utc).date()
    print(json.dumps(plan_brief(today).as_record(), indent=2))

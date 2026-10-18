"""CLI draft-renderer adapter tests (#212) against fake renderer executables.

The fakes stand in for `Tools/SpatterDraftRenderer` (macOS only): they write
files and print receipts so the subprocess, timeout, heartbeat and receipt
validation paths run for real. No network, provider, upload or database."""
import datetime as dt
import hashlib
import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

from backend.spatter import draft_queue as dq
from backend.spatter import renderer_cli as rc

NOW = dt.datetime(2026, 10, 18, 9, 0, tzinfo=dt.timezone.utc)
TODAY = NOW.date()

FAKE = textwrap.dedent('''\
    #!{python}
    import hashlib, json, os, sys, time
    MODE = {mode!r}
    args = sys.argv[1:]
    job = json.load(open(args[args.index("--job") + 1]))
    out = args[args.index("--output-dir") + 1]
    if MODE == "sleep":
        time.sleep(30)
    if MODE == "refuse":
        print(json.dumps({{"schema": "sdi_spatter_draft_render_receipt", "version": 1, "status": "failed", "private_draft": True,
                          "published": False, "owner_approval_required": True, "error": "The brief could not be planned: budget"}}))
        sys.exit(2)
    if MODE == "garbage":
        print("not json"); sys.exit(0)
    work = os.path.join(out, "spatter-draft-x")
    os.mkdir(work)
    def put(name, data):
        path = os.path.join(work, name)
        open(path, "wb").write(data)
        return path, hashlib.sha256(data).hexdigest(), len(data)
    movie = put("spatter-draft.mp4", b"\\x00\\x00\\x00\\x18ftypmp42" + job["brief"].encode())
    manifest = put("manifest.json", b'{{"version":1}}')
    project = put("project.json", json.dumps({{"brief": job["brief"]}}, sort_keys=True).encode())
    seconds = float(job["brief"].rsplit("; ", 2)[1].split()[0])
    frames = int(round(seconds * job["fps"]))
    passes = MODE != "quality"
    receipt = {{
        "schema": "sdi_spatter_draft_render_receipt", "version": 1, "status": "rendered", "job_id": job["job_id"],
        "private_draft": True, "published": MODE == "published", "owner_approval_required": True,
        "brief": job["brief"], "seed": job["seed"], "fps": job["fps"], "width": job["width"], "height": job["height"],
        "movie": {{"path": movie[0], "sha256": movie[1], "bytes": movie[2], "codec": "avc1"}},
        "manifest": {{"path": manifest[0], "sha256": manifest[1]}},
        "project": {{"path": project[0], "sha256": project[1]}},
        "project_digest": project[1],
        "storyboard": {{"schema": "spatter_storyboard", "version": 1, "seed": int(job["seed"]), "brief": job["brief"].lower()}},
        "decoded_frame_count": frames - (1 if MODE == "short" else 0), "expected_frame_count": frames,
        "decoded_duration_seconds": seconds, "expected_duration_seconds": seconds,
        "quality": {{"passes": passes, "failures": [] if passes else ["1 blank frame(s); limit 0."], "findings": []}},
    }}
    if MODE == "tampered":
        receipt["movie"]["sha256"] = "0" * 64
    if MODE == "outside":
        receipt["movie"]["path"] = "/etc/hosts"
    if MODE == "wrong_seed":
        receipt["seed"] = "1"
    print(json.dumps(receipt))
''')


class Previews:
    def __init__(self):
        self.calls = []

    def __call__(self, path, sha, plan):
        self.calls.append((path, sha, plan.seed))
        assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == sha
        return f"https://private.example/v1/render-previews/{sha}"


class CLIRendererTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.output = self.root / "drafts"
        self.plan = dq.plan_brief(TODAY)
        self.beats = 0
        self.previews = Previews()

    def tearDown(self):
        self.temp.cleanup()

    def fake(self, mode="ok") -> Path:
        path = self.root / f"fake-{mode}"
        path.write_text(FAKE.format(python=sys.executable, mode=mode))
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def renderer(self, mode="ok", **kwargs):
        kwargs.setdefault("publish_preview", self.previews)
        return rc.CLIRenderer(self.fake(mode), self.output, kwargs.pop("publish_preview"), **kwargs)

    def heartbeat(self):
        self.beats += 1

    def test_success_validates_receipt_against_files_and_keeps_private_draft(self):
        result = self.renderer().render(self.plan, self.heartbeat)
        self.assertRegex(result.sha256, r"^[a-f0-9]{64}$")
        self.assertTrue(result.quality["passes"])
        self.assertEqual(result.quality["decoded_frame_count"], int(self.plan.seconds * 24))
        self.assertEqual(result.storyboard["seed"], self.plan.seed)
        self.assertTrue(result.preview_url.startswith("https://"))
        self.assertEqual(len(self.previews.calls), 1)
        movie = Path(self.previews.calls[0][0])
        self.assertTrue(movie.is_file() and self.output in movie.parents, "private draft must stay under the output root")
        job = json.loads(next(self.output.glob("draft-*/job.json")).read_text())
        self.assertEqual(job["brief"], self.plan.brief)
        self.assertEqual(job["seed"], str(self.plan.seed), "63-bit seed must travel as an exact decimal string")
        self.assertGreaterEqual(self.beats, 2)

    def test_run_once_submits_only_to_review_queue(self):
        store = dq.InMemoryStore(now=lambda: NOW)
        outcome = dq.run_once(store, owner="worker", reviewer="owner", now=lambda: NOW, renderer=self.renderer())
        self.assertEqual(outcome.state, "review_pending", outcome.reason)
        review = store.reviews[0]
        self.assertEqual(review["state"], "pending")
        self.assertTrue(review["spatter_generated"])
        self.assertEqual(review["destinations"], [], "nothing is released or scheduled for publication")

    def test_refusal_is_reported_and_run_directory_removed(self):
        store = dq.InMemoryStore(now=lambda: NOW)
        outcome = dq.run_once(store, owner="worker", reviewer="owner", now=lambda: NOW, renderer=self.renderer("refuse"))
        self.assertEqual(outcome.state, "failed")
        self.assertIn("refused or failed (exit 2)", outcome.reason)
        self.assertIn("budget", outcome.reason)
        self.assertEqual(store.jobs[TODAY]["state"], "failed")
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertEqual(self.previews.calls, [])

    def test_quality_failure_is_not_previewed_and_marks_job_failed(self):
        store = dq.InMemoryStore(now=lambda: NOW)
        outcome = dq.run_once(store, owner="worker", reviewer="owner", now=lambda: NOW, renderer=self.renderer("quality"))
        self.assertEqual(outcome.state, "failed")
        self.assertIn("Quality gate failed", outcome.reason)
        self.assertEqual(self.previews.calls, [])
        self.assertEqual(store.reviews, [])

    def test_decoded_frame_shortfall_overrides_a_passing_verdict(self):
        result = self.renderer("short").render(self.plan, self.heartbeat)
        self.assertFalse(result.quality["passes"])
        self.assertTrue(any("Decoded" in failure for failure in result.quality["failures"]))
        self.assertEqual(result.preview_url, "")
        self.assertEqual(self.previews.calls, [])

    def test_untrustworthy_receipts_are_rejected(self):
        for mode, needle in [("tampered", "digest does not match"), ("outside", "outside this render"), ("published", "unpublished private draft"),
                             ("wrong_seed", "brief or seed"), ("garbage", "without a valid JSON receipt")]:
            with self.subTest(mode=mode):
                with self.assertRaises(rc.RendererError) as caught:
                    self.renderer(mode).render(self.plan, self.heartbeat)
                self.assertIn(needle, str(caught.exception))
        self.assertEqual(self.previews.calls, [])
        self.assertEqual(list(self.output.iterdir()), [], "rejected renders leave no draft behind")

    def test_timeout_kills_the_renderer_and_keeps_the_lease_alive(self):
        renderer = self.renderer("sleep", timeout=2, heartbeat_interval=1)
        with self.assertRaises(rc.RendererError) as caught:
            renderer.render(self.plan, self.heartbeat)
        self.assertIn("exceeded its 2 s limit", str(caught.exception))
        self.assertGreaterEqual(self.beats, 2)

    def test_missing_preview_publisher_fails_before_rendering(self):
        renderer = self.renderer(publish_preview=None)
        with self.assertRaises(rc.RendererError) as caught:
            renderer.render(self.plan, self.heartbeat)
        self.assertIn("OWNER-GATED", str(caught.exception))
        self.assertFalse(self.output.exists(), "the CLI must not run without a private preview destination")

    def test_preview_publisher_must_return_https(self):
        renderer = self.renderer(publish_preview=lambda path, sha, plan: "http://public.example/x.mp4")
        with self.assertRaises(rc.RendererError):
            renderer.render(self.plan, self.heartbeat)

    def test_environment_selection(self):
        self.assertIsNone(rc.renderer_from_env({}))
        self.assertIsNone(dq.configured_renderer({}))
        store = dq.InMemoryStore(now=lambda: NOW)
        outcome = dq.run_once(store, owner="worker", reviewer="owner", now=lambda: NOW, renderer=dq.configured_renderer({}))
        self.assertEqual(outcome.reason, dq.CAPACITY_NOT_CONFIGURED, "unset CLI keeps the honest OWNER-GATED failure")
        configured = dq.configured_renderer({rc.ENV_CLI: str(self.fake()), rc.ENV_OUTPUT: str(self.output), rc.ENV_FPS: "12",
                                             rc.ENV_WIDTH: "320", rc.ENV_HEIGHT: "180", rc.ENV_TIMEOUT: "120"}, self.previews)
        self.assertIsInstance(configured, rc.CLIRenderer)
        self.assertEqual((configured.fps, configured.width, configured.height, configured.timeout), (12, 320, 180, 120.0))
        for bad in [{rc.ENV_CLI: "relative/renderer"}, {rc.ENV_CLI: str(self.root / "missing")},
                    {rc.ENV_CLI: str(self.fake()), rc.ENV_TIMEOUT: "3600"}, {rc.ENV_CLI: str(self.fake()), rc.ENV_FPS: "x"},
                    {rc.ENV_CLI: str(self.fake()), rc.ENV_OUTPUT: "relative"}]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                rc.renderer_from_env(bad)
        os.chmod(self.fake("noexec"), 0o600)
        with self.assertRaises(ValueError):
            rc.renderer_from_env({rc.ENV_CLI: str(self.root / "fake-noexec")})


if __name__ == "__main__":
    unittest.main()

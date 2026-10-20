"""Offline tests for the feed publisher, destination adapters, marketing worker,
service sweeps and push batch worker. Fake RPC clients record every call; no
network, no provider, no device.

    python3 -m unittest discover -s backend/tests -t .
"""
import contextlib
import fcntl
import hashlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path

from backend.notifications.push import AnnouncementAPI, PushBatchWorker, SinkTransport
from backend.ops import report as ops_report
from backend.ops import sweeps
from backend.publishing import destinations
from backend.publishing.destinations import DestinationConfig, MarketingWorker, Post, default_registry
from backend.publishing.feed_publisher import MAX_POSTER_BYTES, FeedJobAPI, FeedPublisher, ffmpeg_poster, poster_instant
from backend.publishing.worker import JobAPI


class FakeAPI:
    """Answers RPC calls from a dict of scripted results and records them."""

    def __init__(self, script):
        self.script = {k: list(v) for k, v in script.items()}
        self.calls = []

    def call(self, operation, **payload):
        self.calls.append((operation, payload))
        answers = self.script.get(operation)
        if not answers:
            raise AssertionError("unexpected RPC %s %s" % (operation, payload))
        answer = answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer

    def ops(self):
        return [c[0] for c in self.calls]


class FakeHost:
    def __init__(self, fail_put=False, delete_result=True):
        self.puts = []
        self.deletes = []
        self.fail_put = fail_put
        self.delete_result = delete_result

    def put(self, name, source, digest):
        if self.fail_put:
            raise OSError("bucket unavailable")
        self.puts.append((name, Path(source).read_bytes(), digest))
        return "https://cdn.example.test/feed/%s" % name

    def delete(self, url):
        self.deletes.append(url)
        return self.delete_result


class JobAPIPrefixTests(unittest.TestCase):
    def test_subclasses_keep_their_own_prefix_and_allowlist(self):
        api = FeedJobAPI("https://backend.example.test", "service-key")
        self.assertEqual(api.PREFIX, "sdi_feed_")
        with self.assertRaises(ValueError):
            api.call("claim")   # not a feed operation
        legacy = JobAPI("https://backend.example.test", "service-key")
        with self.assertRaises(ValueError):
            legacy.call("publish_claim")
        with self.assertRaises(ValueError):
            JobAPI("http://backend.example.test", "service-key")


class FeedPublisherTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        os.chmod(self.root, 0o700)
        self.payload = b"\x00\x00\x00\x18ftypmp42" + b"m" * 5000
        self.digest = hashlib.sha256(self.payload).hexdigest()
        (self.root / "render.mp4").write_bytes(self.payload)
        self.job_id, self.lease = str(uuid.uuid4()), str(uuid.uuid4())

    def claim(self, **overrides):
        job = {"job": self.job_id, "lease": self.lease, "destination": "feed", "digest": self.digest, "object_key": "render.mp4",
               "byte_count": len(self.payload), "title": "Clip", "description": "A caption.", "made_for_kids": False,
               "creator": str(uuid.uuid4()), "creator_name": "stick", "allow_export": False, "spatter_generated": False}
        job.update(overrides)
        return job

    def publisher(self, api, host=None, duration=12.5, poster=None):
        def no_poster(source, seconds, destination):
            raise FileNotFoundError("no extractor in this fixture")
        return FeedPublisher(api, self.root, host or FakeHost(), lambda path: duration, extract_poster=poster or no_poster)

    @staticmethod
    def jpeg_writer(body=b"\x00" * 64, calls=None):
        def write(source, seconds, destination):
            if calls is not None:
                calls.append((Path(source).read_bytes(), seconds))
            Path(destination).write_bytes(b"\xff\xd8\xff\xe0" + body + b"\xff\xd9")
        return write

    def test_poster_is_extracted_from_the_verified_copy_hashed_and_reported(self):
        api = FakeAPI({"removal_claim": [{"empty": True}], "publish_claim": [self.claim()], "publish_finish": [True]})
        host, calls = FakeHost(), []
        result = self.publisher(api, host, duration=0.8, poster=self.jpeg_writer(calls=calls)).run_once()
        self.assertEqual(result["state"], "published")
        self.assertEqual(calls, [(self.payload, 0.8)])   # the verified file, measured duration
        poster_bytes = b"\xff\xd8\xff\xe0" + b"\x00" * 64 + b"\xff\xd9"
        self.assertEqual([p[0] for p in host.puts], ["%s.mp4" % self.digest, "%s.poster.jpg" % self.digest])
        self.assertEqual(host.puts[1][1:], (poster_bytes, hashlib.sha256(poster_bytes).hexdigest()))
        finish = api.calls[-1][1]
        self.assertEqual(finish["poster_url"], "https://cdn.example.test/feed/%s.poster.jpg" % self.digest)
        self.assertEqual(finish["poster_digest"], hashlib.sha256(poster_bytes).hexdigest())
        self.assertEqual(finish["poster_bytes"], len(poster_bytes))
        self.assertEqual(result["poster"]["url"], finish["poster_url"])
        self.assertEqual([p.name for p in (self.root / ".feed-worker").iterdir()], ["worker.lock"])   # staging removed

    def test_missing_oversized_or_invalid_poster_publishes_the_video_without_one(self):
        def oversize(source, seconds, destination):
            Path(destination).write_bytes(b"\xff\xd8\xff" + b"\x00" * (256 * 1024) + b"\xff\xd9")
        def truncated(source, seconds, destination):
            Path(destination).write_bytes(b"\xff\xd8\xff\xe0" + b"\x00" * 10)
        def nothing(source, seconds, destination):
            pass
        for extractor, fragment in ((oversize, "size"), (truncated, "complete JPEG"), (nothing, "could not be extracted"), (None, "could not be extracted")):
            api = FakeAPI({"removal_claim": [{"empty": True}], "publish_claim": [self.claim()], "publish_finish": [True]})
            host = FakeHost()
            result = self.publisher(api, host, poster=extractor).run_once()
            self.assertEqual(result["state"], "published", fragment)
            self.assertIsNone(result["poster"])
            self.assertIn(fragment, result["poster_reason"])
            self.assertEqual(len(host.puts), 1)
            self.assertNotIn("poster_url", api.calls[-1][1])

    def test_lost_lease_removes_the_orphan_poster_too(self):
        api = FakeAPI({"removal_claim": [{"empty": True}], "publish_claim": [self.claim()], "publish_finish": [False]})
        host = FakeHost()
        result = self.publisher(api, host, poster=self.jpeg_writer()).run_once()
        self.assertEqual(result["state"], "reconcile")
        self.assertTrue(result["orphan_removed"])
        self.assertEqual(host.deletes, [result["url"], "https://cdn.example.test/feed/%s.poster.jpg" % self.digest])

    def test_removal_deletes_the_poster_and_needs_both_confirmed(self):
        removal = {"source": "removal_job", "job": str(uuid.uuid4()), "lease": str(uuid.uuid4()), "url": "https://cdn.example.test/feed/x.mp4",
                   "poster_url": "https://cdn.example.test/feed/x.poster.jpg", "digest": self.digest}
        api = FakeAPI({"removal_claim": [removal], "removal_finish": [True]})
        host = FakeHost()
        self.assertEqual(self.publisher(api, host).run_once()["state"], "removed")
        self.assertEqual(host.deletes, [removal["url"], removal["poster_url"]])

        class PosterStuck(FakeHost):
            def delete(self, url):
                self.deletes.append(url)
                return not url.endswith(".jpg")
        api = FakeAPI({"removal_claim": [removal], "removal_finish": [True]})
        self.assertEqual(self.publisher(api, PosterStuck()).run_once()["state"], "removal_unconfirmed")
        self.assertFalse(api.calls[-1][1]["confirmed"])

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg not installed")
    def test_real_ffmpeg_poster_is_deterministic_and_bounded(self):
        video = self.root / "real.mp4"
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=12:duration=3",
                        "-pix_fmt", "yuv420p", "-c:v", "mpeg4", "-y", str(video)], check=True)
        first, second = self.root / ".a.jpg", self.root / ".b.jpg"
        ffmpeg_poster(video, 3.0, first)
        ffmpeg_poster(video, 3.0, second)
        data = first.read_bytes()
        self.assertEqual(data, second.read_bytes())
        self.assertTrue(data.startswith(b"\xff\xd8\xff") and data.endswith(b"\xff\xd9"))
        self.assertLessEqual(len(data), MAX_POSTER_BYTES)
        self.assertEqual(poster_instant(3.0), 1.0)
        self.assertEqual(poster_instant(0.5), 0.25)
        # Bounded to 640 px on the long edge: the SOF0 frame header holds height then width.
        sof = data.index(b"\xff\xc0")
        height, width = int.from_bytes(data[sof + 5:sof + 7], "big"), int.from_bytes(data[sof + 7:sof + 9], "big")
        self.assertEqual((width, height), (640, 360))

    def test_second_executor_is_busy_and_claims_nothing(self):
        api = FakeAPI({"removal_claim": [{"empty": True}], "publish_claim": [{"empty": True}]})
        publisher = self.publisher(api)
        state = self.root / ".feed-worker"
        state.mkdir(mode=0o700)
        with (state / "worker.lock").open("a") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(publisher.run_once(), {"state": "busy"})
            self.assertEqual(api.calls, [])
        self.assertEqual(publisher.run_once(), {"state": "idle"})

    def test_publishes_verified_bytes_and_reports_the_hosted_url(self):
        api = FakeAPI({"removal_claim": [{"empty": True}], "publish_claim": [self.claim()], "publish_finish": [True]})
        host = FakeHost()
        result = self.publisher(api, host).run_once()
        self.assertEqual(result["state"], "published")
        self.assertEqual(api.ops(), ["removal_claim", "publish_claim", "publish_finish"])
        finish = api.calls[-1][1]
        self.assertEqual(finish, {"job": self.job_id, "token": self.lease, "url": "https://cdn.example.test/feed/%s.mp4" % self.digest, "duration": 12.5})
        self.assertEqual(host.puts[0][1], self.payload)

    def test_digest_mismatch_never_copies(self):
        (self.root / "render.mp4").write_bytes(b"m" * len(self.payload))
        api = FakeAPI({"removal_claim": [{"empty": True}], "publish_claim": [self.claim()], "publish_finish": [True]})
        host = FakeHost()
        result = self.publisher(api, host).run_once()
        self.assertEqual(result["state"], "failed")
        self.assertEqual(host.puts, [])
        self.assertIn("do not match the approved digest", api.calls[-1][1]["failure"])
        self.assertIsNone(api.calls[-1][1]["url"])

    def test_size_mismatch_missing_file_and_escape_are_refused(self):
        for overrides, fragment in (({"byte_count": 1}, "size differs"), ({"object_key": "missing.mp4"}, "missing from staging"), ({"object_key": "../etc"}, "invalid")):
            api = FakeAPI({"removal_claim": [{"empty": True}], "publish_claim": [self.claim(**overrides)], "publish_finish": [True]})
            result = self.publisher(api).run_once()
            self.assertEqual(result["state"], "failed", overrides)
            self.assertIn(fragment, api.calls[-1][1]["failure"])

    def test_bad_duration_and_hosting_failure(self):
        api = FakeAPI({"removal_claim": [{"empty": True}], "publish_claim": [self.claim()], "publish_finish": [True]})
        self.assertEqual(self.publisher(api, duration=0).run_once()["state"], "failed")
        self.assertIn("duration", api.calls[-1][1]["failure"].lower())
        api = FakeAPI({"removal_claim": [{"empty": True}], "publish_claim": [self.claim()], "publish_finish": [True]})
        result = self.publisher(api, FakeHost(fail_put=True)).run_once()
        self.assertEqual(result["state"], "failed")
        self.assertNotIn("bucket", api.calls[-1][1]["failure"])

    def test_lost_lease_after_copy_removes_the_orphan(self):
        api = FakeAPI({"removal_claim": [{"empty": True}], "publish_claim": [self.claim()], "publish_finish": [False]})
        host = FakeHost()
        result = self.publisher(api, host).run_once()
        self.assertEqual(result["state"], "reconcile")
        self.assertTrue(result["orphan_removed"])
        self.assertEqual(host.deletes, [result["url"]])

    def test_removals_run_first_and_only_confirmed_deletion_succeeds(self):
        removal = {"source": "removal_job", "job": str(uuid.uuid4()), "lease": str(uuid.uuid4()), "url": "https://cdn.example.test/feed/x.mp4", "digest": self.digest}
        api = FakeAPI({"removal_claim": [removal], "removal_finish": [True]})
        result = self.publisher(api, FakeHost(delete_result=True)).run_once()
        self.assertEqual(result["state"], "removed")
        self.assertEqual(api.calls[-1][1], {"source": "removal_job", "job": removal["job"], "token": removal["lease"], "confirmed": True})
        api = FakeAPI({"removal_claim": [removal], "removal_finish": [True]})
        result = self.publisher(api, FakeHost(delete_result=False)).run_once()
        self.assertEqual(result["state"], "removal_unconfirmed")
        self.assertFalse(api.calls[-1][1]["confirmed"])

    def test_idle_when_nothing_is_queued(self):
        api = FakeAPI({"removal_claim": [{"empty": True}], "publish_claim": [{"empty": True}]})
        self.assertEqual(self.publisher(api).run_once(), {"state": "idle"})


class FakeTransport:
    def __init__(self, script):
        self.script = list(script)
        self.calls = []

    def __call__(self, method, url, headers, body):
        self.calls.append((method, url, dict(headers), body))
        answer = self.script.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer


class DestinationTests(unittest.TestCase):
    def test_unconfigured_destinations_are_unavailable_and_attempt_nothing(self):
        registry = default_registry()
        transport = FakeTransport([])
        for key, adapter in registry.items():
            outcome = adapter.publish(Post(destination=key, copy="Hello"), transport)
            self.assertEqual(outcome.state, "unavailable", key)
            self.assertTrue(outcome.reason)
        self.assertEqual(transport.calls, [])
        statuses = {s["key"]: s for s in (a.status() for a in registry.values())}
        self.assertFalse(any(s["configured"] for s in statuses.values()))
        self.assertIn("no public API", statuses["youtube"]["reason"])

    def test_dry_run_returns_the_redacted_request_and_sends_nothing(self):
        registry = default_registry({
            "discord": DestinationConfig(enabled=True, dry_run=True, target="123", guild_id="9", credential=lambda: "webhook-token"),
            "x": DestinationConfig(enabled=True, dry_run=True, target="account", credential=lambda: "bearer-secret"),
            "facebook": DestinationConfig(enabled=True, dry_run=True, target="page1", credential=lambda: "page-token"),
        })
        transport = FakeTransport([])
        discord = registry["discord"].publish(Post(destination="discord", copy="New clip", media_url="https://cdn.example.test/a.mp4"), transport)
        self.assertEqual(discord.state, "dry_run")
        self.assertEqual(discord.request["url"], "https://discord.com/api/webhooks/<redacted>")
        self.assertEqual(discord.request["body"]["content"], "New clip\nhttps://cdn.example.test/a.mp4")
        x = registry["x"].publish(Post(destination="x", copy="New clip"), transport)
        self.assertEqual(x.request["headers"]["Authorization"], "<redacted>")
        facebook = registry["facebook"].publish(Post(destination="facebook", copy="New clip", media_url="https://cdn.example.test/a.mp4"), transport)
        self.assertEqual(facebook.request["body"]["access_token"], "<redacted>")
        self.assertEqual(facebook.request["body"]["link"], "https://cdn.example.test/a.mp4")
        self.assertEqual(transport.calls, [])
        self.assertNotIn("webhook-token", json.dumps([discord.request, x.request, facebook.request]))

    def test_live_posting_uses_the_transport_and_parses_real_results(self):
        registry = default_registry({
            "discord": DestinationConfig(enabled=True, dry_run=False, target="123", guild_id="9", credential=lambda: "webhook-token"),
            "x": DestinationConfig(enabled=True, dry_run=False, target="account", credential=lambda: "bearer-secret"),
            "facebook": DestinationConfig(enabled=True, dry_run=False, target="page1", credential=lambda: "page-token"),
        })
        transport = FakeTransport([(200, {}, json.dumps({"id": "555", "channel_id": "77"}).encode())])
        outcome = registry["discord"].publish(Post(destination="discord", copy="Clip"), transport)
        self.assertEqual((outcome.state, outcome.result_url, outcome.provider_ref), ("published", "https://discord.com/channels/9/77/555", "555"))
        self.assertIn("webhook-token", transport.calls[0][1])          # the real request carries the credential
        transport = FakeTransport([(201, {}, json.dumps({"data": {"id": "42"}}).encode())])
        outcome = registry["x"].publish(Post(destination="x", copy="Clip"), transport)
        self.assertEqual(outcome.result_url, "https://x.com/i/web/status/42")
        self.assertEqual(transport.calls[0][2]["Authorization"], "Bearer bearer-secret")
        transport = FakeTransport([(200, {}, json.dumps({"id": "page1_99"}).encode())])
        outcome = registry["facebook"].publish(Post(destination="facebook", copy="Clip"), transport)
        self.assertEqual(outcome.result_url, "https://www.facebook.com/page1_99")
        transport = FakeTransport([(403, {}, b'{"error":"forbidden"}')])
        outcome = registry["facebook"].publish(Post(destination="facebook", copy="Clip"), transport)
        self.assertEqual(outcome.state, "failed")
        self.assertNotIn("page-token", outcome.reason)
        transport = FakeTransport([OSError("down")])
        self.assertEqual(registry["x"].publish(Post(destination="x", copy="Clip"), transport).state, "failed")

    def test_platform_limits_are_enforced_before_sending(self):
        registry = default_registry({
            "discord": DestinationConfig(enabled=True, dry_run=False, target="123", credential=lambda: "t"),
            "x": DestinationConfig(enabled=True, dry_run=False, target="a", credential=lambda: "t"),
        })
        transport = FakeTransport([])
        long_copy = "x" * 1990
        self.assertEqual(registry["discord"].publish(Post(destination="discord", copy=long_copy, media_url="https://cdn.example.test/a.mp4"), transport).state, "failed")
        self.assertEqual(registry["x"].publish(Post(destination="x", copy="y" * 270, media_url="https://cdn.example.test/a.mp4"), transport).state, "failed")
        self.assertEqual(registry["x"].publish(Post(destination="facebook", copy="wrong adapter"), transport).state, "failed")
        self.assertEqual(transport.calls, [])
        with self.assertRaises(ValueError):
            Post(destination="x", copy="c", media_url="http://insecure.example/a.mp4")


class MarketingWorkerTests(unittest.TestCase):
    def claim(self, destination="discord"):
        return {"draft": str(uuid.uuid4()), "lease": str(uuid.uuid4()), "destination": destination, "copy": "Daily draft.", "digest": "a" * 64,
                "media_url": "https://cdn.example.test/a.mp4", "object_key": "a.mp4", "byte_count": 10, "title": "Clip", "brand_voice_version": 1, "attempt": 1}

    def test_dry_run_is_recorded_as_a_failure_never_as_published(self):
        api = FakeAPI({"claim": [self.claim()], "finish": [True]})
        registry = default_registry({"discord": DestinationConfig(enabled=True, dry_run=True, target="1", credential=lambda: "t")})
        result = MarketingWorker(api, registry).run_once()
        self.assertEqual(result["state"], "dry_run")
        finish = api.calls[-1][1]
        self.assertIn("Dry run only", finish["failure"])
        self.assertNotIn("result_url", finish)

    def test_unavailable_destination_fails_with_the_reason(self):
        api = FakeAPI({"claim": [self.claim("tiktok")], "finish": [True]})
        result = MarketingWorker(api, default_registry()).run_once()
        self.assertEqual(result["state"], "unavailable")
        self.assertIn("TikTok", api.calls[-1][1]["failure"])

    def test_live_result_is_reported_with_the_provider_link(self):
        api = FakeAPI({"claim": [self.claim()], "finish": [True]})
        registry = default_registry({"discord": DestinationConfig(enabled=True, dry_run=False, target="1", guild_id="g", credential=lambda: "t")})
        transport = FakeTransport([(200, {}, json.dumps({"id": "5", "channel_id": "6"}).encode())])
        result = MarketingWorker(api, registry, transport).run_once()
        self.assertEqual(result["state"], "published")
        self.assertEqual(api.calls[-1][1]["result_url"], "https://discord.com/channels/g/6/5")
        api = FakeAPI({"claim": [self.claim()], "finish": [False]})
        transport = FakeTransport([(200, {}, json.dumps({"id": "5", "channel_id": "6"}).encode())])
        self.assertEqual(MarketingWorker(api, registry, transport).run_once()["state"], "late_result")

    def test_idle_and_unknown_destination(self):
        self.assertEqual(MarketingWorker(FakeAPI({"claim": [{"empty": True}]}), default_registry()).run_once(), {"state": "idle"})
        api = FakeAPI({"claim": [self.claim("myspace")], "finish": [True]})
        self.assertEqual(MarketingWorker(api, default_registry()).run_once()["state"], "failed")


class SweepTests(unittest.TestCase):
    def test_runs_each_named_sweep_once_and_loops_deletion_until_idle(self):
        api = FakeAPI({"billing_reconcile": [{"expired_now": 1, "measured_at": "t", "list": [1, 2]}],
                       "account_deletion_run": [{"action": "prepared", "user": "u"}, {"action": "purged"}, {"action": "idle"}],
                       "war_expire_proposals": [3], "worker_heartbeat": [True]})
        report = sweeps.run_sweeps(api, ["billing_reconcile", "account_deletion_run", "war_expire_proposals", "nonsense"])
        self.assertEqual(report["billing_reconcile"], {"state": "ok", "iterations": 1, "result": {"expired_now": 1, "measured_at": "t"}})
        self.assertEqual(report["account_deletion_run"]["iterations"], 3)
        self.assertEqual(report["war_expire_proposals"]["result"], 3)
        self.assertEqual(report["nonsense"]["state"], "skipped")
        self.assertEqual(api.calls[-1], ("worker_heartbeat", {"worker": "service-sweeps", "note": "ok"}))

    def test_failures_are_reported_without_detail_and_do_not_stop_other_sweeps(self):
        api = FakeAPI({"support_retention": [RuntimeError("Job service response unavailable; secret=abc")], "challenge_finalize": [{"finalized": 0}], "worker_heartbeat": [True]})
        report = sweeps.run_sweeps(api, ["support_retention", "challenge_finalize"])
        self.assertEqual(report["support_retention"], {"state": "failed", "iterations": 0, "error": "RuntimeError"})
        self.assertEqual(report["challenge_finalize"]["state"], "ok")
        self.assertEqual(api.calls[-1][1]["note"], "failed: support_retention")
        self.assertNotIn("secret", json.dumps(report))

    def test_room_sweep_reports_asset_and_project_handoff_counts(self):
        api = FakeAPI({"room_asset_sweep": [{"discarded": 1, "verified": 1, "unverified_total": 0, "snapshots_discarded": 2,
                                             "snapshots_verified": 2, "snapshots_unverified_total": 0}], "worker_heartbeat": [True]})
        report = sweeps.run_sweeps(api, ["room_asset_sweep"])
        self.assertEqual(report["room_asset_sweep"]["state"], "ok")
        self.assertEqual(report["room_asset_sweep"]["result"]["snapshots_discarded"], 2)
        self.assertEqual(report["room_asset_sweep"]["result"]["snapshots_unverified_total"], 0)
        self.assertEqual(api.calls[0], ("room_asset_sweep", {}))
        self.assertIn("room_asset_sweep", sweeps.SweepAPI.PERMITTED)

    def test_configuration_report_sends_presence_booleans_only(self):
        env = {"SDI_BACKEND_URL": "https://backend.example.test", "SDI_SERVICE_KEY": "service-secret-value",
               "SDI_YOUTUBE_CLIENT_FILE": "/run/secrets/yt", "SDI_MAIL_SENDER_DOMAIN": ""}
        presence = sweeps.configuration_presence(env)
        self.assertEqual(presence, {"sdi_backend_url": True, "sdi_service_key": True, "sdi_youtube_client_file": True,
                                    "sdi_youtube_token_file": False, "sdi_stripe_webhook_secret_file": False,
                                    "sdi_mail_sender_domain": False, "sdi_mail_credentials_file": False})
        api = FakeAPI({"worker_configuration": [True, False, RuntimeError("Job service response unavailable")]})
        self.assertEqual(sweeps.report_configuration(api, env), {"state": "ok"})
        self.assertEqual(api.calls[-1], ("worker_configuration", {"worker": "service-sweeps", "settings": presence}))
        self.assertNotIn("service-secret-value", json.dumps(api.calls))
        self.assertEqual(sweeps.report_configuration(api, env), {"state": "refused"})
        self.assertEqual(sweeps.report_configuration(api, env), {"state": "failed", "error": "RuntimeError"})

    def test_main_refuses_to_run_without_configuration(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(sweeps.main(["--all"], environment={}), 2)
            self.assertEqual(sweeps.main(["--list", "--all"], environment={}), 0)
            api = FakeAPI({"billing_reconcile": [{"expired_now": 0}], "worker_heartbeat": [True], "worker_configuration": [True],
                           "ops_report": [{"status": "recorded", "id": "x"}]})
            self.assertEqual(sweeps.main(["--only", "billing_reconcile"], environment={}, api_factory=lambda: api), 0)
            self.assertEqual(api.calls[-1], ("ops_report", {"kind": "retention_sweep", "outcome": "succeeded", "label": "",
                                                            "metrics": {"sweeps_run": 1, "sweeps_failed": 0}}))
        self.assertIn("not configured", err.getvalue())
        self.assertIn("billing_reconcile", out.getvalue())
        self.assertEqual(sweeps.SweepAPI.PREFIX, "sdi_")
        self.assertTrue(set(sweeps.SWEEPS.values()) <= sweeps.SweepAPI.PERMITTED)


    def test_draft_preview_expiry_is_scheduled_locally(self):
        self.assertIn("draft_preview_expire", sweeps.LOCAL_SWEEPS)
        api = FakeAPI({"worker_heartbeat": [True, True]})
        report = sweeps.run_sweeps(api, ["draft_preview_expire"], environment={})
        self.assertEqual(report["draft_preview_expire"], {"state": "skipped", "reason": "not configured"})
        base = Path(tempfile.mkdtemp())
        root = base / "intake"; root.mkdir(mode=0o700)
        key = base / "signing.key"; key.write_bytes(b"s" * 32); os.chmod(key, 0o600)
        env = {"SDI_DRAFT_PREVIEW_OWNER_ID": str(uuid.uuid4()), "SDI_INTAKE_ORIGIN": "https://intake.example.test",
               "SDI_PREVIEW_SIGNING_KEY_FILE": str(key), "SDI_INTAKE_DIRECTORY": str(root), "SDI_INTAKE_TOTAL_BYTES": str(1 << 20)}
        upload = str(uuid.uuid4())
        (root / (upload + ".mp4")).write_bytes(b"x")
        (root / (upload + ".draft.json")).write_text(json.dumps({"schema": "sdi_spatter_draft_preview", "upload": upload, "expires": 1, "byte_count": 1}))
        report = sweeps.run_sweeps(api, ["draft_preview_expire"], environment=env)
        self.assertEqual(report["draft_preview_expire"], {"state": "ok", "iterations": 1, "result": {"removed": 1, "retained_bytes": 0}})
        self.assertFalse((root / (upload + ".mp4")).exists())
        self.assertEqual([c[0] for c in api.calls], ["worker_heartbeat", "worker_heartbeat"], "no RPC for a local sweep")

    def test_room_asset_sweep_is_scheduled_and_service_only(self):
        self.assertEqual(sweeps.SWEEPS["room_asset_sweep"], "room_asset_sweep")
        self.assertIn("room_asset_sweep", sweeps.SweepAPI.PERMITTED)
        api = FakeAPI({"room_asset_sweep": [{"discarded": 2, "verified": 2, "unverified_total": 0}], "worker_heartbeat": [True]})
        report = sweeps.run_sweeps(api, ["room_asset_sweep"])
        self.assertEqual(report["room_asset_sweep"], {"state": "ok", "iterations": 1,
                                                      "result": {"discarded": 2, "verified": 2, "unverified_total": 0}})
        self.assertEqual(api.calls[0], ("room_asset_sweep", {}))

    def test_run_outcome_is_reported_as_counts_only(self):
        api = FakeAPI({"ops_report": [{"status": "recorded", "id": "x"}, {"error": "Metrics are named whole numbers only."},
                                      RuntimeError("Job service response unavailable; secret=abc")]})
        report = {"a": {"state": "ok"}, "b": {"state": "failed", "error": "RuntimeError"}, "c": {"state": "skipped"},
                  "_heartbeat": {"state": "ok"}}
        self.assertEqual(sweeps.report_outcome(api, report), {"state": "recorded"})
        self.assertEqual(api.calls[-1][1], {"kind": "retention_sweep", "outcome": "failed", "label": "",
                                            "metrics": {"sweeps_run": 2, "sweeps_failed": 1}})
        self.assertEqual(sweeps.report_outcome(api, report)["state"], "refused")
        self.assertEqual(sweeps.report_outcome(api, report), {"state": "failed", "error": "RuntimeError"})
        self.assertEqual(sweeps.report_outcome(api, {"x": {"state": "skipped"}})["state"], "skipped")
        self.assertEqual(len(api.calls), 3)

    def test_failed_ops_report_does_not_fail_the_run(self):
        out = io.StringIO()
        api = FakeAPI({"support_retention": [{"deleted": 0}], "worker_heartbeat": [True], "worker_configuration": [True],
                       "ops_report": [RuntimeError("Job service response unavailable")]})
        with contextlib.redirect_stdout(out):
            self.assertEqual(sweeps.main(["--only", "support_retention"], environment={}, api_factory=lambda: api), 0)
        self.assertEqual(json.loads(out.getvalue())["_ops_report"], {"state": "failed", "error": "RuntimeError"})


class OpsReportCommandTests(unittest.TestCase):
    def test_metrics_are_named_whole_numbers(self):
        self.assertEqual(ops_report.parse_metrics(["bytes=12", "duration_seconds=3"]), {"bytes": 12, "duration_seconds": 3})
        for bad in (["Bytes=1"], ["bytes=-1"], ["bytes=1.5"], ["host=db.internal"], ["bytes"]):
            with self.assertRaises(ValueError):
                ops_report.parse_metrics(bad)

    def test_unconfigured_report_is_skipped_with_a_message(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(ops_report.main(["backup", "succeeded"], environment={}), ops_report.NOT_CONFIGURED)
            self.assertEqual(ops_report.main(["backup", "succeeded"], environment={"SDI_BACKEND_URL": "http://insecure.test",
                                                                                    "SDI_SERVICE_KEY": "k"}), ops_report.NOT_CONFIGURED)
        self.assertIn("not configured", err.getvalue())

    def test_report_is_sent_and_refusals_fail_the_command(self):
        out = io.StringIO()
        api = FakeAPI({"ops_report": [{"status": "recorded", "id": "x"}, {"error": "Labels are a version number or a commit hash only."}]})
        with contextlib.redirect_stdout(out):
            self.assertEqual(ops_report.main(["restore_drill", "succeeded", "--label", "3f2a9c1", "--metric", "tables=40"],
                                             environment={}, api_factory=lambda: api), 0)
            self.assertEqual(ops_report.main(["release", "failed", "--label", "not a version"], environment={}, api_factory=lambda: api), 1)
        self.assertEqual(api.calls[0], ("ops_report", {"kind": "restore_drill", "outcome": "succeeded", "label": "3f2a9c1",
                                                       "metrics": {"tables": 40}}))
        self.assertEqual(ops_report.OpsReportAPI.PREFIX, "sdi_")
        self.assertEqual(ops_report.OpsReportAPI.PERMITTED, frozenset({"ops_report"}))


class PushWorkerTests(unittest.TestCase):
    def test_batch_is_sent_through_the_transport_and_results_reported(self):
        deliveries = [{"delivery": "d1", "platform": "ios", "environment": "sandbox", "token": "a" * 40, "title": "T", "body": "B"},
                      {"delivery": "d2", "platform": "android", "environment": "production", "token": "b" * 40, "title": "T", "body": "B"}]
        api = FakeAPI({"claim": [{"announcement": "ann", "deliveries": deliveries, "complete": False}], "finish": [{"sent": 1, "failed": 1}]})
        sink = SinkTransport(failures={"b" * 40: "Unregistered"})
        result = PushBatchWorker(api, sink, batch=100).run_once()
        self.assertEqual(result, {"state": "batch", "announcement": "ann", "attempted": 2, "sent": 1, "failed": 1})
        self.assertEqual(api.calls[0], ("claim", {"batch": 100}))
        self.assertEqual(api.calls[1][1]["results"], [{"delivery": "d1", "ok": True, "reason": ""}, {"delivery": "d2", "ok": False, "reason": "Unregistered"}])
        self.assertEqual(len(sink.sent), 2)
        self.assertNotIn("a" * 40, json.dumps(sink.sent))     # the sink keeps a suffix only

    def test_idle_and_complete(self):
        self.assertEqual(PushBatchWorker(FakeAPI({"claim": [{"empty": True}]}), SinkTransport()).run_once(), {"state": "idle"})
        api = FakeAPI({"claim": [{"announcement": "ann", "deliveries": [], "complete": True}]})
        self.assertEqual(PushBatchWorker(api, SinkTransport()).run_once()["state"], "complete")
        self.assertEqual(AnnouncementAPI.PREFIX, "sdi_announcement_")
        with self.assertRaises(ValueError):
            PushBatchWorker(api, SinkTransport(), batch=0)


if __name__ == "__main__":
    unittest.main()


class PostPublicationCleanupTests(unittest.TestCase):
    """#190: the staging copy goes only after the database fences a verified release."""

    def setUp(self):
        from backend.ingestion.store import UploadStore
        self.root = Path(tempfile.mkdtemp())
        os.chmod(self.root, 0o700)
        self.store = UploadStore(self.root, total_quota=64 * 1024 * 1024, account_quota=32 * 1024 * 1024, lifetime=3600)
        self.actor = str(uuid.uuid4())
        self.review = str(uuid.uuid4())

    def submitted(self, review=None):
        payload = os.urandom(2048)
        digest = hashlib.sha256(payload).hexdigest()
        meta = {"size": len(payload), "sha256": digest, "title": "Clip", "source_revision": "rev1",
                "destinations": ["feed"], "rights_summary": "Own work", "consent_version": "terms-v1", "made_for_kids": False}
        upload = self.store.begin(self.actor, str(uuid.uuid4()), meta)["id"]
        self.store.append(self.actor, upload, 0, payload, digest)
        self.store.complete(self.actor, upload, validate_media=lambda p: None,
                            register_review=lambda *a: review or self.review)
        return upload

    def state(self, upload):
        return self.store.status(self.actor, upload)["state"]

    def test_release_unlinks_only_after_database_fence(self):
        from backend.publishing.cleanup import release_published
        upload = self.submitted()
        api = FakeAPI({"publication_release_candidates": [[{"upload": upload, "review": self.review}]],
                       "release_published_upload": [True]})
        report = release_published(api, self.store, limit=5)
        self.assertEqual(report["released"], 1)
        self.assertEqual(api.ops(), ["publication_release_candidates", "release_published_upload"])
        self.assertEqual(api.calls[1][1], {"upload": upload, "review": self.review})
        self.assertFalse((self.root / (upload + ".mp4")).exists())
        self.assertEqual(self.state(upload), "expired")
        # A repeated candidate (crash recovery window) is a no-op, not a second RPC.
        again = FakeAPI({"publication_release_candidates": [[{"upload": upload, "review": self.review}]]})
        self.assertEqual(release_published(again, self.store)["already_released"], 1)

    def test_refusal_error_or_mismatch_keeps_the_file(self):
        from backend.publishing.cleanup import release_published
        refused = self.submitted()
        failing = self.submitted(review=str(uuid.uuid4()))
        mismatched = self.submitted(review=str(uuid.uuid4()))
        api = FakeAPI({"publication_release_candidates": [[
                           {"upload": refused, "review": self.review},
                           {"upload": failing, "review": self.store.status(self.actor, failing)["review_id"]},
                           {"upload": mismatched, "review": str(uuid.uuid4())},
                           {"upload": "not-a-uuid", "review": self.review}]],
                       "release_published_upload": [False, RuntimeError("unavailable")]})
        report = release_published(api, self.store)
        self.assertEqual((report["released"], report["kept"], report["failed"]), (0, 2, 1))
        for upload in (refused, failing, mismatched):
            self.assertTrue((self.root / (upload + ".mp4")).exists())
            self.assertEqual(self.state(upload), "submitted")
        # The mismatched review never reached the release RPC.
        self.assertEqual(api.ops().count("release_published_upload"), 2)

    def test_candidate_service_failure_removes_nothing(self):
        from backend.publishing.cleanup import release_published
        upload = self.submitted()
        report = release_published(FakeAPI({"publication_release_candidates": [RuntimeError("down")]}), self.store)
        self.assertEqual(report["failed"], 1)
        self.assertTrue((self.root / (upload + ".mp4")).exists())

    def test_unsubmitted_upload_is_never_released(self):
        from backend.publishing.cleanup import release_published
        meta = {"size": 10, "sha256": "0" * 64, "title": "Clip", "source_revision": "rev1",
                "destinations": ["feed"], "rights_summary": "Own work", "consent_version": "terms-v1", "made_for_kids": False}
        upload = self.store.begin(self.actor, str(uuid.uuid4()), meta)["id"]
        api = FakeAPI({"publication_release_candidates": [[{"upload": upload, "review": self.review}]]})
        self.assertEqual(release_published(api, self.store)["kept"], 1)
        self.assertEqual(api.ops(), ["publication_release_candidates"])

    def test_command_requires_execute_and_hides_errors(self):
        from backend.publishing import cleanup
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                cleanup.main([])
        err = io.StringIO()

        def broken():
            raise ValueError("https://backend.example.test secret path")
        with contextlib.redirect_stderr(err):
            self.assertEqual(cleanup.main(["--execute"], factory=broken), 1)
        self.assertNotIn("secret", err.getvalue())
        out = io.StringIO()
        api = FakeAPI({"publication_release_candidates": [[]]})
        with contextlib.redirect_stdout(out):
            self.assertEqual(cleanup.main(["--execute", "--limit", "3"], factory=lambda: (api, self.store)), 0)
        self.assertEqual(json.loads(out.getvalue())["released"], 0)
        self.assertEqual(api.calls[0][1], {"lim": 3})

    def test_release_api_is_narrow(self):
        from backend.publishing.cleanup import ReleaseAPI
        api = ReleaseAPI("https://backend.example.test", "service-key")
        with self.assertRaises(ValueError):
            api.call("retire_upload")

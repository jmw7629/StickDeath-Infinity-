"""Offline tests for backend/publishing with scripted fake transports. No network.

Run from the repository root:  python3 -m unittest discover -s backend/tests -t .
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import uuid
import urllib.error

from backend.publishing.owner_oauth import OwnerAuthorizationRequired, OwnerGrant, OwnerTokenProvider
from backend.publishing.feed_publisher import FeedPublisher
from backend.publishing.worker import MAX_CONCURRENCY, JobAPI, PublishingWorker
from backend.publishing.youtube_upload import ReconciliationRequired, UploadError, YouTubeUploader, google_url
from backend.publishing.youtube_withdraw import withdraw

CHANNEL = "UCownerchannel"
VIDEO = "abcDEF12345"


class FakeTransport:
    """Answers provider calls from a script of (code, headers, body) triples."""
    def __init__(self, script):
        self.script = list(script)
        self.calls = []
    def __call__(self, method, url, headers, body):
        self.calls.append((method, url, dict(headers), body))
        if not self.script:
            raise AssertionError("unexpected provider call: %s %s" % (method, url))
        return self.script.pop(0)


def channels():
    return (200, {}, json.dumps({"items": [{"id": CHANNEL}]}).encode())


def video(privacy="private", processing="succeeded", upload_status="processed", channel=CHANNEL, embeddable=True):
    return (200, {}, json.dumps({"items": [{"id": VIDEO, "snippet": {"channelId": channel},
             "status": {"privacyStatus": privacy, "uploadStatus": upload_status, "selfDeclaredMadeForKids": False, "embeddable": embeddable},
             "processingDetails": {"processingStatus": processing}}]}).encode())


class UploaderFixture(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        os.chmod(self.root, 0o700)
        self.source_dir = Path(tempfile.mkdtemp())
        self.source = self.source_dir / "render.mp4"
        self.payload = b"m" * (5 * 1024 * 1024 + 17)   # two upload chunks
        self.source.write_bytes(self.payload)
        self.digest = hashlib.sha256(self.payload).hexdigest()
        self.job = str(uuid.uuid4())
        self.renewals = []
        self.allowed = [True]

    def uploader(self, transport):
        def renew():
            self.renewals.append(True)
            return self.allowed[0]
        return YouTubeUploader(self.root, lambda: "token-value", renew, CHANNEL, transport=transport)


class UploadTests(UploaderFixture):
    def test_resumable_upload_is_private_and_checkpointed(self):
        session = "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=s1"
        transport = FakeTransport([
            channels(),
            (200, {"location": session}, b""),
            (308, {}, b""),                                             # probe: nothing stored yet
            (308, {"range": "bytes=0-%d" % (YouTubeUploader.CHUNK - 1)}, b""),
            (200, {}, json.dumps({"id": VIDEO}).encode()),
        ])
        result = self.uploader(transport).upload(self.job, self.source, self.digest, "Title", "Desc", False)
        self.assertEqual(result["video_id"], VIDEO)
        self.assertEqual(result["visibility"], "private")
        self.assertFalse(result["processing_verified"])
        initiation = json.loads(transport.calls[1][3])
        self.assertEqual(initiation["status"]["privacyStatus"], "private")
        self.assertEqual(transport.calls[1][2]["X-Upload-Content-Length"], str(len(self.payload)))
        self.assertEqual(transport.calls[3][2]["Content-Range"], "bytes 0-%d/%d" % (YouTubeUploader.CHUNK - 1, len(self.payload)))
        self.assertTrue(all(call[2]["Authorization"] == "Bearer token-value" for call in transport.calls))
        self.assertGreaterEqual(len(self.renewals), len(transport.calls))
        state = json.loads((self.root / (self.job + ".json")).read_text())
        self.assertEqual(state["result"]["video_id"], VIDEO)
        self.assertTrue(self.source.exists(), "original is never deleted")
        # Replaying the job returns the checkpoint without touching the provider.
        self.assertEqual(self.uploader(FakeTransport([])).upload(self.job, self.source, self.digest, "Title", "Desc", False)["video_id"], VIDEO)

    def test_upload_refuses_changed_bytes_metadata_and_channel(self):
        with self.assertRaises(UploadError):
            self.uploader(FakeTransport([channels()])).upload(self.job, self.source, "0" * 64, "Title", "Desc", False)
        self.assertFalse((self.root / (self.job + ".json")).exists())
        wrong_channel = (200, {}, json.dumps({"items": [{"id": "UCsomeoneelse"}]}).encode())
        with self.assertRaises(UploadError):
            self.uploader(FakeTransport([wrong_channel])).upload(self.job, self.source, self.digest, "Title", "Desc", False)
        with self.assertRaises(UploadError):
            self.uploader(FakeTransport([])).upload(self.job, self.source, self.digest, "", "Desc", False)
        with self.assertRaises(UploadError):
            self.uploader(FakeTransport([])).upload("not-a-job", self.source, self.digest, "Title", "Desc", False)

    def test_lost_approval_stops_transfer(self):
        self.allowed[0] = False
        with self.assertRaises(UploadError):
            self.uploader(FakeTransport([channels()])).upload(self.job, self.source, self.digest, "Title", "Desc", False)

    def test_uncertain_initiation_requires_reconciliation_not_retry(self):
        transport = FakeTransport([channels(), (500, {}, b"")])
        with self.assertRaises(ReconciliationRequired):
            self.uploader(transport).upload(self.job, self.source, self.digest, "Title", "Desc", False)
        state = json.loads((self.root / (self.job + ".json")).read_text())
        self.assertTrue(state["initializing"])
        with self.assertRaises(ReconciliationRequired):
            self.uploader(FakeTransport([channels()])).upload(self.job, self.source, self.digest, "Title", "Desc", False)

    def test_provider_endpoint_allowlist(self):
        for url in ("http://www.googleapis.com/youtube/v3/videos", "https://evil.example/youtube/v3/videos",
                    "https://www.googleapis.com/other", "https://user@www.googleapis.com/youtube/v3/videos"):
            with self.assertRaises(UploadError):
                google_url(url)
        self.assertEqual(google_url("https://www.googleapis.com/youtube/v3/videos?part=id"), "https://www.googleapis.com/youtube/v3/videos?part=id")


class ReleaseTests(UploaderFixture):
    def seed_private_upload(self):
        checkpoint = {"digest": self.digest, "channel": CHANNEL, "metadata_digest": "x",
                      "result": {"video_id": VIDEO, "url": "https://www.youtube.com/watch?v=" + VIDEO, "visibility": "private",
                                 "processing_verified": False, "digest": self.digest}}
        (self.root / (self.job + ".json")).write_text(json.dumps(checkpoint))

    def test_processing_pending_then_publish_verified(self):
        self.seed_private_upload()
        pending = self.uploader(FakeTransport([video(processing="processing", upload_status="uploaded")])).finish_processing_and_publish(self.job, self.digest)
        self.assertEqual(pending["state"], "processing")
        transport = FakeTransport([video(), (200, {}, b"{}"), video(privacy="public")])
        receipt = self.uploader(transport).finish_processing_and_publish(self.job, self.digest)
        self.assertEqual(receipt["state"], "published")
        self.assertEqual(receipt["url"], "https://www.youtube.com/watch?v=" + VIDEO)
        self.assertTrue(receipt["processing_verified"])
        update = json.loads(transport.calls[1][3])
        self.assertEqual(update["status"]["privacyStatus"], "public")
        self.assertEqual(update["status"]["selfDeclaredMadeForKids"], False)

    def test_release_requires_confirmation_and_ownership(self):
        self.seed_private_upload()
        # Public before this job ever recorded a release intent: never claim it.
        with self.assertRaises(ReconciliationRequired):
            self.uploader(FakeTransport([video(privacy="public")])).finish_processing_and_publish(self.job, self.digest)
        with self.assertRaises(UploadError):
            self.uploader(FakeTransport([video(channel="UCother")])).finish_processing_and_publish(self.job, self.digest)
        with self.assertRaises(UploadError):
            self.uploader(FakeTransport([video(processing="failed")])).finish_processing_and_publish(self.job, self.digest)
        with self.assertRaises(ReconciliationRequired):
            self.uploader(FakeTransport([video(), (200, {}, b"{}"), video(privacy="private")])).finish_processing_and_publish(self.job, self.digest)
        # After a recorded release intent an uncertain update is reconciled by reading provider state.
        self.assertEqual(self.uploader(FakeTransport([video(privacy="public"), video(privacy="public")])).finish_processing_and_publish(self.job, self.digest)["state"], "published")
        with self.assertRaises(UploadError):
            self.uploader(FakeTransport([])).finish_processing_and_publish(self.job, "1" * 64)

    def test_withdraw_returns_video_to_private_and_verifies(self):
        self.seed_private_upload()
        transport = FakeTransport([video(privacy="public"), (200, {}, b"{}"), video(privacy="private")])
        receipt = withdraw(self.uploader(transport), self.job, self.digest, VIDEO)
        self.assertEqual(receipt["state"], "private")
        self.assertNotIn("publishAt", json.loads(transport.calls[1][3])["status"])
        self.assertEqual(withdraw(self.uploader(FakeTransport([video(privacy="private"), video(privacy="private")])), self.job, self.digest, VIDEO)["state"], "private")
        with self.assertRaises(ReconciliationRequired):
            withdraw(self.uploader(FakeTransport([video(privacy="public"), (200, {}, b"{}"), video(privacy="public")])), self.job, self.digest, VIDEO)
        with self.assertRaises(ReconciliationRequired):
            withdraw(self.uploader(FakeTransport([])), self.job, self.digest, "otherVideo1")


class OwnerTokenTests(unittest.TestCase):
    def grant(self, revision="r1", enabled=True):
        return OwnerGrant(revision, CHANNEL, "client", "secret", "refresh", enabled)

    def test_refresh_caches_until_expiry_and_hides_secrets(self):
        clock = [100.0]
        calls = []
        def transport(fields):
            calls.append(fields)
            return 200, json.dumps({"access_token": "acc-1", "token_type": "Bearer", "expires_in": 3600}).encode()
        grants = [self.grant()]
        provider = OwnerTokenProvider(lambda: grants[0], lambda rev, state: None, CHANNEL, transport=transport, clock=lambda: clock[0])
        self.assertEqual(provider(), "acc-1")
        self.assertEqual(provider(), "acc-1")
        self.assertEqual(len(calls), 1)
        self.assertNotIn("secret", repr(grants[0]))
        clock[0] += 3600
        provider()
        self.assertEqual(len(calls), 2)

    def test_invalid_grant_requires_reconnect_and_records_state(self):
        states = []
        def transport(fields):
            return 400, json.dumps({"error": "invalid_grant"}).encode()
        provider = OwnerTokenProvider(lambda: self.grant(), lambda rev, state: states.append((rev, state)), CHANNEL, transport=transport, clock=lambda: 0.0)
        with self.assertRaises(OwnerAuthorizationRequired):
            provider()
        self.assertEqual(states, [("r1", "reconnect_required")])
        with self.assertRaises(OwnerAuthorizationRequired):
            provider()

    def test_disabled_or_mismatched_grant_is_refused_without_requests(self):
        def transport(fields):
            raise AssertionError("no refresh expected")
        for grant in (self.grant(enabled=False), OwnerGrant("r1", "UCother", "c", "s", "r")):
            provider = OwnerTokenProvider(lambda g=grant: g, lambda rev, state: None, CHANNEL, transport=transport)
            with self.assertRaises(OwnerAuthorizationRequired):
                provider()


class ScriptedJobAPI(JobAPI):
    def __init__(self, answers):
        super().__init__("https://backend.example.test", "service-key")
        self.answers = dict(answers)
        self.calls = []
    def call(self, operation, **payload):
        self.calls.append((operation, payload))
        answer = self.answers[operation]
        return answer(payload) if callable(answer) else answer


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.artifacts = Path(tempfile.mkdtemp())
        self.checkpoints = Path(tempfile.mkdtemp()) / "state"
        self.payload = b"w" * 4096
        self.digest = hashlib.sha256(self.payload).hexdigest()
        (self.artifacts / "render.mp4").write_bytes(self.payload)

    def test_job_api_only_accepts_https_and_known_operations(self):
        with self.assertRaises(ValueError):
            JobAPI("http://backend.example.test", "key")
        with self.assertRaises(ValueError):
            JobAPI("https://backend.example.test", "")
        api = JobAPI("https://backend.example.test", "key")
        with self.assertRaises(ValueError):
            api.call("drop_everything")

    def test_idle_when_nothing_is_claimable(self):
        api = ScriptedJobAPI({"removal_claim": {"empty": True}, "claim": {"empty": True}})
        worker = PublishingWorker(api, self.artifacts, self.checkpoints, lambda: "token", CHANNEL)
        self.assertEqual(worker.run_once(), {"state": "idle"})

    def test_concurrency_cap_reports_busy_without_claiming(self):
        api = ScriptedJobAPI({"removal_claim": {"empty": True}, "claim": {"empty": True}})
        worker = PublishingWorker(api, self.artifacts, self.checkpoints, lambda: "token", CHANNEL)
        self.assertEqual(worker.run_once(), {"state": "idle"})
        calls = len(api.calls)
        with (self.checkpoints / "worker.lock").open("a") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(worker.run_once(), {"state": "busy"})
            self.assertEqual(len(api.calls), calls)   # nothing was claimed
            second = PublishingWorker(api, self.artifacts, self.checkpoints, lambda: "token", CHANNEL, max_concurrent=2)
            self.assertEqual(second.run_once(), {"state": "idle"})
            with (self.checkpoints / "worker-1.lock").open("a") as other:
                fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(second.run_once(), {"state": "busy"})
        self.assertEqual(worker.run_once(), {"state": "idle"})
        for bad in (0, MAX_CONCURRENCY + 1, True, "2"):
            with self.assertRaises(ValueError):
                PublishingWorker(api, self.artifacts, self.checkpoints, lambda: "token", CHANNEL, max_concurrent=bad)

    def test_burst_of_executors_never_exceeds_the_slot_cap(self):
        # #263 burst fixture: eight executors start together against two slots. While
        # the first claims are in flight the rest must report busy without any RPC.
        import threading
        import time
        inflight = {"now": 0, "peak": 0}
        guard = threading.Lock()
        def slow_removal_claim(payload):
            with guard:
                inflight["now"] += 1
                inflight["peak"] = max(inflight["peak"], inflight["now"])
            time.sleep(0.4)
            with guard:
                inflight["now"] -= 1
            return {"empty": True}
        api = ScriptedJobAPI({"removal_claim": slow_removal_claim, "claim": {"empty": True}})
        start = threading.Barrier(8)
        results = []
        def executor():
            worker = PublishingWorker(api, self.artifacts, self.checkpoints, lambda: "token", CHANNEL, max_concurrent=2)
            start.wait()
            results.append(worker.run_once()["state"])
        self.checkpoints.mkdir(mode=0o700, parents=True)
        threads = [threading.Thread(target=executor) for _ in range(8)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(10)
        self.assertEqual(len(results), 8)
        self.assertLessEqual(inflight["peak"], 2)
        self.assertEqual(results.count("idle") + results.count("busy"), 8)
        self.assertGreaterEqual(results.count("busy"), 6 - 2)   # tolerate a late starter taking a freed slot
        claims = sum(1 for op, _ in api.calls if op == "removal_claim")
        self.assertEqual(claims, results.count("idle"))   # a busy executor made no call at all

    def test_unsupported_destination_fails_the_job_without_provider_calls(self):
        job = str(uuid.uuid4()); lease = str(uuid.uuid4())
        api = ScriptedJobAPI({"removal_claim": {"empty": True}, "renew": True, "finish": True,
                              "claim": {"job": job, "lease": lease, "destination": "feed", "phase": "upload", "digest": self.digest,
                                        "object_key": "render.mp4", "byte_count": len(self.payload), "title": "T", "description": "", "made_for_kids": False}})
        worker = PublishingWorker(api, self.artifacts, self.checkpoints, lambda: "token", CHANNEL)
        self.assertEqual(worker.run_once()["state"], "failed")
        finish = [payload for op, payload in api.calls if op == "finish"][0]
        self.assertIsNone(finish["provider"])
        self.assertIn("Refresh status", finish["failure"])

    def test_owner_authorization_failure_is_reported_not_retried_blindly(self):
        job = str(uuid.uuid4()); lease = str(uuid.uuid4())
        def token():
            raise OwnerAuthorizationRequired("Owner must reconnect YouTube.")
        api = ScriptedJobAPI({"removal_claim": {"empty": True}, "renew": True, "finish": True,
                              "claim": {"job": job, "lease": lease, "destination": "youtube", "phase": "upload", "digest": self.digest,
                                        "object_key": "render.mp4", "byte_count": len(self.payload), "title": "T", "description": "", "made_for_kids": False}})
        worker = PublishingWorker(api, self.artifacts, self.checkpoints, token, CHANNEL)
        self.assertEqual(worker.run_once()["state"], "authorization_unavailable")
        finish = [payload for op, payload in api.calls if op == "finish"][0]
        self.assertIn("Channel authorization unavailable", finish["failure"])

    def test_artifact_outside_storage_or_wrong_size_is_rejected(self):
        job = str(uuid.uuid4()); lease = str(uuid.uuid4())
        claim = {"job": job, "lease": lease, "destination": "youtube", "phase": "upload", "digest": self.digest,
                 "object_key": "render.mp4", "byte_count": len(self.payload) + 1, "title": "T", "description": "", "made_for_kids": False}
        api = ScriptedJobAPI({"removal_claim": {"empty": True}, "renew": True, "finish": True, "claim": claim})
        worker = PublishingWorker(api, self.artifacts, self.checkpoints, lambda: "token", CHANNEL)
        self.assertEqual(worker.run_once()["state"], "failed")


class YouTubeFeedReceiptTests(unittest.TestCase):
    def setUp(self):
        WorkerTests.setUp(self)

    def processing_run(self, final=None, accepted=True):
        job, lease = str(uuid.uuid4()), str(uuid.uuid4())
        self.checkpoints.mkdir(mode=0o700, parents=True, exist_ok=True)
        (self.checkpoints / (job + ".json")).write_text(json.dumps({
            "digest": self.digest, "channel": CHANNEL, "release_intent": True,
            "result": {"video_id": VIDEO, "digest": self.digest, "visibility": "private"}}))
        claim = {"job": job, "lease": lease, "destination": "youtube", "phase": "processing", "digest": self.digest,
                 "object_key": "not-present.mp4", "byte_count": len(self.payload), "title": "T", "description": "", "made_for_kids": False}
        api = ScriptedJobAPI({"removal_claim": {"empty": True}, "claim": claim, "renew": True,
                              "finish_youtube": accepted, "uncertain": True})
        transport = FakeTransport([video(privacy="public"), video(privacy="public"), final or video(privacy="public")])
        worker = PublishingWorker(api, self.artifacts, self.checkpoints, lambda: "token", CHANNEL)
        def uploader(root, access_token, renew, channel):
            return YouTubeUploader(root, access_token, renew, channel, transport=transport)
        with mock.patch("backend.publishing.worker.YouTubeUploader", side_effect=uploader):
            result = worker.run_once()
        return result, api, transport

    def test_processing_worker_records_actual_public_owner_embeddable_receipt_without_reading_a_local_render(self):
        result, api, transport = self.processing_run()
        self.assertEqual(result["state"], "release_recorded")
        receipt = [payload["receipt"] for op, payload in api.calls if op == "finish_youtube"][0]
        self.assertEqual(receipt, {"state": "published", "video_id": VIDEO, "channel_id": CHANNEL, "digest": self.digest,
                                 "url": "https://www.youtube.com/watch?v=" + VIDEO, "visibility": "public",
                                 "processing_verified": True, "embeddable": True})
        self.assertEqual(len(transport.calls), 3)
        self.assertTrue(all(method == "GET" for method, _, _, _ in transport.calls))
        self.assertGreaterEqual(sum(op == "renew" for op, _ in api.calls), 3)
        self.assertFalse(any(op == "finish" for op, _ in api.calls))
        self.assertFalse((self.artifacts / "not-present.mp4").exists())

    def test_final_provider_changes_or_malformed_response_require_reconciliation_without_a_receipt(self):
        for final in [video(privacy="private"), video(channel="UCother"), video(processing="processing"),
                      video(upload_status="rejected"), (200, {}, b"not json"), (503, {}, b"{}")]:
            with self.subTest(final=final):
                result, api, _ = self.processing_run(final=final)
                self.assertEqual(result["state"], "reconcile")
                self.assertFalse(any(op == "finish_youtube" for op, _ in api.calls))
                self.assertTrue(any(op == "uncertain" for op, _ in api.calls))

    def test_nonembeddable_channel_receipt_is_explicitly_false_and_server_rejection_is_not_success(self):
        result, api, _ = self.processing_run(final=video(privacy="public", embeddable=False))
        self.assertEqual(result["state"], "release_recorded")
        self.assertIs([payload["receipt"] for op, payload in api.calls if op == "finish_youtube"][0]["embeddable"], False)
        result, api, _ = self.processing_run(accepted=False)
        self.assertEqual(result["state"], "reconcile")
        self.assertTrue(any(op == "uncertain" for op, _ in api.calls))

    def test_unverified_local_result_cannot_trigger_provider_verification_or_receipt_recording(self):
        worker = PublishingWorker(ScriptedJobAPI({}), self.artifacts, self.checkpoints, lambda: "token", CHANNEL)
        transport = FakeTransport([])
        uploader = YouTubeUploader(self.checkpoints, lambda: "token", lambda: True, CHANNEL, transport=transport)
        valid = {"state": "published", "video_id": VIDEO, "digest": self.digest,
                 "processing_verified": True, "visibility": "public", "url": "https://www.youtube.com/watch?v=" + VIDEO}
        for changed in [{"digest": "0" * 64}, {"processing_verified": False}, {"visibility": "private"},
                        {"url": "https://foreign.example/watch?v=" + VIDEO}, {"video_id": "not-a-video"}]:
            with self.assertRaises(ReconciliationRequired):
                worker._verified_public_receipt(uploader, dict(valid, **changed), self.digest)
        self.assertEqual(transport.calls, [])


class PostPublicationReadBoundaryTests(unittest.TestCase):
    def setUp(self):
        WorkerTests.setUp(self)

    def run_final_read_failure(self, origin, resume=False):
        """Run real uploader/worker methods; fail only the third, post-public read.
        A second run represents explicitly authorized reconciliation of the same
        job/provider ID, not an automatic upload retry.
        """
        job, lease = str(uuid.uuid4()), str(uuid.uuid4())
        self.checkpoints.mkdir(mode=0o700, parents=True)
        checkpoint = self.checkpoints / (job + ".json")
        checkpoint.write_text(json.dumps({"digest": self.digest, "channel": CHANNEL, "release_intent": True,
            "result": {"video_id": VIDEO, "digest": self.digest, "visibility": "private"}}))
        claim = {"job": job, "lease": lease, "destination": "youtube", "phase": "processing", "digest": self.digest,
                 "object_key": "not-present.mp4", "byte_count": len(self.payload), "provider": VIDEO}
        active = [True]
        counts = {"renew": 0, "token": 0}
        provider_calls = []

        def renew(payload):
            counts["renew"] += 1
            if active[0] and counts["renew"] == 3:
                if origin == "lease_loss": return False
                if origin == "lease_read": raise RuntimeError("Scripted lease service unavailable")
            return True

        def token():
            counts["token"] += 1
            if active[0] and counts["token"] == 3:
                if origin == "upload_error": return "invalid token\n"  # actual request() raises UploadError
                if origin == "owner_auth": raise OwnerAuthorizationRequired("Scripted owner reconnection needed")
            return "synthetic-token"

        def transport(method, url, headers, body):
            provider_calls.append((method, url))
            if active[0] and len(provider_calls) == 3:
                errors = {"transport": urllib.error.URLError("Scripted final read unavailable"),
                          "timeout": TimeoutError("Scripted final read timeout"),
                          "socket": OSError("Scripted final read socket failure")}
                if origin in errors: raise errors[origin]
            return video(privacy="public")

        api = ScriptedJobAPI({"removal_claim": {"empty": True}, "claim": lambda payload: dict(claim),
                              "renew": renew, "finish": True, "finish_youtube": True, "uncertain": True})
        worker = PublishingWorker(api, self.artifacts, self.checkpoints, token, CHANNEL)
        def uploader(root, access_token, renew_approval, channel):
            return YouTubeUploader(root, access_token, renew_approval, channel, transport=transport)
        original_open = Path.open
        def reject_render_open(path, *args, **kwargs):
            if path.suffix == ".mp4": raise AssertionError("A public-processing resume must not read a render")
            return original_open(path, *args, **kwargs)
        with mock.patch("backend.publishing.worker.YouTubeUploader", side_effect=uploader), \
             mock.patch.object(YouTubeUploader, "upload", side_effect=AssertionError("No duplicate upload")), \
             mock.patch.object(Path, "open", new=reject_render_open):
            first = worker.run_once()
            first_calls = list(api.calls)
            published = json.loads(checkpoint.read_text())["published"]
            second = None
            if resume:
                active[0] = False
                counts.update(renew=0, token=0)
                claim["lease"] = str(uuid.uuid4())  # new lease from authorized server reconciliation
                second = worker.run_once()
        return first, first_calls, published, second, api.calls, provider_calls

    def test_final_known_public_read_auth_lease_and_transport_failures_only_reconcile(self):
        for origin in ["upload_error", "owner_auth", "lease_loss", "lease_read", "transport", "timeout", "socket"]:
            with self.subTest(origin=origin):
                # Each scenario owns its independent checkpoint/lock directory.
                self.checkpoints = Path(tempfile.mkdtemp()) / "state"
                result, calls, published, _, _, provider_calls = self.run_final_read_failure(origin)
                self.assertEqual(result["state"], "reconcile")
                self.assertEqual([op for op, _ in calls if op in ("uncertain", "finish", "finish_youtube")], ["uncertain"])
                self.assertEqual(published["state"], "published")
                self.assertEqual(published["video_id"], VIDEO)
                self.assertEqual(published["digest"], self.digest)
                self.assertTrue(provider_calls)
                self.assertTrue(all(method == "GET" and url.endswith("id=" + VIDEO) for method, url in provider_calls))

    def test_authorized_resume_after_final_read_failure_retains_provider_id_without_upload_or_render_read(self):
        result, first_calls, published, resumed, calls, provider_calls = self.run_final_read_failure("lease_loss", resume=True)
        self.assertEqual(result["state"], "reconcile")
        self.assertEqual(resumed["state"], "release_recorded")
        self.assertFalse(any(op == "finish" for op, _ in calls))
        self.assertEqual(sum(op == "uncertain" for op, _ in calls), 1)
        receipts = [payload["receipt"] for op, payload in calls if op == "finish_youtube"]
        self.assertEqual(len(receipts), 1)
        self.assertEqual(receipts[0]["video_id"], published["video_id"])
        self.assertEqual(receipts[0]["digest"], self.digest)
        self.assertTrue(all(method == "GET" and url.endswith("id=" + VIDEO) for method, url in provider_calls))


class FeedReferencePublisherTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.job, self.lease = str(uuid.uuid4()), str(uuid.uuid4())
        self.calls = []
        self.host_calls = []
        self.url = "https://www.youtube.com/watch?v=" + VIDEO

    def publisher(self, response):
        parent = self
        class API:
            def call(self, operation, **payload):
                parent.calls.append((operation, payload))
                if operation == "removal_claim": return {"empty": True}
                if operation == "publish_claim":
                    return {"job": parent.job, "lease": parent.lease, "destination": "feed", "playback_provider": "youtube"}
                if operation == "publish_reference": return response
                raise AssertionError("Unexpected operation " + operation)
        class Host:
            def put(self, *args): parent.host_calls.append(("put", args)); raise AssertionError("No reference upload")
            def delete(self, *args): parent.host_calls.append(("delete", args)); raise AssertionError("No provider deletion through host")
        def no_probe(*args): raise AssertionError("No raw artifact probe")
        return FeedPublisher(API(), self.root, Host(), no_probe)

    def test_reference_uses_only_server_transaction_without_artifact_probe_host_or_poster(self):
        result = self.publisher({"state": "published", "url": self.url}).run_once()
        self.assertEqual(result, {"state": "published", "job": self.job, "url": self.url, "playback_provider": "youtube"})
        self.assertEqual(self.calls, [("removal_claim", {}), ("publish_claim", {}),
                                     ("publish_reference", {"job": self.job, "token": self.lease})])
        self.assertEqual(self.host_calls, [])
        self.assertNotIn("duration", result)

    def test_cancel_unavailable_and_rejected_reference_never_report_publication(self):
        for response, expected in [({"state": "cancelled"}, "cancelled"), ({"state": "unavailable"}, "unavailable"),
                                   ({"state": "rejected"}, "reconcile"), (True, "reconcile"),
                                   ({"state": "published", "url": "https://foreign.example/video"}, "reconcile")]:
            with self.subTest(response=response):
                self.assertEqual(self.publisher(response).run_once()["state"], expected)
                self.assertEqual(self.host_calls, [])

    def test_host_deletion_refuses_youtube_and_extracted_media_urls(self):
        publisher = self.publisher({})
        for url in [self.url, "https://youtu.be/" + VIDEO, "https://www.youtube-nocookie.com/embed/" + VIDEO,
                    "https://r1.googlevideo.com/videoplayback", "https://www.youtube.com./watch?v=" + VIDEO,
                    "https://user:password@cdn.example/file.mp4", "http://cdn.example/file.mp4"]:
            self.assertFalse(publisher._delete(url))
        self.assertEqual(self.host_calls, [])

    def test_hosted_url_validation_keeps_existing_raw_https_renditions(self):
        self.assertTrue(FeedPublisher._hosted_url("https://cdn.example/approved.mp4?signature=opaque"))
        self.assertFalse(FeedPublisher._hosted_url(self.url))


if __name__ == "__main__":
    unittest.main()

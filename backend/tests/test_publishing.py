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
import uuid

from backend.publishing.owner_oauth import OwnerAuthorizationRequired, OwnerGrant, OwnerTokenProvider
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


def video(privacy="private", processing="succeeded", upload_status="processed", channel=CHANNEL):
    return (200, {}, json.dumps({"items": [{"id": VIDEO, "snippet": {"channelId": channel},
             "status": {"privacyStatus": privacy, "uploadStatus": upload_status, "selfDeclaredMadeForKids": False},
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


if __name__ == "__main__":
    unittest.main()

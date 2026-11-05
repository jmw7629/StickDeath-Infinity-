"""Offline tests for backend/ingestion: fake transports only, no network, no media tools.

Run from the repository root:  python3 -m unittest discover -s backend/tests -t .
"""
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error
import uuid

from backend.ingestion import assets as assets_module
from backend.ingestion import auth as auth_module
from backend.ingestion.assets import LicensedAssetRegistry
from backend.ingestion import registration as registration_module
from backend.ingestion.auth import AccountAuthorizer
from backend.ingestion.http import UploadApplication
from backend.ingestion.preview import PreviewLinks
from backend.ingestion.registration import ReviewRegistrar
from backend.ingestion.store import IntakeError, UploadStore, CHUNK_BYTES


class FakeResponse:
    def __init__(self, body, code=200):
        self.body, self.code = body, code
    def read(self, limit=None):
        return self.body if limit is None else self.body[:limit]
    def __enter__(self):
        return self
    def __exit__(self, *exc):
        return False


class FakeOpener:
    """Records requests and answers from a script; never touches the network."""
    def __init__(self, script):
        self.script = list(script)
        self.requests = []
    def open(self, request, timeout=None):
        self.requests.append(request)
        answer = self.script.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer


def install_opener(module, opener):
    original = module.urllib.request.build_opener
    module.urllib.request.build_opener = lambda *handlers: opener
    return original


def metadata(size, digest):
    return {"size": size, "sha256": digest, "title": "Clip", "source_revision": "rev1",
            "destinations": ["feed"], "rights_summary": "Own work", "consent_version": "terms-v1", "made_for_kids": False}


class UploadStoreTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        os.chmod(self.root, 0o700)
        self.clock = [1_000_000.0]
        self.store = UploadStore(self.root, total_quota=64 * 1024 * 1024, account_quota=32 * 1024 * 1024,
                                 lifetime=3600, clock=lambda: self.clock[0])
        self.actor = str(uuid.uuid4())
        self.payload = b"render-bytes-" * 1000
        self.digest = hashlib.sha256(self.payload).hexdigest()

    def test_begin_is_idempotent_per_actor_and_key(self):
        key = str(uuid.uuid4())
        first = self.store.begin(self.actor, key, metadata(len(self.payload), self.digest))
        again = self.store.begin(self.actor, key, metadata(len(self.payload), self.digest))
        self.assertEqual(first["id"], again["id"])
        with self.assertRaises(IntakeError) as refused:
            self.store.begin(self.actor, key, metadata(len(self.payload) + 1, self.digest))
        self.assertEqual(refused.exception.status, 409)
        other = self.store.begin(str(uuid.uuid4()), key, metadata(len(self.payload), self.digest))
        self.assertNotEqual(first["id"], other["id"])

    def test_metadata_must_be_complete_and_explicit(self):
        bad = metadata(len(self.payload), self.digest)
        bad["destinations"] = ["feed", "everywhere"]
        with self.assertRaises(IntakeError):
            self.store.begin(self.actor, str(uuid.uuid4()), bad)
        bad = metadata(len(self.payload), self.digest)
        bad["made_for_kids"] = "no"
        with self.assertRaises(IntakeError):
            self.store.begin(self.actor, str(uuid.uuid4()), bad)
        bad = metadata(len(self.payload), self.digest)
        del bad["rights_summary"]
        with self.assertRaises(IntakeError):
            self.store.begin(self.actor, str(uuid.uuid4()), bad)

    def test_content_rules_refuse_metadata_before_any_upload_row(self):
        bad = metadata(len(self.payload), self.digest)
        bad["title"] = "Call 555-123-4567"
        with self.assertRaises(IntakeError) as refused:
            self.store.begin(self.actor, str(uuid.uuid4()), bad)
        self.assertEqual(refused.exception.status, 422)
        self.assertIn("content_rule.personal_data", str(refused.exception))
        self.assertNotIn("555", str(refused.exception))
        ok = metadata(len(self.payload), self.digest)
        ok["rights_summary"] = "Music licensed; licensor contact licensing@example.com"
        self.assertEqual(self.store.begin(self.actor, str(uuid.uuid4()), ok)["state"], "receiving")

    def test_optional_project_digest_is_validated_and_kept(self):
        good = {**metadata(len(self.payload), self.digest), "source_project_digest": "d" * 64}
        upload = self.store.begin(self.actor, str(uuid.uuid4()), good)["id"]
        self.assertEqual(self.store.metadata(self.actor, upload)["source_project_digest"], "d" * 64)
        for bad in ("D" * 64, "d" * 63, 7, None):
            with self.assertRaises(IntakeError):
                self.store.begin(self.actor, str(uuid.uuid4()), {**metadata(len(self.payload), self.digest), "source_project_digest": bad})

    def test_chunks_verify_checksum_offset_and_duplicates(self):
        upload = self.store.begin(self.actor, str(uuid.uuid4()), metadata(len(self.payload), self.digest))["id"]
        half = len(self.payload) // 2
        first, second = self.payload[:half], self.payload[half:]
        with self.assertRaises(IntakeError) as wrong:
            self.store.append(self.actor, upload, 0, first, hashlib.sha256(b"x").hexdigest())
        self.assertEqual(wrong.exception.status, 422)
        state = self.store.append(self.actor, upload, 0, first, hashlib.sha256(first).hexdigest())
        self.assertEqual(state["offset"], half)
        duplicate = self.store.append(self.actor, upload, 0, first, hashlib.sha256(first).hexdigest())
        self.assertEqual(duplicate["offset"], half)
        with self.assertRaises(IntakeError) as conflict:
            self.store.append(self.actor, upload, 0, b"different" + first[9:], hashlib.sha256(b"different" + first[9:]).hexdigest())
        self.assertEqual(conflict.exception.status, 409)
        with self.assertRaises(IntakeError):
            self.store.append(self.actor, upload, half + 1, second, hashlib.sha256(second).hexdigest())
        with self.assertRaises(IntakeError) as foreign:
            self.store.status(str(uuid.uuid4()), upload)
        self.assertEqual(foreign.exception.status, 404)
        self.store.append(self.actor, upload, half, second, hashlib.sha256(second).hexdigest())
        self.assertEqual(self.store.status(self.actor, upload)["offset"], len(self.payload))

    def test_complete_runs_validator_then_idempotent_registration(self):
        upload = self.store.begin(self.actor, str(uuid.uuid4()), metadata(len(self.payload), self.digest))["id"]
        self.store.append(self.actor, upload, 0, self.payload, self.digest)
        validated, registered = [], []
        review = str(uuid.uuid4())
        def validate(path):
            validated.append(Path(path).name)
        def register(upload_id, owner, path, meta, expires):
            registered.append((upload_id, owner, meta["sha256"]))
            return review
        result = self.store.complete(self.actor, upload, validate_media=validate, register_review=register)
        self.assertEqual(result["state"], "submitted")
        self.assertEqual(result["review_id"], review)
        again = self.store.complete(self.actor, upload, validate_media=validate, register_review=register)
        self.assertEqual(again["review_id"], review)
        self.assertEqual(validated, [upload + ".mp4"])
        self.assertEqual(registered, [(upload, self.actor, self.digest)])
        with self.assertRaises(IntakeError) as blocked:
            self.store.cancel(self.actor, upload)
        self.assertEqual(blocked.exception.status, 409)
        self.assertTrue((self.root / (upload + ".mp4")).exists())

    def test_complete_rejects_digest_mismatch_and_incomplete_upload(self):
        wrong = hashlib.sha256(b"other").hexdigest()
        upload = self.store.begin(self.actor, str(uuid.uuid4()), metadata(len(self.payload), wrong))["id"]
        with self.assertRaises(IntakeError) as incomplete:
            self.store.complete(self.actor, upload, validate_media=lambda p: None, register_review=lambda *a: str(uuid.uuid4()))
        self.assertEqual(incomplete.exception.status, 409)
        self.store.append(self.actor, upload, 0, self.payload, self.digest)
        with self.assertRaises(IntakeError) as mismatch:
            self.store.complete(self.actor, upload, validate_media=lambda p: None, register_review=lambda *a: str(uuid.uuid4()))
        self.assertEqual(mismatch.exception.status, 422)

    def test_expiry_keeps_submitted_files_until_release_confirmed(self):
        upload = self.store.begin(self.actor, str(uuid.uuid4()), metadata(len(self.payload), self.digest))["id"]
        self.store.append(self.actor, upload, 0, self.payload, self.digest)
        self.store.complete(self.actor, upload, validate_media=lambda p: None, register_review=lambda *a: str(uuid.uuid4()))
        self.clock[0] += 3601
        self.assertEqual(self.store.expire(lambda u, r: False), 0)
        self.assertTrue((self.root / (upload + ".mp4")).exists())
        self.assertEqual(self.store.expire(lambda u, r: True), 1)
        self.assertFalse((self.root / (upload + ".mp4")).exists())
        self.assertEqual(self.store.status(self.actor, upload)["state"], "expired")

    def test_quotas_bound_concurrent_uploads(self):
        for _ in range(5):
            self.store.begin(self.actor, str(uuid.uuid4()), metadata(1024, self.digest))
        with self.assertRaises(IntakeError) as full:
            self.store.begin(self.actor, str(uuid.uuid4()), metadata(1024, self.digest))
        self.assertEqual(full.exception.status, 429)


class AuthorizerTests(unittest.TestCase):
    def test_authorizer_uses_backend_identity_not_token_claims(self):
        actor = str(uuid.uuid4())
        opener = FakeOpener([FakeResponse(json.dumps({"authorized": True, "actor": actor}).encode())])
        original = install_opener(auth_module, opener)
        try:
            authorizer = AccountAuthorizer("https://backend.example.test", "publishable-key")
            self.assertEqual(authorizer("Bearer header.payload.signature"), actor)
            request = opener.requests[0]
            self.assertEqual(request.full_url, "https://backend.example.test/rest/v1/rpc/sdi_upload_identity")
            self.assertEqual(request.get_header("Authorization"), "Bearer header.payload.signature")
        finally:
            auth_module.urllib.request.build_opener = original

    def test_authorizer_fails_closed(self):
        cases = [
            (FakeResponse(json.dumps({"authorized": False}).encode()), 403),
            (urllib.error.HTTPError("u", 401, "nope", {}, io.BytesIO(b"")), 401),
            (urllib.error.URLError("down"), 503),
            (FakeResponse(b"not json"), 503),
        ]
        for answer, status in cases:
            opener = FakeOpener([answer])
            original = install_opener(auth_module, opener)
            try:
                with self.assertRaises(IntakeError) as refused:
                    AccountAuthorizer("https://backend.example.test", "key")("Bearer abc.def.ghi")
                self.assertEqual(refused.exception.status, status)
            finally:
                auth_module.urllib.request.build_opener = original
        with self.assertRaises(ValueError):
            AccountAuthorizer("http://backend.example.test", "key")


class PreviewLinkTests(unittest.TestCase):
    def test_links_are_signed_bounded_and_expire(self):
        now = [1_700_000_000.0]
        links = PreviewLinks("https://intake.example.test", b"k" * 32, lifetime=300, clock=lambda: now[0])
        upload, owner, digest = str(uuid.uuid4()), str(uuid.uuid4()), "a" * 64
        url, expiry = links(upload, owner, digest)
        token = url.split("/v1/render-previews/")[1]
        self.assertEqual(links.verify(token)[:3], (upload, owner, digest))
        self.assertEqual(int(expiry.timestamp()), 1_700_000_300)
        encoded, signature = token.split(".")
        with self.assertRaises(ValueError):
            links.verify(encoded + "." + ("0" * 64))
        now[0] += 301
        with self.assertRaises(ValueError):
            links.verify(token)
        with self.assertRaises(ValueError):
            PreviewLinks("http://intake.example.test", b"k" * 32)
        with self.assertRaises(ValueError):
            PreviewLinks("https://intake.example.test", b"short")


class RegistrarTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.upload = str(uuid.uuid4())
        self.path = self.root / (self.upload + ".mp4")
        self.path.write_bytes(b"x" * 10)
        self.links = PreviewLinks("https://intake.example.test", b"k" * 32)

    def registrar(self):
        return ReviewRegistrar("https://backend.example.test", "service-key", self.root, "terms-v1", self.links, publishable_key="publishable-key")

    def test_registration_posts_private_preview_and_returns_review(self):
        review = str(uuid.uuid4())
        opener = FakeOpener([FakeResponse(json.dumps({"allowed": True}).encode()), FakeResponse(json.dumps({"review_id": review}).encode())])
        original = install_opener(registration_module, opener)
        try:
            meta = metadata(10, "b" * 64)
            owner = str(uuid.uuid4())
            self.assertEqual(self.registrar()(self.upload, owner, self.path, meta, 1_800_000_000), review)
            consent = json.loads(opener.requests[0].data)
            self.assertEqual(opener.requests[0].full_url, "https://backend.example.test/rest/v1/rpc/sdi_consent_verify")
            self.assertEqual(consent, {"subject": owner, "version": "terms-v1"})
            body = json.loads(opener.requests[1].data)
            self.assertEqual(body["object_key"], self.upload + ".mp4")
            self.assertTrue(body["preview_url"].startswith("https://intake.example.test/v1/render-previews/"))
            self.assertEqual(opener.requests[1].full_url, "https://backend.example.test/rest/v1/rpc/sdi_register_upload")
        finally:
            registration_module.urllib.request.build_opener = original

    def test_registration_binds_the_declared_project_digest_and_fails_closed(self):
        review = str(uuid.uuid4())
        meta = {**metadata(10, "b" * 64), "source_project_digest": "c" * 64}
        opener = FakeOpener([FakeResponse(json.dumps({"allowed": True}).encode()), FakeResponse(json.dumps({"review_id": review}).encode()),
                             FakeResponse(json.dumps({"status": "confirmed", "version": 2, "changed": True}).encode())])
        original = install_opener(registration_module, opener)
        try:
            self.assertEqual(self.registrar()(self.upload, str(uuid.uuid4()), self.path, meta, 1_800_000_000), review)
            self.assertEqual(json.loads(opener.requests[1].data)["metadata"]["source_project_digest"], "c" * 64)
            self.assertEqual(opener.requests[2].full_url, "https://backend.example.test/rest/v1/rpc/sdi_review_bind_source_digest")
            self.assertEqual(json.loads(opener.requests[2].data), {"upload": self.upload, "review": review, "digest": "c" * 64})
        finally:
            registration_module.urllib.request.build_opener = original
        # A refused or unreachable binding is never reported as a submitted review.
        for answer, status in ((FakeResponse(json.dumps({"error": "Source digest does not match the registered upload."}).encode()), 409),
                               (urllib.error.URLError("down"), 503), (FakeResponse(b"garbage"), 503)):
            opener = FakeOpener([FakeResponse(json.dumps({"allowed": True}).encode()), FakeResponse(json.dumps({"review_id": review}).encode()), answer])
            original = install_opener(registration_module, opener)
            try:
                with self.assertRaises(IntakeError) as refusal:
                    self.registrar()(self.upload, str(uuid.uuid4()), self.path, meta, 1_800_000_000)
                self.assertEqual(refusal.exception.status, status)
            finally:
                registration_module.urllib.request.build_opener = original
        # Without a declared digest nothing extra is sent.
        opener = FakeOpener([FakeResponse(json.dumps({"allowed": True}).encode()), FakeResponse(json.dumps({"review_id": review}).encode())])
        original = install_opener(registration_module, opener)
        try:
            self.registrar()(self.upload, str(uuid.uuid4()), self.path, metadata(10, "b" * 64), 1_800_000_000)
            self.assertEqual(len(opener.requests), 2)
        finally:
            registration_module.urllib.request.build_opener = original

    def test_registration_refuses_stale_consent_and_unconfirmed_backend(self):
        with self.assertRaises(IntakeError) as stale:
            self.registrar()(self.upload, str(uuid.uuid4()), self.path, {**metadata(10, "b" * 64), "consent_version": "terms-v0"}, 1_800_000_000)
        self.assertEqual(stale.exception.status, 409)
        for answer in (FakeResponse(json.dumps({"error": "Creator unavailable."}).encode()), urllib.error.URLError("down")):
            opener = FakeOpener([FakeResponse(json.dumps({"allowed": True}).encode()), answer])
            original = install_opener(registration_module, opener)
            try:
                with self.assertRaises(IntakeError):
                    self.registrar()(self.upload, str(uuid.uuid4()), self.path, metadata(10, "b" * 64), 1_800_000_000)
            finally:
                registration_module.urllib.request.build_opener = original

    def test_registration_requires_server_verified_consent(self):
        refused = FakeResponse(json.dumps({"allowed": False, "reason": "Current content policy acceptance and age confirmation required."}).encode())
        for answer, status in ((refused, 409), (FakeResponse(b"garbage"), 503), (urllib.error.URLError("down"), 503), (FakeResponse(b"{}"), 409)):
            opener = FakeOpener([answer])
            original = install_opener(registration_module, opener)
            try:
                with self.assertRaises(IntakeError) as refusal:
                    self.registrar()(self.upload, str(uuid.uuid4()), self.path, metadata(10, "b" * 64), 1_800_000_000)
                self.assertEqual(refusal.exception.status, status)
                self.assertEqual(len(opener.requests), 1, "registration must not be attempted without verified consent")
            finally:
                registration_module.urllib.request.build_opener = original
        self.assertIn("age confirmation", str(IntakeError("Current content policy acceptance and age confirmation required.", 409)))

    def test_artifact_released_fails_closed(self):
        for answer in (FakeResponse(b"false"), FakeResponse(b"garbage"), urllib.error.URLError("down")):
            opener = FakeOpener([answer])
            original = install_opener(registration_module, opener)
            try:
                self.assertFalse(self.registrar().artifact_released(self.upload, None))
            finally:
                registration_module.urllib.request.build_opener = original
        opener = FakeOpener([FakeResponse(b"true")])
        original = install_opener(registration_module, opener)
        try:
            self.assertTrue(self.registrar().artifact_released(self.upload, str(uuid.uuid4())))
        finally:
            registration_module.urllib.request.build_opener = original


class LicensedAssetRegistryTests(unittest.TestCase):
    """The shipped catalogues are the licence authority for declared library assets (#188)."""
    def setUp(self):
        self.registry = LicensedAssetRegistry.from_catalogues()
        images = json.loads((assets_module.DEFAULT_ROOT / "StudioImages" / "catalogue.json").read_text())
        sounds = json.loads((assets_module.DEFAULT_ROOT / "StudioSounds" / "catalogue.json").read_text())
        self.image = images["images"][0]["originalSHA256"]
        self.sound = sounds["sounds"][0]["originalSHA256"]
        self.store = UploadStore(Path(tempfile.mkdtemp()), total_quota=64 * 1024 * 1024, account_quota=32 * 1024 * 1024,
                                 licensed_assets=self.registry)
        self.unchecked = UploadStore(Path(tempfile.mkdtemp()), total_quota=64 * 1024 * 1024, account_quota=32 * 1024 * 1024)

    def test_catalogued_assets_are_admitted_with_their_licence_and_unknown_ones_refused(self):
        checked = self.registry.check([{"kind": "image", "sha256": self.image}, {"kind": "sound", "sha256": self.sound},
                                       {"kind": "image", "sha256": self.image}])
        self.assertEqual([c["kind"] for c in checked], ["image", "sound"], "duplicates collapse, order kept")
        self.assertTrue(all(c["license"] for c in checked))
        unknown = "0" * 64
        with self.assertRaises(IntakeError) as refused:
            self.registry.check([{"kind": "image", "sha256": unknown}])
        self.assertEqual(refused.exception.status, 422)
        with self.assertRaises(IntakeError):
            self.registry.check([{"kind": "sound", "sha256": self.image}])  # right digest, wrong kind
        for malformed in ("not-a-list", [{"kind": "video", "sha256": self.image}], [{"kind": "image"}],
                          [{"kind": "image", "sha256": "ABC"}], [{"kind": "image", "sha256": self.image, "license": "CC0-1.0"}],
                          [{"kind": "image", "sha256": self.image}] * (assets_module.MAX_CREDITS + 1)):
            with self.assertRaises(IntakeError, msg=str(malformed)[:60]):
                self.registry.check(malformed)

    def test_store_requires_a_registry_before_admitting_credits_and_keeps_the_matched_licence(self):
        actor = str(uuid.uuid4()); digest = hashlib.sha256(b"render").hexdigest()
        declared = dict(metadata(4096, digest), asset_credits=[{"kind": "image", "sha256": self.image}])
        with self.assertRaises(IntakeError) as refused:
            self.unchecked.begin(actor, str(uuid.uuid4()), declared)
        self.assertEqual(refused.exception.status, 503, "credits are never admitted unchecked")
        upload = self.store.begin(actor, str(uuid.uuid4()), declared)
        self.assertEqual(upload["state"], "receiving")
        stored = self.store.metadata(actor, upload["id"])
        self.assertEqual(stored["asset_credits"][0]["sha256"], self.image)
        self.assertTrue(stored["asset_credits"][0]["license"])
        with self.assertRaises(IntakeError) as refused:
            self.store.begin(actor, str(uuid.uuid4()), dict(metadata(4096, digest), asset_credits=[{"kind": "sound", "sha256": "f" * 64}]))
        self.assertEqual(refused.exception.status, 422)
        plain = self.store.begin(actor, str(uuid.uuid4()), metadata(4096, digest))
        self.assertEqual(plain["state"], "receiving", "renders without library assets still declare nothing")


class OptionalSoundRegistryTests(unittest.TestCase):
    """Trusted local metadata admits optional credits; client input cannot add rights."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.resources = Path(self.temp.name) / "Resources"
        self.images = self.resources / "StudioImages"
        self.sounds = self.resources / "StudioSounds"
        self.images.mkdir(parents=True); self.sounds.mkdir()
        (self.images / "catalogue.json").write_text(json.dumps({"licenses": [{"id": "cc0", "license": "CC0-1.0"}],
            "images": [{"licenseID": "cc0", "sha256": "1" * 64, "originalSHA256": "1" * 64}]}))
        (self.sounds / "catalogue.json").write_text(json.dumps({"sounds": [
            {"license": "CC0-1.0", "sha256": "2" * 64, "originalSHA256": "2" * 64}]}))
        self.descriptor_file = self.sounds / "sound-packs.json"

    def write_packs(self):
        self.descriptors = []
        for pack_id, digest, original in (("ambience-test-v1", "3" * 64, "4" * 64), ("comedy-test-v1", "5" * 64, "6" * 64)):
            directory = self.sounds / "pack-catalogues" / pack_id
            directory.mkdir(parents=True)
            entry = {"id": digest, "sha256": digest, "originalSHA256": original, "filename": digest + ".wav",
                     "title": "Optional fixture", "category": "Ambience", "author": "Fixture author",
                     "sourceURL": "https://opengameart.org/content/fixture", "license": "CC0-1.0",
                     "licenseURL": "https://creativecommons.org/publicdomain/zero/1.0/", "byteCount": 1024,
                     "duration": 1.0, "sampleRate": 44100, "channels": 1, "waveformPeaks": [0.25] * 256,
                     "waveformRMS": [0.125] * 256, "tags": ["nature"]}
            data = json.dumps({"schemaVersion": 1, "sounds": [entry]}).encode()
            (directory / "catalogue.json").write_bytes(data)
            base = "https://raw.githubusercontent.com/jmw7629/StickDeath-Infinity-/owned-tag/assets/sound-packs/" + pack_id + "/"
            self.descriptors.append({"id": pack_id, "title": "Trusted fixture pack", "manifestURL": base + "catalogue.json",
                                     "baseURL": base, "manifestBytes": len(data), "manifestSHA256": hashlib.sha256(data).hexdigest(),
                                     "soundCount": 1, "totalAudioBytes": 1024})
        self.save_descriptors()

    def save_descriptors(self):
        self.descriptor_file.write_bytes(json.dumps(self.descriptors).encode())

    def pinned(self):
        # Tests replace the code-owned pin only; production has no request/env pin override.
        return mock.patch.object(assets_module, "TRUSTED_SOUND_PACK_DESCRIPTORS_SHA256",
                                 hashlib.sha256(self.descriptor_file.read_bytes()).hexdigest())

    def test_absent_descriptors_preserve_bundled_only_and_custom_environment_roots(self):
        (self.sounds / "pack-catalogues").mkdir()
        (self.sounds / "pack-catalogues" / "untrusted.json").write_text("not a catalogue")
        with mock.patch.dict(os.environ, {"SDI_ASSET_CATALOGUE_ROOT": str(self.resources)}):
            registry = LicensedAssetRegistry.from_catalogues()
        self.assertEqual(registry.images, {"1" * 64: "CC0-1.0"})
        self.assertEqual(registry.sounds, {"2" * 64: "CC0-1.0"})
        with self.assertRaises(IntakeError):
            registry.check([{"kind": "sound", "sha256": "3" * 64}])

    def test_pinned_optional_original_and_shipped_digests_reach_stored_credits_without_audio_files(self):
        self.write_packs()
        with self.pinned():
            registry = LicensedAssetRegistry.from_catalogues(self.resources)
        credits = [{"kind": "sound", "sha256": value * 64} for value in ("2", "3", "4", "5", "6")]
        self.assertEqual(registry.check(credits), [{**value, "license": "CC0-1.0"} for value in credits])
        for descriptor in self.descriptors:
            self.assertEqual([p.name for p in (self.sounds / "pack-catalogues" / descriptor["id"]).iterdir()], ["catalogue.json"])
        store = UploadStore(Path(self.temp.name) / "uploads", total_quota=64 * 1024 * 1024,
                            account_quota=32 * 1024 * 1024, licensed_assets=registry)
        actor = str(uuid.uuid4())
        upload = store.begin(actor, str(uuid.uuid4()), dict(metadata(4096, "7" * 64), asset_credits=credits))
        self.assertEqual(store.metadata(actor, upload["id"])["asset_credits"], registry.check(credits))
        with self.assertRaises(IntakeError):
            registry.check([{"kind": "sound", "sha256": "8" * 64, "license": "CC0-1.0"}])

    def test_changed_descriptor_or_manifest_bytes_are_refused_without_silent_fallback(self):
        self.write_packs()
        with self.pinned():
            self.descriptor_file.write_bytes(self.descriptor_file.read_bytes() + b" ")
            with self.assertRaises(ValueError):
                LicensedAssetRegistry.from_catalogues(self.resources)
        self.save_descriptors()
        with self.pinned():
            path = self.sounds / "pack-catalogues" / self.descriptors[0]["id"] / "catalogue.json"
            path.write_bytes(path.read_bytes().replace(b"Optional fixture", b"Tampered fixture"))
            with self.assertRaises(ValueError):
                LicensedAssetRegistry.from_catalogues(self.resources)

    def test_missing_pinned_local_catalogue_is_not_replaced_by_a_remote_fetch(self):
        self.write_packs()
        path = self.sounds / "pack-catalogues" / self.descriptors[0]["id"] / "catalogue.json"
        path.unlink()
        with self.pinned(), mock.patch("urllib.request.urlopen", side_effect=AssertionError("No network allowed")) as network:
            with self.assertRaises(ValueError):
                LicensedAssetRegistry.from_catalogues(self.resources)
            network.assert_not_called()

    def test_even_pinned_descriptor_metadata_cannot_escape_paths_or_misstate_totals(self):
        self.write_packs()
        good = json.loads(json.dumps(self.descriptors))
        changes = [("id", "../outside"), ("id", "/absolute"), ("id", "bad.id"), ("id", "Uppercase"),
                   ("manifestBytes", True), ("manifestBytes", assets_module.MAX_SOUND_PACK_MANIFEST_BYTES + 1),
                   ("manifestSHA256", "z" * 64), ("soundCount", True), ("soundCount", 2), ("totalAudioBytes", 1025)]
        for key, value in changes:
            with self.subTest(key=key, value=value):
                self.descriptors = json.loads(json.dumps(good)); self.descriptors[0][key] = value; self.save_descriptors()
                with self.pinned(), self.assertRaises(ValueError):
                    LicensedAssetRegistry.from_catalogues(self.resources)
        self.descriptors = [good[0], good[0]]; self.save_descriptors()
        with self.pinned(), self.assertRaises(ValueError):
            LicensedAssetRegistry.from_catalogues(self.resources)

    def test_pinned_manifest_refuses_unknown_licence_forged_ids_duplicate_keys_and_bad_waveforms(self):
        self.write_packs()
        path = self.sounds / "pack-catalogues" / self.descriptors[0]["id"] / "catalogue.json"
        good = json.loads(path.read_bytes())
        changes = [("license", "owner-says-okay"), ("id", "9" * 64), ("originalSHA256", "bad"),
                   ("filename", "../foreign.wav"), ("byteCount", True), ("waveformPeaks", [0] * 256),
                   ("waveformRMS", [0.5] * 256), ("tags", ["../private"]), ("sourceURL", "https://example.com/untrusted")]
        for key, value in changes:
            with self.subTest(key=key):
                manifest = json.loads(json.dumps(good)); manifest["sounds"][0][key] = value
                data = json.dumps(manifest).encode(); path.write_bytes(data)
                self.descriptors[0]["manifestBytes"] = len(data)
                self.descriptors[0]["manifestSHA256"] = hashlib.sha256(data).hexdigest(); self.save_descriptors()
                with self.pinned(), self.assertRaises(ValueError):
                    LicensedAssetRegistry.from_catalogues(self.resources)
        data = json.dumps(good).replace('"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 1').encode()
        path.write_bytes(data); self.descriptors[0]["manifestBytes"] = len(data)
        self.descriptors[0]["manifestSHA256"] = hashlib.sha256(data).hexdigest(); self.save_descriptors()
        with self.pinned(), self.assertRaises(ValueError):
            LicensedAssetRegistry.from_catalogues(self.resources)

    def test_symlinked_descriptor_catalogue_and_each_optional_directory_are_refused(self):
        self.write_packs()
        paths = [self.descriptor_file, self.sounds, self.sounds / "pack-catalogues",
                 self.sounds / "pack-catalogues" / self.descriptors[0]["id"],
                 self.sounds / "pack-catalogues" / self.descriptors[0]["id"] / "catalogue.json"]
        with self.pinned():
            for path in paths:
                with self.subTest(path=path.name):
                    moved = path.with_name(path.name + ".owned"); path.rename(moved)
                    try:
                        path.symlink_to(moved.name, target_is_directory=moved.is_dir())
                        with self.assertRaises(ValueError):
                            LicensedAssetRegistry.from_catalogues(self.resources)
                    finally:
                        path.unlink(); moved.rename(path)

    def test_nonregular_and_oversized_metadata_fail_before_reading_and_conflicting_licences_fail(self):
        self.write_packs()
        catalogue = self.sounds / "pack-catalogues" / self.descriptors[0]["id"] / "catalogue.json"
        original = catalogue.read_bytes()
        with self.pinned():
            catalogue.unlink(); os.mkfifo(catalogue)
            try:
                with self.assertRaises(ValueError):
                    LicensedAssetRegistry.from_catalogues(self.resources)
            finally:
                catalogue.unlink(); catalogue.write_bytes(original)
            with catalogue.open("wb") as file:
                file.truncate(assets_module.MAX_SOUND_PACK_MANIFEST_BYTES + 1)
            with self.assertRaises(ValueError):
                LicensedAssetRegistry.from_catalogues(self.resources)
            catalogue.write_bytes(original)
            (self.sounds / "catalogue.json").write_text(json.dumps({"sounds": [
                {"license": "CC-BY-4.0", "sha256": "3" * 64, "originalSHA256": "3" * 64}]}))
            with self.assertRaises(ValueError):
                LicensedAssetRegistry.from_catalogues(self.resources)


class UploadApplicationTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        os.chmod(self.root, 0o700)
        self.store = UploadStore(self.root, total_quota=64 * 1024 * 1024, account_quota=32 * 1024 * 1024)
        self.actor = str(uuid.uuid4())
        self.app = UploadApplication(self.store, lambda token: self.actor, lambda path: None,
                                     lambda upload, owner, path, meta, expires: str(uuid.uuid4()))
        self.payload = b"q" * 4096
        self.digest = hashlib.sha256(self.payload).hexdigest()

    def call(self, method, path, body=b"", headers=None):
        environ = {"REQUEST_METHOD": method, "PATH_INFO": path, "wsgi.input": io.BytesIO(body),
                   "CONTENT_LENGTH": str(len(body)) if body else "", "HTTP_AUTHORIZATION": "Bearer header.payload.sig"}
        environ.update(headers or {})
        captured = {}
        def start_response(status, response_headers):
            captured["status"] = status
            captured["headers"] = dict(response_headers)
        body_out = b"".join(self.app(environ, start_response))
        return captured["status"], json.loads(body_out)

    def test_end_to_end_upload_over_wsgi(self):
        key = str(uuid.uuid4())
        status, created = self.call("POST", "/v1/render-uploads", json.dumps(metadata(len(self.payload), self.digest)).encode(),
                                    {"CONTENT_TYPE": "application/json", "HTTP_IDEMPOTENCY_KEY": key})
        self.assertEqual(status, "201 Created")
        upload = created["id"]
        status, state = self.call("PATCH", f"/v1/render-uploads/{upload}", self.payload,
                                  {"CONTENT_TYPE": "application/octet-stream", "HTTP_UPLOAD_OFFSET": "0", "HTTP_UPLOAD_CHECKSUM": self.digest})
        self.assertEqual(status, "200 OK")
        self.assertEqual(state["offset"], len(self.payload))
        status, done = self.call("POST", f"/v1/render-uploads/{upload}/complete")
        self.assertEqual(done["state"], "submitted")
        status, body = self.call("GET", f"/v1/render-uploads/{upload}")
        self.assertEqual(body["review_id"], done["review_id"])

    def test_rejections_are_json_and_never_leak(self):
        status, body = self.call("POST", "/v1/render-uploads", b"{}", {"CONTENT_TYPE": "text/plain"})
        self.assertEqual(status, "415 Unsupported Media Type")
        status, body = self.call("GET", "/v1/other")
        self.assertEqual(status, "404 Not Found")
        environ = {"REQUEST_METHOD": "GET", "PATH_INFO": "/v1/render-uploads/x", "wsgi.input": io.BytesIO(b""), "CONTENT_LENGTH": ""}
        captured = {}
        self.app(environ, lambda s, h: captured.setdefault("status", s))
        self.assertEqual(captured["status"], "401 Unauthorized")
        def exploding(token):
            raise RuntimeError("secret internal detail")
        app = UploadApplication(self.store, exploding, lambda p: None, lambda *a: str(uuid.uuid4()))
        captured = {}
        environ["HTTP_AUTHORIZATION"] = "Bearer header.payload.sig"
        out = b"".join(app(environ, lambda s, h: captured.setdefault("status", s)))
        self.assertEqual(captured["status"], "503 Service Unavailable")
        self.assertNotIn(b"secret internal detail", out)

    def test_chunk_size_bounded(self):
        key = str(uuid.uuid4())
        size = CHUNK_BYTES + 1
        _, created = self.call("POST", "/v1/render-uploads", json.dumps(metadata(size, "c" * 64)).encode(),
                               {"CONTENT_TYPE": "application/json", "HTTP_IDEMPOTENCY_KEY": key})
        status, body = self.call("PATCH", f"/v1/render-uploads/{created['id']}", b"z" * size,
                                 {"CONTENT_TYPE": "application/octet-stream", "HTTP_UPLOAD_OFFSET": "0", "HTTP_UPLOAD_CHECKSUM": "c" * 64})
        self.assertTrue(status.startswith("413 "), status)


if __name__ == "__main__":
    unittest.main()

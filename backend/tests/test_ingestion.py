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
import urllib.error
import uuid

from backend.ingestion import auth as auth_module
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
        return ReviewRegistrar("https://backend.example.test", "service-key", self.root, "terms-v1", self.links)

    def test_registration_posts_private_preview_and_returns_review(self):
        review = str(uuid.uuid4())
        opener = FakeOpener([FakeResponse(json.dumps({"review_id": review}).encode())])
        original = install_opener(registration_module, opener)
        try:
            meta = metadata(10, "b" * 64)
            self.assertEqual(self.registrar()(self.upload, str(uuid.uuid4()), self.path, meta, 1_800_000_000), review)
            body = json.loads(opener.requests[0].data)
            self.assertEqual(body["object_key"], self.upload + ".mp4")
            self.assertTrue(body["preview_url"].startswith("https://intake.example.test/v1/render-previews/"))
            self.assertEqual(opener.requests[0].full_url, "https://backend.example.test/rest/v1/rpc/sdi_register_upload")
        finally:
            registration_module.urllib.request.build_opener = original

    def test_registration_refuses_stale_consent_and_unconfirmed_backend(self):
        with self.assertRaises(IntakeError) as stale:
            self.registrar()(self.upload, str(uuid.uuid4()), self.path, {**metadata(10, "b" * 64), "consent_version": "terms-v0"}, 1_800_000_000)
        self.assertEqual(stale.exception.status, 409)
        for answer in (FakeResponse(json.dumps({"error": "Creator unavailable."}).encode()), urllib.error.URLError("down")):
            opener = FakeOpener([answer])
            original = install_opener(registration_module, opener)
            try:
                with self.assertRaises(IntakeError):
                    self.registrar()(self.upload, str(uuid.uuid4()), self.path, metadata(10, "b" * 64), 1_800_000_000)
            finally:
                registration_module.urllib.request.build_opener = original

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

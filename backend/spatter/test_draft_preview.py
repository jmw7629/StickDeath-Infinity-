"""Owner-only draft previews on the intake preview links (#212). Local files and the
real PreviewLinks/PreviewApplication only: no network, database or upload."""
import datetime as dt
import hashlib
import os
import stat
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from urllib.parse import urlsplit

import json

from backend.ingestion import registration as registration_module
from backend.ingestion.preview import PreviewApplication, PreviewLinks
from backend.ingestion.registration import ReviewRegistrar
from backend.ingestion.store import IntakeError, UploadStore
from backend.spatter import draft_preview as dp
from backend.spatter import draft_queue as dq
from backend.spatter import renderer_cli as rc
from backend.spatter.test_renderer_cli import FAKE

OWNER = str(uuid.UUID(int=1, version=4))
OTHER = str(uuid.UUID(int=2, version=4))
ORIGIN = "https://intake.example.test"
NOW = dt.datetime(2026, 10, 18, 9, 0, tzinfo=dt.timezone.utc)


class DraftPreviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / "intake"
        self.root.mkdir(mode=0o700)
        self.now = [1_800_000_000.0]
        self.clock = lambda: self.now[0]
        self.links = PreviewLinks(ORIGIN, b"k" * 32, lifetime=600, clock=self.clock)
        self.store = dp.DraftPreviewStore(self.root, self.links, OWNER, retention=7200, clock=self.clock)
        self.movie = self.base / "draft.mp4"
        self.movie.write_bytes(b"\x00\x00\x00\x18ftypmp42" + b"x" * 5000)
        self.digest = hashlib.sha256(self.movie.read_bytes()).hexdigest()
        self.app = PreviewApplication(self.root, self.links, dp.combined_authority(self.store, lambda *args: None))

    def tearDown(self):
        self.temp.cleanup()

    def get(self, url, headers=None):
        captured = {}
        environ = {"REQUEST_METHOD": "GET", "PATH_INFO": urlsplit(url).path, **(headers or {})}
        body = self.app(environ, lambda status, response_headers: captured.update(status=status, headers=dict(response_headers)))
        data = b"".join(body)
        getattr(body, "close", lambda: None)()
        return captured["status"], captured["headers"], data

    def test_publish_signs_a_short_owner_link_that_serves_the_exact_draft(self):
        published = self.store.publish(self.movie, self.digest)
        url, expires = published.url, published.expires
        self.assertEqual((published.object_key, published.byte_count), (dp.draft_upload_id(self.digest) + ".mp4", self.movie.stat().st_size))
        self.assertEqual(published.retained_until, dt.datetime.fromtimestamp(self.now[0] + 7200, dt.timezone.utc))
        self.assertTrue(url.startswith(ORIGIN + "/v1/render-previews/"))
        self.assertEqual(expires, dt.datetime.fromtimestamp(self.now[0] + 600, dt.timezone.utc), "link lifetime is the 10-minute signer bound")
        upload, owner, digest, _ = self.links.verify(urlsplit(url).path.rsplit("/", 1)[1])
        self.assertEqual((upload, owner, digest), (dp.draft_upload_id(self.digest), OWNER, self.digest))
        status, headers, data = self.get(url)
        self.assertEqual(status, "200 OK")
        self.assertEqual(headers["Cache-Control"], "private, no-store")
        self.assertEqual(hashlib.sha256(data).hexdigest(), self.digest)
        copy = self.root / (upload + ".mp4")
        self.assertEqual(stat.S_IMODE(copy.stat().st_mode), 0o600)
        self.store.publish(self.movie, self.digest)
        self.assertEqual(len(list(self.root.glob("*.mp4"))), 1, "republishing the same digest reuses its slot")

    def test_links_are_owner_only_and_expire(self):
        url = self.store.publish(self.movie, self.digest).url
        upload = dp.draft_upload_id(self.digest)
        other_link, _ = self.links(upload, OTHER, self.digest)
        self.assertEqual(self.get(other_link)[0], "404 Not Found", "a link signed for anyone but the owner is refused")
        self.assertIsNone(self.store.authority(upload, OWNER, "0" * 64))
        self.now[0] += 601
        self.assertEqual(self.get(url)[0], "404 Not Found", "signed links expire")
        fresh, _ = self.store.link(upload, self.digest)
        self.assertEqual(self.get(fresh)[0], "200 OK", "renewal signs a new short link while the copy is retained")
        self.now[0] += 7200
        self.assertIsNone(self.store.authority(upload, OWNER, self.digest))
        with self.assertRaises(ValueError):
            self.store.link(upload, self.digest)
        self.assertEqual(self.store.expire(), 1)
        self.assertFalse((self.root / (upload + ".mp4")).exists())
        self.assertFalse((self.root / (upload + ".draft.json")).exists())

    def test_changed_or_mismatched_content_is_refused(self):
        with self.assertRaises(ValueError):
            self.store.publish(self.movie, "a" * 64)
        self.assertEqual(sorted(p.name for p in self.root.iterdir() if not p.name.endswith(".lock")), [], "no partial preview is left")
        url = self.store.publish(self.movie, self.digest).url
        upload = dp.draft_upload_id(self.digest)
        with open(self.root / (upload + ".mp4"), "ab") as handle:
            handle.write(b"tampered")
        self.assertEqual(self.get(url)[0], "404 Not Found", "a changed copy no longer matches its recorded size")
        occupied = dp.draft_upload_id("b" * 64)
        (self.root / (occupied + ".mp4")).write_bytes(b"real upload")
        other = self.base / "other.mp4"
        other.write_bytes(b"other")
        with self.assertRaises(ValueError):
            self.store.publish(other, "b" * 64)

    def test_fallback_authority_still_serves_registered_uploads(self):
        calls = []
        authorize = dp.combined_authority(self.store, lambda *args: calls.append(args) or {"byte_count": 1, "expires": 1})
        self.assertEqual(authorize(str(uuid.uuid4()), OWNER, "c" * 64), {"byte_count": 1, "expires": 1})
        self.assertEqual(len(calls), 1)
        self.assertIsNone(dp.combined_authority(None, lambda *args: None)("x", "y", "z"))

    def test_configuration_is_bounded_and_unconfigured_safe(self):
        open_root = self.base / "open"
        open_root.mkdir(mode=0o755)
        os.chmod(open_root, 0o755)
        with self.assertRaises(ValueError):
            dp.DraftPreviewStore(open_root, self.links, OWNER)
        for retention in (60, 30 * 86400):
            with self.assertRaises(ValueError):
                dp.DraftPreviewStore(self.root, self.links, OWNER, retention=retention)
        with self.assertRaises(ValueError):
            dp.DraftPreviewStore(self.root, self.links, "owner")
        self.assertIsNone(dp.draft_previews_from_env({}))
        with self.assertRaises(ValueError):
            dp.draft_previews_from_env({dp.ENV_OWNER: OWNER})
        key = self.base / "signing.key"
        key.write_bytes(b"s" * 32)
        os.chmod(key, 0o600)
        env = {dp.ENV_OWNER: OWNER, dp.ENV_ORIGIN: ORIGIN, dp.ENV_KEY_FILE: str(key), dp.ENV_DIRECTORY: str(self.root), dp.ENV_QUOTA: str(1 << 30)}
        self.assertIsInstance(dp.draft_previews_from_env(env), dp.DraftPreviewStore)
        os.chmod(key, 0o644)
        with self.assertRaises(ValueError):
            dp.draft_previews_from_env(env)

    def test_renderer_from_env_submits_a_draft_with_a_bounded_owner_preview(self):
        key = self.base / "signing.key"
        key.write_bytes(b"s" * 32)
        os.chmod(key, 0o600)
        cli = self.base / "fake-cli"
        cli.write_text(FAKE.format(python=sys.executable, mode="ok"))
        cli.chmod(0o700)
        env = {rc.ENV_CLI: str(cli), rc.ENV_OUTPUT: str(self.base / "drafts"), dp.ENV_OWNER: OWNER, dp.ENV_ORIGIN: ORIGIN,
               dp.ENV_KEY_FILE: str(key), dp.ENV_DIRECTORY: str(self.root), dp.ENV_QUOTA: str(1 << 30)}
        renderer = dq.configured_renderer(env)
        self.assertIsInstance(renderer.publish_preview, dp.DraftPreviewStore)
        store = dq.InMemoryStore(now=lambda: NOW)
        submitted = []
        progress = store.progress
        store.progress = lambda *args, **kwargs: (submitted.append(kwargs.get("review")), progress(*args, **kwargs))[1]
        outcome = dq.run_once(store, owner="worker", reviewer=OWNER, now=lambda: NOW, renderer=renderer)
        self.assertEqual(outcome.state, "review_pending", outcome.reason)
        sent = [item for item in submitted if item][0]
        expires = dt.datetime.fromisoformat(sent["preview_expires_at"])
        self.assertLessEqual(expires - dt.datetime.now(dt.timezone.utc), dt.timedelta(minutes=15), "the review row carries the link's bounded expiry")
        self.assertTrue(sent["preview_url"].startswith(ORIGIN + "/v1/render-previews/"))
        review = store.reviews[0]
        self.assertEqual(review["destinations"], [])
        upload = dp.draft_upload_id(review["render_digest"])
        self.assertEqual(review["artifact"]["object_key"], upload + ".mp4", "the review records the retained copy")
        self.assertEqual(sent["object_key"], upload + ".mp4")
        self.assertEqual(sent["byte_count"], (self.root / (upload + ".mp4")).stat().st_size)
        self.assertGreater(dt.datetime.fromisoformat(sent["artifact_expires_at"]), expires)
        self.assertTrue((self.root / (upload + ".mp4")).is_file())
        without_preview = dict(env)
        del without_preview[dp.ENV_OWNER]
        failed = dq.run_once(dq.InMemoryStore(now=lambda: NOW), owner="worker", reviewer=OWNER, now=lambda: NOW,
                             renderer=dq.configured_renderer(without_preview))
        self.assertEqual(failed.state, "failed")
        self.assertIn("OWNER-GATED", failed.reason)


    def test_draft_copies_share_the_intake_disk_quota(self):
        size = self.movie.stat().st_size
        uploads = UploadStore(self.root, total_quota=size * 3, account_quota=size * 3)
        tight = dp.DraftPreviewStore(self.root, self.links, OWNER, retention=7200, clock=self.clock,
                                     total_quota=size * 3, other_usage=lambda: size * 2 + 1)
        with self.assertRaises(ValueError):
            tight.publish(self.movie, self.digest)
        roomy = dp.DraftPreviewStore(self.root, self.links, OWNER, retention=7200, clock=self.clock,
                                     total_quota=size * 3, other_usage=uploads.charged_bytes)
        roomy.publish(self.movie, self.digest)
        self.assertEqual(roomy.retained_bytes(), size)
        roomy.publish(self.movie, self.digest)
        self.assertEqual(roomy.retained_bytes(), size, "republishing the same draft is not charged twice")
        uploads.reserved_bytes = roomy.retained_bytes
        meta = {"size": size * 2 + 1, "sha256": "e" * 64, "title": "Clip", "source_revision": "rev1", "destinations": ["feed"],
                "rights_summary": "Own work", "consent_version": "terms-v1", "made_for_kids": False}
        with self.assertRaises(IntakeError) as caught:
            uploads.begin(str(uuid.uuid4()), str(uuid.uuid4()), meta)
        self.assertEqual(caught.exception.status, 429, "an upload cannot use space a retained draft holds")
        self.now[0] += 7201
        self.assertEqual(roomy.retained_bytes(), 0, "expired drafts stop counting")
        uploads.begin(str(uuid.uuid4()), str(uuid.uuid4()), meta)

    def test_owner_renewal_route_re_signs_a_draft_through_link(self):
        published = self.store.publish(self.movie, self.digest)
        upload = dp.draft_upload_id(self.digest)
        registrar = ReviewRegistrar("https://backend.example.test", "service-key", self.root, "terms-v1",
                                    self.store.signer(self.links))
        permit = str(uuid.uuid4())
        sent = []

        class Opener:
            def __init__(self, answers):
                self.answers = answers
            def open(self, request, timeout=None):
                sent.append(json.loads(request.data))
                body = json.dumps(self.answers.pop(0)).encode()
                class Response:
                    def read(self, limit=None): return body
                    def __enter__(self): return self
                    def __exit__(self, *exc): return False
                return Response()

        opener = Opener([{"permit": permit, "upload": upload, "creator": OWNER, "digest": self.digest, "byte_count": published.byte_count},
                         {"preview_url": "ok", "preview_expires_at": "later"}])
        original = registration_module.urllib.request.build_opener
        registration_module.urllib.request.build_opener = lambda *handlers: opener
        try:
            self.now[0] += 7000  # 200 s of retention left: the link may not outlive it
            result = registrar.renew_preview("Bearer owner-session-token", str(uuid.uuid4()), self.digest, 1)
        finally:
            registration_module.urllib.request.build_opener = original
        self.assertEqual(result["preview_url"], "ok")
        renewal = sent[1]
        self.assertEqual(renewal["permit"], permit)
        token = urlsplit(renewal["url"]).path.rsplit("/", 1)[1]
        self.assertEqual(self.links.verify(token)[:3], (upload, OWNER, self.digest))
        self.assertLessEqual(dt.datetime.fromisoformat(renewal["expires"]), published.retained_until,
                             "a renewed link never outlives the retained draft")
        self.assertEqual(self.get(renewal["url"])[0], "200 OK")
        other = self.store.signer(lambda *args: ("https://fallback.example/x", None))
        self.assertEqual(other(str(uuid.uuid4()), OWNER, "f" * 64)[0], "https://fallback.example/x", "uploads keep their own signer")


    def test_intake_factory_serves_drafts_only_when_configured(self):
        from backend.ingestion.application import create_application
        svc = self.base / "service.key"; svc.write_text("service-key"); os.chmod(svc, 0o600)
        key = self.base / "signing.key"; key.write_bytes(b"k" * 32); os.chmod(key, 0o600)
        env = {"SDI_BACKEND_URL": "https://backend.example.test", "SDI_INTAKE_ORIGIN": ORIGIN, "SDI_PUBLISHING_CONSENT_VERSION": "terms-v1",
               "SDI_INTAKE_DIRECTORY": str(self.root), "SDI_INTAKE_TOTAL_BYTES": str(4 << 30), "SDI_PREVIEW_SIGNING_KEY_FILE": str(key),
               "SDI_BACKEND_PUBLISHABLE_KEY": "pk", "SDI_BACKEND_SERVICE_KEY_FILE": str(svc), "SDI_FFPROBE": "/usr/bin/true", "SDI_FFMPEG": "/usr/bin/true"}
        drafts = dp.DraftPreviewStore(self.root, PreviewLinks(ORIGIN, b"k" * 32), OWNER)
        url = drafts.publish(self.movie, self.digest).url

        def fetch(app):
            seen = {}
            body = app({"REQUEST_METHOD": "GET", "PATH_INFO": urlsplit(url).path, "wsgi.url_scheme": "https", "HTTP_HOST": "intake.example.test"},
                       lambda status, headers: seen.update(status=status))
            data = b"".join(body)
            getattr(body, "close", lambda: None)()
            return seen["status"], data

        original = registration_module.ReviewRegistrar.preview_authority
        try:
            # Without the owner setting the factory never consults draft records (the
            # registered-upload authority, stubbed here to refuse, decides alone).
            registration_module.ReviewRegistrar.preview_authority = lambda self, *args: None
            self.assertEqual(fetch(create_application(env))[0], "404 Not Found")
            status, data = fetch(create_application(dict(env, SDI_DRAFT_PREVIEW_OWNER_ID=OWNER)))
        finally:
            registration_module.ReviewRegistrar.preview_authority = original
        self.assertEqual(status, "200 OK")
        self.assertEqual(hashlib.sha256(data).hexdigest(), self.digest)


if __name__ == "__main__":
    unittest.main()

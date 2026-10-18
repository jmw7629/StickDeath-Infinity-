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

from backend.ingestion.preview import PreviewApplication, PreviewLinks
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
        url, expires = self.store.publish(self.movie, self.digest)
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
        url, _ = self.store.publish(self.movie, self.digest)
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
        url, _ = self.store.publish(self.movie, self.digest)
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
        env = {dp.ENV_OWNER: OWNER, dp.ENV_ORIGIN: ORIGIN, dp.ENV_KEY_FILE: str(key), dp.ENV_DIRECTORY: str(self.root)}
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
               dp.ENV_KEY_FILE: str(key), dp.ENV_DIRECTORY: str(self.root)}
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
        self.assertTrue((self.root / (upload + ".mp4")).is_file())
        without_preview = dict(env)
        del without_preview[dp.ENV_OWNER]
        failed = dq.run_once(dq.InMemoryStore(now=lambda: NOW), owner="worker", reviewer=OWNER, now=lambda: NOW,
                             renderer=dq.configured_renderer(without_preview))
        self.assertEqual(failed.state, "failed")
        self.assertIn("OWNER-GATED", failed.reason)


if __name__ == "__main__":
    unittest.main()

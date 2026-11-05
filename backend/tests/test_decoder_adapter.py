"""Owned synthetic bytes/processes only; no media decoder/bwrap or network calls."""
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
import uuid
from unittest import mock

from backend.ingestion import application
from backend.ingestion.decoder import DecoderSandbox, ValidationReceipt, _capture
from backend.ingestion.media import MediaValidator
from backend.ingestion.store import IntakeError, UploadStore


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.snapshots = self.root / "snapshots"
        self.snapshots.mkdir(mode=0o700)
        self.source = self.root / "own-bytes"
        self.source.write_bytes(b"own synthetic bytes\n" * 100)
        self.source.chmod(0o600)
        # Snapshot IO is real. Constructor/root installation and decoder execution
        # intentionally remain Linux integration gates, never faked as acceptance.
        self.adapter = object.__new__(DecoderSandbox)
        self.adapter.snapshot_directory = self.snapshots
        self.adapter.root = self.root / "operator-decoder"
        self.adapter._slot = threading.BoundedSemaphore(1)

    def tearDown(self):
        self.temporary.cleanup()

    def test_snapshot_keeps_private0400_name_without_write_descriptors(self):
        original = self.source.read_bytes()
        with self.adapter.snapshot(self.source) as snapshot:
            identity = os.fstat(snapshot.fd)
            self.assertEqual(identity.st_nlink, 1)
            self.assertEqual(identity.st_mode & 0o777, 0o400)
            self.assertEqual(fcntl.fcntl(snapshot.fd, fcntl.F_GETFL) & os.O_ACCMODE, os.O_RDONLY)
            self.assertEqual(list(self.snapshots.iterdir()), [snapshot.path])
            self.assertEqual(snapshot.path.stat().st_ino, identity.st_ino)
            self.assertEqual(os.read(snapshot.fd, len(original) + 1), original)
            self.assertEqual(snapshot.sha256, hashlib.sha256(original).hexdigest())
            with self.assertRaises(OSError) as refused:
                os.write(snapshot.fd, b"no")
            self.assertEqual(refused.exception.errno, errno.EBADF)
            for fd in range(3, 256):
                try:
                    info = os.fstat(fd)
                except OSError:
                    continue
                if (info.st_dev, info.st_ino) == (identity.st_dev, identity.st_ino):
                    self.assertEqual(fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE, os.O_RDONLY)
        with self.assertRaises(OSError):
            os.fstat(snapshot.fd)
        self.assertEqual(list(self.snapshots.iterdir()), [])

    def test_snapshot_tamper_is_rejected_before_child_execution(self):
        with self.assertRaises(IntakeError):
            with self.adapter.snapshot(self.source) as snapshot:
                snapshot.path.chmod(0o600)
                snapshot.path.write_bytes(b"different own bytes")
                snapshot.path.chmod(0o400)
                with mock.patch("backend.ingestion.decoder.subprocess.Popen") as spawn:
                    with self.assertRaises(IntakeError):
                        self.adapter.probe(snapshot)
                    spawn.assert_not_called()

    def test_mutating_original_cannot_change_snapshot_and_fails_completion(self):
        original = self.source.read_bytes()
        with self.assertRaises(IntakeError) as failure:
            with self.adapter.snapshot(self.source) as snapshot:
                self.source.write_bytes(b"changed" * 100)
                self.assertEqual(os.read(snapshot.fd, len(original) + 1), original)
        self.assertEqual(failure.exception.status, 409)
        self.assertEqual(list(self.snapshots.iterdir()), [])

    def test_symlink_hardlink_and_busy_slot_fail_closed(self):
        link = self.root / "symlink"
        link.symlink_to(self.source)
        with self.assertRaises(OSError):
            with self.adapter.snapshot(link):
                self.fail("symlink accepted")
        hard = self.root / "hardlink"
        os.link(self.source, hard)
        with self.assertRaises(IntakeError):
            with self.adapter.snapshot(self.source):
                self.fail("hardlink accepted")
        hard.unlink()
        with self.adapter.snapshot(self.source):
            with self.assertRaises(IntakeError) as busy:
                with self.adapter.snapshot(self.source):
                    self.fail("overlapping snapshot accepted")
            self.assertEqual(busy.exception.status, 503)

    def test_child_environment_and_extra_descriptors_are_scrubbed(self):
        extra = os.open(self.source, os.O_RDONLY)
        os.set_inheritable(extra, True)
        try:
            with self.adapter.snapshot(self.source) as snapshot:
                code = ("import os,json;fd=int(__import__('sys').argv[1]);extra=int(__import__('sys').argv[2]);"
                        "out={'input':os.read(fd,3).decode(),'secret':os.getenv('SDI_TEST_SECRET')};"
                        "\ntry:os.fstat(extra);out['extra_open']=True"
                        "\nexcept OSError:out['extra_open']=False"
                        "\nprint(json.dumps(out))")
                with mock.patch.dict(os.environ, SDI_TEST_SECRET="own-not-a-secret"):
                    raw = _capture([sys.executable, "-I", "-B", "-c", code, str(snapshot.fd), str(extra)], snapshot.fd, 2, 1024)
                self.assertEqual(json.loads(raw), {"input": "own", "secret": None, "extra_open": False})
        finally:
            os.close(extra)

    def test_stderr_and_stdout_caps_terminate_owned_process(self):
        with self.adapter.snapshot(self.source) as snapshot:
            for fd, size in ((1, 2048), (2, 65537)):
                code = "import os,time;os.write(%d,b'x'*%d);time.sleep(10)" % (fd, size)
                start = time.monotonic()
                with self.assertRaises(IntakeError):
                    _capture([sys.executable, "-I", "-B", "-c", code], snapshot.fd, 2, 1024)
                self.assertLess(time.monotonic() - start, 2)

    def test_timeout_kills_owned_descendant_group(self):
        marker = self.root / "heartbeat"
        pidfile = self.root / "child-pid"
        code = ("import os,time,pathlib,sys;pid=os.fork();"
                "\nif pid: pathlib.Path(sys.argv[2]).write_text(str(pid));time.sleep(10)"
                "\nelse:"
                "\n while True:pathlib.Path(sys.argv[1]).write_text(str(time.monotonic()));time.sleep(.02)")
        try:
            with self.adapter.snapshot(self.source) as snapshot:
                with self.assertRaises(IntakeError):
                    _capture([sys.executable, "-I", "-B", "-c", code, str(marker), str(pidfile)], snapshot.fd, 0.3, 1024)
            self.assertTrue(marker.exists())
            before = marker.read_bytes()
            time.sleep(0.1)
            self.assertEqual(marker.read_bytes(), before)
        finally:
            if pidfile.exists():
                try:
                    os.kill(int(pidfile.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_factory_rejects_missing_adapter_before_secrets_or_store(self):
        with mock.patch.object(application, "_secret_file") as secrets:
            with self.assertRaises(ValueError):
                application.create_application({"SDI_BACKEND_URL": "https://own.example.test"})
            secrets.assert_not_called()
        with self.assertRaises(ValueError):
            MediaValidator(Path("/usr/bin/true"))

    def test_boot_rejects_untrusted_tool_root_without_starting_process(self):
        with mock.patch("backend.ingestion.decoder.subprocess.Popen") as spawn:
            with self.assertRaises(ValueError):
                DecoderSandbox(self.root, self.snapshots)
            spawn.assert_not_called()

    def test_constructor_rejects_real_or_effective_root_before_filesystem_checks(self):
        for uid, euid in ((0, 1000), (1000, 0)):
            with self.subTest(uid=uid, euid=euid), mock.patch("backend.ingestion.decoder.sys.platform", "linux"), \
                    mock.patch("backend.ingestion.decoder.os.getuid", return_value=uid), \
                    mock.patch("backend.ingestion.decoder.os.geteuid", return_value=euid), \
                    mock.patch.object(DecoderSandbox, "_check_tools") as tools, \
                    mock.patch.object(DecoderSandbox, "_check_snapshot_directory") as snapshots:
                with self.assertRaises(ValueError):
                    DecoderSandbox(self.adapter.root, self.snapshots)
                tools.assert_not_called()
                snapshots.assert_not_called()

    def test_snapshot_directory_rejects_actual_private_leaf_under_nonsticky0777_parent(self):
        shared = self.root / "untrusted-shared"
        shared.mkdir()
        shared.chmod(0o777)
        private = shared / "private"
        private.mkdir(mode=0o700)
        self.adapter.snapshot_directory = private
        self.assertEqual(private.stat().st_mode & 0o777, 0o700)
        self.assertEqual(shared.stat().st_mode & 0o1777, 0o777)
        with self.assertRaises(ValueError), mock.patch("backend.ingestion.decoder.tempfile.mkstemp") as create:
            with self.adapter.snapshot(self.source):
                self.fail("mutable snapshot ancestor accepted")
        create.assert_not_called()
        self.assertEqual(list(private.iterdir()), [])

    def test_snapshot_directory_accepts_actual_normal_private_path(self):
        self.adapter._check_snapshot_directory()

    def test_snapshot_directory_rejects_actual_symlink_ancestor(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.adapter.snapshot_directory = alias / "snapshots"
        with self.assertRaises(ValueError):
            self.adapter._check_snapshot_directory()

    def test_snapshot_directory_checks_explicit_root_sticky_temporary_ancestor(self):
        # Root-owned system-directory metadata is simulated: no chown, root
        # temporary directory creation or host permission change is performed.
        for shared in (Path("/tmp"), Path("/var/tmp")):
            self.adapter.snapshot_directory = shared / "own-worker" / "snapshots"
            metadata = {q: SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o755)
                        for q in self.adapter.snapshot_directory.parents}
            metadata[shared] = SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o1777)
            metadata[shared / "own-worker"] = SimpleNamespace(st_uid=os.getuid(), st_mode=stat.S_IFDIR | 0o700)
            metadata[self.adapter.snapshot_directory] = SimpleNamespace(st_uid=os.getuid(), st_mode=stat.S_IFDIR | 0o700)
            with self.subTest(shared=str(shared)), mock.patch.object(Path, "lstat", autospec=True, side_effect=metadata.__getitem__):
                self.adapter._check_snapshot_directory()
                # Both conditions must be checked, even at an allowed path.
                metadata[shared] = SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o777)
                with self.assertRaises(ValueError):
                    self.adapter._check_snapshot_directory()
                metadata[shared] = SimpleNamespace(st_uid=os.getuid(), st_mode=stat.S_IFDIR | 0o1777)
                with self.assertRaises(ValueError):
                    self.adapter._check_snapshot_directory()

    def test_snapshot_directory_rejects_other_owner_or_unlisted_shared_sticky_ancestor(self):
        shared = self.root / "other-ancestor"
        shared.mkdir()
        private = shared / "private"
        private.mkdir(mode=0o700)
        self.adapter.snapshot_directory = private
        original_lstat = Path.lstat
        for owner, mode in ((os.getuid() + 1, 0o755), (0, 0o1777)):
            def metadata(path):
                if path == shared:
                    return SimpleNamespace(st_uid=owner, st_mode=stat.S_IFDIR | mode)
                return original_lstat(path)
            with self.subTest(owner=owner, mode=oct(mode)), mock.patch.object(Path, "lstat", autospec=True, side_effect=metadata):
                with self.assertRaises(ValueError):
                    self.adapter._check_snapshot_directory()

    def test_probe_and_full_decode_receive_the_same_actual_snapshot_fd(self):
        seen = []
        def probe(snapshot):
            seen.append((snapshot.fd, os.fstat(snapshot.fd).st_ino, snapshot.sha256))
            return json.dumps({"format": {"duration": "1", "size": str(snapshot.size), "format_name": "mov,mp4"},
                "streams": [{"codec_type": "video", "codec_name": "h264", "width": 160,
                             "height": 90, "avg_frame_rate": "24/1"}]}).encode()
        def decode(snapshot, timeout):
            seen.append((snapshot.fd, os.fstat(snapshot.fd).st_ino, snapshot.sha256))
            self.assertEqual(timeout, 600)
        with mock.patch.object(self.adapter, "probe", side_effect=probe), mock.patch.object(self.adapter, "decode", side_effect=decode):
            receipt = MediaValidator(self.adapter)(self.source)
        self.assertEqual(seen[0], seen[1])
        self.assertEqual(receipt, ValidationReceipt(self.source.stat().st_size, hashlib.sha256(self.source.read_bytes()).hexdigest()))

    def test_snapshot_receipt_mismatch_never_registers_review(self):
        store_root = self.root / "store"
        store = UploadStore(store_root, total_quota=4 * 1024**2, account_quota=4 * 1024**2)
        data = self.source.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        actor = str(uuid.uuid4())
        metadata = {"size": len(data), "sha256": digest, "title": "Own synthetic test", "source_revision": "own1",
            "destinations": ["feed"], "rights_summary": "Own work", "consent_version": "terms-v1", "made_for_kids": False}
        upload = store.begin(actor, str(uuid.uuid4()), metadata)["id"]
        store.append(actor, upload, 0, data, digest)
        register = mock.Mock()
        with self.assertRaises(IntakeError):
            store.complete(actor, upload, validate_media=lambda _: ValidationReceipt(len(data), "0" * 64), register_review=register)
        register.assert_not_called()


if __name__ == "__main__":
    unittest.main()

"""Archive safety using synthetic app folders and actual compiler-made Mach-O.

These fixtures prove packaging rules, not that StickDeath runs on a local Mac.
"""
from pathlib import Path
import hashlib
import importlib.util
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("native_review_package", ROOT / "scripts/native-review/package_simulator_app.py")
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)
COMMIT = "a" * 40


class NativeReviewPackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix="sdi-macho-package-fixture-")
        p = Path(cls.fixture.name)
        source = p / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).decode().strip()
        for arch in ["x86_64", "arm64"]:
            subprocess.run(["xcrun", "clang", "-target", arch + "-apple-ios17.0-simulator",
                            "-isysroot", sdk, str(source), "-o", str(p / arch)], check=True, timeout=60)
        cls.binary = p / "universal"
        subprocess.run(["xcrun", "lipo", "-create", str(p / "x86_64"), str(p / "arm64"),
                        "-output", str(cls.binary)], check=True, timeout=30)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sdi-review-package-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "StickDeathInfinity.app"
        self.app.mkdir()
        self.info = {"CFBundleIdentifier": "com.willisnmb.stickdeathinfinity",
                     "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "CFBundleExecutable": "Fixture"}
        self.write_info()
        shutil.copy2(self.binary, self.app / "Fixture")
        (self.app / "Samples").mkdir()
        (self.app / "Samples/test-data.bin").write_bytes(bytes(range(256)) * 8192)
        self.output = self.root / "review"

    def write_info(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))

    def test_real_archive_preserves_every_fixture_byte_hash_and_executable_mode(self):
        before = {p.relative_to(self.app).as_posix(): p.read_bytes() for p in self.app.rglob("*") if p.is_file()}
        receipt = subject.package(self.app, self.output, COMMIT)
        self.assertEqual(receipt["architectures"], ["arm64", "x86_64"])
        self.assertEqual(receipt["sourceCommit"], COMMIT)
        self.assertFalse(receipt["localMacRuntimeVerified"])
        self.assertFalse(receipt["appWasModified"])
        archive = self.output / "StickDeathInfinity-simulator.zip"
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), receipt["archiveSHA256"])
        with zipfile.ZipFile(archive) as zipped:
            self.assertIsNone(zipped.testzip())
            self.assertEqual(len(zipped.infolist()), len(before))
            for name, data in before.items():
                self.assertEqual(zipped.read("StickDeathInfinity.app/" + name), data)
                self.assertEqual(receipt["fileHashes"][name], hashlib.sha256(data).hexdigest())
                self.assertEqual((self.app / name).read_bytes(), data)
            self.assertTrue((zipped.getinfo("StickDeathInfinity.app/Fixture").external_attr >> 16) & 0o111)

    def test_all_backend_settings_reject_without_copying_configured_app(self):
        for key in subject.SETTINGS:
            self.info[key] = "configured-test-value"
            self.write_info()
            with self.assertRaises(ValueError):
                subject.package(self.app, self.output, COMMIT)
            self.assertFalse(self.output.exists())
            self.info.pop(key)

    def test_wrong_source_identity_platform_and_executable_fail_closed(self):
        for commit in ["short", "../source", "A" * 40]:
            with self.assertRaises(ValueError):
                subject.package(self.app, self.output, commit)
        for key, bad in [("CFBundleIdentifier", "invalid.fixture"), ("CFBundleSupportedPlatforms", ["iPhoneOS"]),
                         ("CFBundleExecutable", "../Fixture"), ("CFBundleExecutable", "missing")]:
            old = self.info[key]
            self.info[key] = bad
            self.write_info()
            with self.assertRaises(ValueError):
                subject.package(self.app, self.output, COMMIT)
            self.info[key] = old
        self.assertFalse(self.output.exists())

    def test_links_and_device_provisioning_are_never_archived(self):
        linked = self.root / "Linked.app"
        linked.symlink_to(self.app, target_is_directory=True)
        with self.assertRaises(ValueError):
            subject.package(linked, self.output, COMMIT)
        foreign = self.root / "foreign"
        foreign.write_bytes(b"preserved foreign test data")
        link = self.app / "linked-data"
        link.symlink_to(foreign)
        with self.assertRaises(ValueError):
            subject.package(self.app, self.output, COMMIT)
        link.unlink()
        (self.app / "embedded.mobileprovision").write_bytes(b"not a real provisioning profile")
        with self.assertRaises(ValueError):
            subject.package(self.app, self.output, COMMIT)
        self.assertEqual(foreign.read_bytes(), b"preserved foreign test data")

    def test_existing_output_and_size_limits_preserve_originals(self):
        self.output.mkdir()
        (self.output / "owned-by-another-operation").write_text("keep")
        with self.assertRaises(FileExistsError):
            subject.package(self.app, self.output, COMMIT)
        self.assertEqual((self.output / "owned-by-another-operation").read_text(), "keep")
        with patch.object(subject, "MAXIMUM_BYTES", 64):
            with self.assertRaises(ValueError):
                subject.package(self.app, self.root / "other", COMMIT)
        self.assertFalse((self.root / "other").exists())

    def test_apple_silicon_only_binary_cannot_claim_intel_support(self):
        shutil.copy2(Path(self.fixture.name) / "arm64", self.app / "Fixture")
        with self.assertRaises(ValueError):
            subject.package(self.app, self.output, COMMIT)
        self.assertFalse(self.output.exists())

    def test_nested_native_code_cannot_hide_an_incompatible_architecture(self):
        shutil.copy2(Path(self.fixture.name) / "arm64", self.app / "Fixture.debug.dylib")
        with self.assertRaises(ValueError):
            subject.package(self.app, self.output, COMMIT)
        self.assertFalse(self.output.exists())

    def test_expired_packaging_budget_creates_no_output(self):
        with patch.object(subject.time, "monotonic", side_effect=[0, 121]):
            with self.assertRaises(TimeoutError):
                subject.package(self.app, self.output, COMMIT)
        self.assertFalse(self.output.exists())

    def test_actual_source_change_after_inspection_removes_owned_partial(self):
        original = subject.subprocess.check_output
        def inspect_and_change(command, **kwargs):
            result = original(command, **kwargs)
            if command[:4] == ["xcrun", "vtool", "-arch", "arm64"]:
                (self.app / "Samples/test-data.bin").write_bytes(b"changed during inspection")
            return result
        with patch.object(subject.subprocess, "check_output", side_effect=inspect_and_change):
            with self.assertRaises(ValueError):
                subject.package(self.app, self.output, COMMIT)
        self.assertFalse((self.output / "StickDeathInfinity-simulator.zip").exists())
        self.assertFalse((self.output / "StickDeathInfinity-simulator.zip.partial").exists())
        self.assertEqual((self.app / "Samples/test-data.bin").read_bytes(), b"changed during inspection")


if __name__ == "__main__":
    unittest.main()

"""Device scratch policy with tiny real paths and virtual stat extents.

No compiler, subprocess, network or large/sparse physical file is used. These
cases verify accounting/admission rules, not application compilation or runtime.
"""
from pathlib import Path
import importlib.util
import os
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("device_review_guard", ROOT / "scripts/native-smoke/build_device_review_ci.py")
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)
GIB = 1024 ** 3
CAS = "DerivedData/CompilationCache.noindex/generic/v1.1/v8.data"


class DeviceReviewScratchPolicyTests(unittest.TestCase):
    def setUp(self):
        # The caller may keep even these single-byte fixtures on its private SSD.
        self.temp = tempfile.TemporaryDirectory(prefix="sdi-guard-policy-", dir=os.environ.get("SDI_POLICY_FIXTURE_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.scratch = self.root / "scratch"
        self.scratch.mkdir()
        self.records = {}
        self.original_lstat = Path.lstat
        self.guard = subject.Guard(self.root, self.scratch)

    def file(self, relative=CAS, *, logical=27_002_197_845, allocated=169_922_560,
             uid=None, nlink=None, blocks=True):
        path = self.scratch / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x")
        real = path.lstat()
        record = SimpleNamespace(st_mode=real.st_mode, st_size=logical,
                                 st_uid=real.st_uid if uid is None else uid,
                                 st_nlink=real.st_nlink if nlink is None else nlink)
        if blocks:
            record.st_blocks = allocated // 512
        self.records[path] = record
        return path

    def scan(self, *, initial=False, free=64 * GIB, walk=None, deadline=None):
        def lstat(path):
            return self.records[path] if path in self.records else self.original_lstat(path)
        with patch.object(Path, "lstat", lstat), \
             patch.object(subject.shutil, "disk_usage", return_value=SimpleNamespace(free=free)), \
             patch.object(subject, "WORK_DEADLINE", deadline), \
             patch.object(subject.time, "monotonic", return_value=100.0):
            if walk is None:
                self.guard.check(initial=initial)
            else:
                with patch.object(subject.os, "walk", return_value=walk):
                    self.guard.check(initial=initial)
        return self.guard.observation

    def rejected(self, **scan):
        with self.assertRaises(RuntimeError):
            self.scan(**scan)
        return self.guard.observation

    def test_failure_scratch_size_envelope_uses_allocation_and_reports_both_sizes(self):
        self.file()
        seen = self.scan()
        self.assertTrue(seen["scratchScanComplete"])
        self.assertEqual(seen["scratchSparseCompilationCacheCount"], 1)
        self.assertEqual(seen["scratchLogicalBytes"], 27_002_197_845)
        self.assertEqual(seen["scratchChargedBytes"], 169_922_560)
        self.assertEqual(seen["scratchAllocatedChargeBytes"], 169_922_560)
        self.assertEqual(seen["scratchSparseCompilationCacheAllocatedByteLimit"], 2 * GIB)
        self.assertEqual(seen["scratchChargedByteLimit"], 16 * GIB)
        self.assertEqual(seen["scratchAllocatedByteLimit"], 16 * GIB)

    def test_renamed_adjacent_version_and_unrelated_sparse_files_remain_logically_charged(self):
        for relative in (CAS + ".copy", CAS.replace("v8.data", "v9.data"),
                         CAS.replace("v1.1", "v1.2"), "DerivedData/other/v8.data"):
            with self.subTest(relative=relative):
                self.records.clear()
                self.file(relative)
                seen = self.rejected(walk=[(str((self.scratch / relative).parent), [], [Path(relative).name])])
                self.assertEqual(seen["scratchSparseCompilationCacheCount"], 0)
                self.assertEqual(seen["scratchChargedBytes"], 27_002_197_845)
                self.guard = subject.Guard(self.root, self.scratch)

    def test_foreign_owner_does_not_receive_sparse_accounting(self):
        self.file(uid=os.getuid() + 1)
        self.assertEqual(self.rejected()["scratchSparseCompilationCacheCount"], 0)

    def test_hardlinked_file_does_not_receive_sparse_accounting(self):
        path = self.file(nlink=2)
        os.link(path, self.root / "second-link")
        self.assertEqual(self.rejected()["scratchSparseCompilationCacheCount"], 0)

    def test_exact_data_path_symlink_and_directory_are_rejected(self):
        for kind in ("symlink", "directory"):
            with self.subTest(kind=kind):
                path = self.scratch / CAS
                path.parent.mkdir(parents=True, exist_ok=True)
                if kind == "symlink":
                    target = self.root / "outside-data"
                    target.write_bytes(b"x")
                    path.symlink_to(target)
                else:
                    path.mkdir()
                seen = self.rejected()
                self.assertEqual(seen["scratchSparseCompilationCacheCount"], 0)
                path.unlink() if kind == "symlink" else path.rmdir()
                self.guard = subject.Guard(self.root, self.scratch)

    def test_symlink_parent_or_escaped_scratch_never_qualifies(self):
        outside = self.root / "outside"
        outside.mkdir()
        parent = self.scratch / "DerivedData/CompilationCache.noindex/generic"
        parent.parent.mkdir(parents=True)
        parent.symlink_to(outside, target_is_directory=True)
        path = self.file()
        # Model an entry yielded before a concurrent parent replacement, rather
        # than relying on os.walk to traverse a symlink it normally refuses.
        seen = self.rejected(walk=[(str(path.parent), [], [path.name])])
        self.assertEqual(seen["scratchSparseCompilationCacheCount"], 0)
        parent.unlink()
        self.records.clear()
        real_scratch = self.root / "real-scratch"
        self.scratch.rename(real_scratch)
        self.scratch.symlink_to(real_scratch, target_is_directory=True)
        self.file()
        self.guard = subject.Guard(self.root, self.scratch)
        seen = self.rejected()
        self.assertEqual(seen["scratchSparseCompilationCacheCount"], 0)

    def test_foreign_directory_owner_is_not_an_owned_chain(self):
        path = self.file()
        parent = path.parent
        actual = parent.lstat()
        self.records[parent] = SimpleNamespace(st_mode=actual.st_mode, st_uid=os.getuid() + 1)
        self.assertEqual(self.rejected()["scratchSparseCompilationCacheCount"], 0)

    def test_missing_allocation_and_insufficient_sparsity_keep_logical_charge(self):
        for values in ({"blocks": False}, {"allocated": 27_002_197_632}, {"allocated": 4 * GIB}):
            with self.subTest(values=values):
                self.file(**values)
                self.assertEqual(self.rejected()["scratchSparseCompilationCacheCount"], 0)
                self.guard = subject.Guard(self.root, self.scratch)

    def test_zero_allocated_sparse_extent_is_still_bounded(self):
        self.file(allocated=0)
        seen = self.scan()
        self.assertEqual(seen["scratchSparseCompilationCacheCount"], 1)
        self.assertEqual(seen["scratchChargedBytes"], 0)

    def test_exact_logical_and_allocated_boundaries_pass(self):
        self.file(logical=32 * GIB, allocated=2 * GIB)
        seen = self.scan()
        self.assertEqual(seen["scratchSparseCompilationCacheLogicalBytes"], 32 * GIB)
        self.assertEqual(seen["scratchSparseCompilationCacheAllocatedBytes"], 2 * GIB)

    def test_one_byte_over_logical_limit_fails(self):
        self.file(logical=32 * GIB + 1, allocated=2 * GIB)
        self.assertEqual(self.rejected()["scratchOffendingRelativeEntry"], CAS)

    def test_one_block_over_allocated_limit_fails(self):
        self.file(logical=32 * GIB, allocated=2 * GIB + 512)
        self.assertEqual(self.rejected()["scratchOffendingRelativeEntry"], CAS)

    def test_duplicate_cas_observation_exceeds_one_file_allowance(self):
        path = self.file(logical=10 * GIB, allocated=512)
        seen = self.rejected(walk=[(str(path.parent), [], [path.name, path.name])])
        self.assertEqual(seen["scratchSparseCompilationCacheCount"], 2)

    def test_ordinary_logical_and_allocated_caps_still_fail(self):
        for logical, allocated in ((17 * GIB, 512), (GIB, 17 * GIB)):
            with self.subTest(logical=logical, allocated=allocated):
                self.file("ordinary.bin", logical=logical, allocated=allocated)
                seen = self.rejected(walk=[(str(self.scratch), [], ["ordinary.bin"])])
                self.assertEqual(seen["scratchSparseCompilationCacheCount"], 0)
                self.guard = subject.Guard(self.root, self.scratch)

    def test_special_and_ordinary_allocations_share_the_same_global_cap(self):
        self.file(logical=32 * GIB, allocated=2 * GIB)
        self.file("ordinary.bin", logical=15 * GIB, allocated=15 * GIB)
        seen = self.rejected()
        self.assertEqual(seen["scratchSparseCompilationCacheCount"], 1)
        self.assertEqual(seen["scratchAllocatedChargeBytes"], 17 * GIB)
        self.assertEqual(seen["scratchChargedBytes"], 17 * GIB)

    def test_existing_sdk_sparse_accounting_is_retained(self):
        name = "DerivedData/SDKStatCaches.noindex/iphoneos26.2-23C53-" + "a" * 64 + ".sdkstatcache"
        self.file(name, logical=64 * GIB, allocated=1024 ** 2)
        seen = self.scan()
        self.assertEqual(seen["scratchSparseSDKStatCacheCount"], 1)
        self.assertEqual(seen["scratchSparseCompilationCacheCount"], 0)
        self.assertEqual(seen["scratchChargedBytes"], 1024 ** 2)

    def test_free_space_and_overall_deadline_still_stop_before_scan(self):
        for initial, free in ((False, 4 * GIB - 1), (True, 8 * GIB - 1)):
            with self.subTest(initial=initial):
                self.rejected(initial=initial, free=free)
        with self.assertRaises(TimeoutError):
            self.scan(deadline=0)

    def test_all_three_no_cache_arguments_are_unchanged(self):
        arguments = subject.build_arguments(self.scratch, self.root / "Info.plist")
        for value in ("COMPILATION_CACHE_ENABLE_CACHING=NO", "SWIFT_ENABLE_COMPILE_CACHE=NO", "CLANG_ENABLE_COMPILE_CACHE=NO"):
            self.assertEqual(arguments.count(value), 1)


if __name__ == "__main__":
    unittest.main()

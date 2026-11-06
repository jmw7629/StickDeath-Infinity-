"""Device scratch policy with tiny real paths and virtual stat extents.

No compiler, subprocess, network or large/sparse physical file is used. These
cases verify accounting/admission rules, not application compilation or runtime.
"""
from pathlib import Path
import importlib.util
import os
import stat
import struct
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
        # OTHER_LDFLAGS reaches clang first. Its linker-only option must be
        # driver-forwarded; no signing/Review identity/offline guard may drift.
        linker_settings = [value for value in arguments if value.startswith("OTHER_LDFLAGS=")]
        self.assertEqual(linker_settings, ["OTHER_LDFLAGS=$(inherited) -Wl,-no_adhoc_codesign"])
        self.assertNotIn("-no_adhoc_codesign", linker_settings[0].partition("=")[2].split())
        for value in ("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
                      "DEVELOPMENT_TEAM=", "PRODUCT_BUNDLE_IDENTIFIER=" + subject.BUNDLE):
            self.assertEqual(arguments.count(value), 1)
        for setting in subject.OFFLINE_SETTINGS:
            self.assertEqual(arguments.count(setting + "="), 1)


class DeviceReviewMachORpathTests(unittest.TestCase):
    """Tiny actual Mach-O byte fixtures; no compiler or native project build."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sdi-rpath-policy-", dir=os.environ.get("SDI_POLICY_FIXTURE_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / "sdi-device-review-build/DerivedData/Build/Products/Debug-iphoneos" / (subject.APP + ".app")
        self.app.mkdir(parents=True)
        self.binary = self.app / subject.APP
        self.qualified = str(self.app.parent / "PackageFrameworks")

    def command(self, kind, name):
        fixed = 12 if kind & 0x7fffffff == 0x1c else 24
        encoded = name.encode() + b"\0"
        length = (fixed + len(encoded) + 7) & ~7
        return struct.pack("<III", kind, length, fixed) + bytes(fixed - 12) + encoded + bytes(length - fixed - len(encoded))

    def macho(self, commands=(), *, platform=2, cpu=0x0100000c, subtype=0, filetype=2):
        build = struct.pack("<IIIIII", 0x32, 24, platform, 17 << 16, 26 << 16, 0)
        commands = [build, *commands]
        payload = b"".join(commands)
        self.binary.write_bytes(struct.pack("<IiiIIIII", 0xfeedfacf, cpu, subtype, filetype, len(commands), len(payload), 0, 0) + payload)
        return self.binary

    def inspect(self, commands=(), **header):
        return subject.inspect_macho(self.macho(commands, **header), qualified_build_rpath=self.qualified)

    def test_actual_main_and_debug_dylib_runpaths_are_directories_and_audited(self):
        for names, filetype in ((["@executable_path", self.qualified, "@executable_path/Frameworks"], 2),
                                (["/usr/lib/swift", self.qualified, "@executable_path/Frameworks"], 6)):
            with self.subTest(filetype=filetype):
                result = self.inspect([self.command(0x8000001c, name) for name in names], filetype=filetype)
                self.assertEqual(result["rpaths"], names)
                self.assertEqual(result["qualifiedBuildRpathDirectory"], self.qualified)
                self.assertEqual(result["dependencies"], [])
                self.assertEqual(result["buildVersion"]["platform"], "iOS")
                self.assertEqual(result["signature"], "absent")

    def test_bare_macros_are_rpath_only_and_default_does_not_qualify_build_paths(self):
        names = ["@executable_path", "@loader_path"]
        result = subject.inspect_macho(self.macho([self.command(0x8000001c, name) for name in names]))
        self.assertEqual(result["rpaths"], names)
        self.assertIsNone(result["qualifiedBuildRpathDirectory"])
        with self.assertRaisesRegex(ValueError, "LC_RPATH"):
            subject.inspect_macho(self.macho([self.command(0x8000001c, self.qualified)]))
        for kind in (0xc, 0xd, 0x80000018, 0x8000001f, 0x80000023):
            for name in [*names, self.qualified]:
                with self.subTest(kind=kind, name=name), self.assertRaisesRegex(ValueError, "dylib"):
                    self.inspect([self.command(kind, name)])

    def test_foreign_adjacent_relative_and_unqualified_runpaths_stay_rejected(self):
        for name in (self.qualified + "-other", self.qualified + "/child", self.qualified + "/../PackageFrameworks",
                     str(self.app.parent.parent / "PackageFrameworks"), "/private/arbitrary-secret-directory",
                     "PackageFrameworks", "@executable_path-other", "@loader_path-other", "@rpath"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "LC_RPATH") as error:
                self.inspect([self.command(0x8000001c, name)])
            self.assertNotIn(name, str(error.exception))

    def test_caller_cannot_qualify_a_foreign_directory_or_non_ci_product(self):
        path = self.macho([self.command(0x8000001c, self.qualified)])
        for value in (self.qualified + "-other", "/private/PackageFrameworks", [self.qualified]):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "exact validated CI product"):
                subject.inspect_macho(path, qualified_build_rpath=value)
        outside = self.root / (subject.APP + ".app")
        outside.mkdir()
        moved = outside / subject.APP
        moved.write_bytes(path.read_bytes())
        with self.assertRaisesRegex(ValueError, "exact validated CI product"):
            subject.inspect_macho(moved, qualified_build_rpath=str(outside.parent / "PackageFrameworks"))
        alias = self.root / "linked-product.app"
        alias.symlink_to(self.app, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "exact validated CI product"):
            subject.inspect_macho(alias / subject.APP, qualified_build_rpath=self.qualified)

    def test_duplicate_runpaths_are_rejected_including_the_qualified_directory(self):
        for name in ("@executable_path", "@loader_path/Frameworks", self.qualified, "/usr/lib/swift"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Duplicate native LC_RPATH"):
                self.inspect([self.command(0x8000001c, name)] * 2)

    def test_existing_dylib_prefixes_remain_unchanged(self):
        names = ["@rpath/Library.dylib", "@executable_path/Library.dylib", "@loader_path/Library.dylib",
                 "/System/Library/Frameworks/Foundation.framework/Foundation", "/usr/lib/libSystem.B.dylib"]
        result = self.inspect([self.command(0xc, name) for name in names])
        self.assertEqual(result["dependencies"], names)
        self.assertEqual(result["rpaths"], [])

    def test_signed_simulator_wrong_cpu_and_malformed_headers_still_fail(self):
        rpath = self.command(0x8000001c, self.qualified)
        with self.assertRaisesRegex(ValueError, "signature"):
            self.inspect([rpath, struct.pack("<IIII", 0x1d, 16, 0, 0)])
        for header in ({"platform": 7}, {"cpu": 0x01000007}, {"subtype": 2}, {"filetype": 1}):
            with self.subTest(header=header), self.assertRaises(ValueError):
                self.inspect([rpath], **header)
        path = self.macho([rpath])
        path.write_bytes(path.read_bytes()[:-1])
        with self.assertRaisesRegex(ValueError, "bounds"):
            subject.inspect_macho(path, qualified_build_rpath=self.qualified)
        path.write_bytes(b"\xca\xfe\xba\xbe" + bytes(28))
        with self.assertRaisesRegex(ValueError, "thin"):
            subject.inspect_macho(path, qualified_build_rpath=self.qualified)


if __name__ == "__main__":
    unittest.main()

"""Read-only disk preflight thresholds with a fake disk_usage; no Mac, no deletion."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sdi_disk_preflight", ROOT / "scripts/native-smoke/disk_preflight.py")
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)
GIB = subject.GIB


def fake_usage(free_gib):
    def usage(path):
        return (int(100 * GIB), int(100 * GIB) - int(free_gib * GIB), int(free_gib * GIB))
    return usage


class DiskPreflight(unittest.TestCase):
    def test_start_headroom_met(self):
        result = subject.measure("/", usage=fake_usage(2.0), now=lambda: 1000)
        self.assertEqual((result["status"], result["exitCode"]), ("ok", 0))
        self.assertEqual(result["freeGiB"], 2.0)
        self.assertEqual((result["startGiB"], result["floorGiB"]), (1.85, 1.4))
        self.assertFalse(result["deletedAnything"])
        self.assertTrue(result["readOnly"])
        self.assertEqual(result["measuredAt"], 1000)

    def test_between_floor_and_start_blocks_new_work(self):
        result = subject.measure("/", usage=fake_usage(1.616), now=lambda: 0)
        self.assertEqual((result["status"], result["exitCode"]), ("below-start", 2))

    def test_at_or_below_floor_stops(self):
        for free in (1.4, 1.39, 0.0):
            with self.subTest(free=free):
                result = subject.measure("/", usage=fake_usage(free), now=lambda: 0)
                self.assertEqual((result["status"], result["exitCode"]), ("below-floor", 3))

    def test_exact_start_boundary_counts_as_met(self):
        # 2.0 GiB is exactly representable in bytes; 1.85 GiB is not.
        result = subject.measure("/", 2.0, 1.5, usage=fake_usage(2.0), now=lambda: 0)
        self.assertEqual(result["status"], "ok")
        result = subject.measure("/", 2.0, 1.5, usage=fake_usage(1.5), now=lambda: 0)
        self.assertEqual(result["status"], "below-floor")

    def test_thresholds_cannot_be_lowered_or_inverted(self):
        for start, floor in ((1.8, 1.4), (1.85, 1.3), (1.5, 1.6), (1.85, 0)):
            with self.subTest(start=start, floor=floor), self.assertRaises(ValueError):
                subject.measure("/", start, floor, usage=fake_usage(5))

    def test_higher_thresholds_are_allowed(self):
        result = subject.measure("/", 3.0, 2.0, usage=fake_usage(2.5), now=lambda: 0)
        self.assertEqual(result["status"], "below-start")

    def test_cli_prints_json_and_returns_status_exit_code(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = subject.main(["/", "--start-gib", "1.85", "--floor-gib", "1.4"], usage=fake_usage(1.0))
        payload = json.loads(out.getvalue())
        self.assertEqual(code, 3)
        self.assertEqual(payload["status"], "below-floor")
        self.assertEqual(payload["path"], "/")

    def test_cli_reports_measurement_errors_as_json(self):
        def failing(path):
            raise FileNotFoundError(path)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = subject.main(["/definitely/missing"], usage=failing)
        payload = json.loads(out.getvalue())
        self.assertEqual((code, payload["status"], payload["exitCode"]), (4, "error", 4))
        self.assertFalse(payload["deletedAnything"])

    def test_real_measurement_touches_nothing(self):
        with tempfile.TemporaryDirectory(prefix="sdi-disk-preflight-") as directory:
            before = sorted(Path(directory).iterdir())
            result = subject.measure(directory)
            self.assertIn(result["status"], {"ok", "below-start", "below-floor"})
            self.assertGreater(result["totalBytes"], 0)
            self.assertEqual(sorted(Path(directory).iterdir()), before)


if __name__ == "__main__":
    unittest.main()

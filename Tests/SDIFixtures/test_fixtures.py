import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify_fixtures  # noqa: E402


class SDIFixtureTests(unittest.TestCase):
    def test_committed_fixtures_match_generator_and_expectations(self):
        self.assertEqual([], verify_fixtures.verify())

    def test_golden_fixture_describes_schema_35_features(self):
        document = verify_fixtures.decode((verify_fixtures.ROOT / "assets" / "swift-schema35-studio.sdi").read_bytes())
        self.assertEqual(35, document["schemaVersion"])
        self.assertEqual(["position", "alpha"], [layer["lockMode"] for layer in document["layers"]])
        self.assertEqual("#FC5D5B", document["layers"][0]["colorLabel"])
        self.assertEqual(["multiply", "linear-dodge"], [layer["blendMode"] for layer in document["layers"]])
        self.assertEqual(3, document["frames"][1]["holdTicks"])
        self.assertEqual([0.2, 0.6, 1.0], [p["pressure"] for p in document["frames"][1]["elements"][0]["points"]])
        self.assertEqual([-0.25, 0, 0.5, 0], document["audioTrackPans"])
        self.assertEqual([2], document["soloedAudioTracks"])

    def test_corrupt_bytes_are_detected(self):
        data = bytearray((verify_fixtures.ROOT / "assets" / "swift-schema35-studio.sdi").read_bytes())
        data[-1] ^= 1
        with self.assertRaises(ValueError):
            verify_fixtures.decode(bytes(data))
        with self.assertRaises(ValueError):
            verify_fixtures.decode(bytes(data[:-1]))


if __name__ == "__main__":
    unittest.main()

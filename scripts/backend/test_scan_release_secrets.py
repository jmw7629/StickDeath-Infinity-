"""Offline tests for scan_release_secrets.py. Builds throwaway git repositories only.

    python3 -I scripts/backend/test_scan_release_secrets.py
"""
from __future__ import annotations

import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("scan_release_secrets", HERE / "scan_release_secrets.py")
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)

# Synthetic values assembled at runtime so this file never contains a match itself.
STRIPE = "sk_" + "live_" + "Z9" * 12
WEBHOOK = "whsec_" + "Q7" * 10
PEM = "-----BEGIN " + "PRIVATE KEY-----"


class ScanTests(unittest.TestCase):
    def repo(self, files: dict[str, bytes | str]) -> Path:
        root = Path(tempfile.mkdtemp(prefix="sdi-scan-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(root)])
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        for name, content in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content if isinstance(content, bytes) else content.encode())
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
        return root

    def test_clean_tree_passes(self):
        root = self.repo({"README.md": "Nothing to see.\n", "app.py": "KEY = os.environ['SDI_SERVICE_KEY']\n"})
        self.assertEqual(scanner.scan(root), [])

    def test_credentials_are_reported_masked(self):
        root = self.repo({"config.py": f"STRIPE = '{STRIPE}'\nHOOK = '{WEBHOOK}'\n", "key.txt": PEM + "\nabc\n"})
        findings = scanner.scan(root)
        self.assertEqual(len(findings), 3, findings)
        joined = "\n".join(findings)
        self.assertNotIn(STRIPE, joined)
        self.assertNotIn(WEBHOOK, joined)
        self.assertIn("config.py:1: stripe live/test secret key", joined)

    def test_untracked_files_are_not_release_source(self):
        root = self.repo({"README.md": "ok\n"})
        (root / "local.txt").write_text(STRIPE)
        self.assertEqual(scanner.scan(root), [])

    def test_tracked_env_file_and_binary_skip(self):
        root = self.repo({".env": "A=1\n", ".env.example": "A=\n", "art.png": b"\x89PNG\0" + STRIPE.encode()})
        self.assertEqual(scanner.scan(root), [".env: environment file is tracked"])

    def test_plist_values_must_be_substitutions(self):
        plist = {"SUPABASE_URL": "$(SUPABASE_URL)", "SUPABASE_PUBLISHABLE_KEY": "pk-literal", "STRIPE_SECRET_KEY": "$(X)"}
        root = self.repo({"StickDeathInfinity/Info.plist": plistlib.dumps(plist)})
        findings = scanner.scan(root)
        self.assertIn("StickDeathInfinity/Info.plist: SUPABASE_PUBLISHABLE_KEY is not a $(SUPABASE_PUBLISHABLE_KEY) build substitution", findings)
        self.assertIn("StickDeathInfinity/Info.plist: server-only setting STRIPE_SECRET_KEY in the app bundle", findings)

    def test_android_build_cannot_name_server_settings(self):
        root = self.repo({"android/gradle.properties": "sdi.serviceRoleKey=$SERVICE_KEY\n"})
        self.assertEqual(scanner.scan(root), ["android/gradle.properties:1: server-only setting named in the Android build"])

    def test_cli_exit_status(self):
        root = self.repo({"bad.txt": STRIPE})
        self.assertEqual(scanner.main(["--root", str(root)]), 1)
        clean = self.repo({"ok.txt": "fine"})
        self.assertEqual(scanner.main(["--root", str(clean)]), 0)

    def test_repository_release_source_is_clean(self):
        self.assertEqual(scanner.scan(scanner.ROOT), [])


if __name__ == "__main__":
    unittest.main()

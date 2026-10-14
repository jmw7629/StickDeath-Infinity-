#!/usr/bin/env python3
"""Secret-leak and client-boundary check on the exact release source (#238, #256).

Scans every file tracked at the current commit (``git ls-files``; untracked and
ignored files are not release source) for credential-shaped values, and checks the
client build definitions keep provider configuration as build-time substitutions.
It prints the commit it examined and one line per finding, with the value masked;
the matched value itself is never printed. Exit status 1 means at least one finding.

This is a pattern scan: it finds the common credential formats listed below and
cannot prove that no secret exists. Rotation of anything it finds is an owner step
(docs/SECURITY_CREDENTIALS.md); deleting the line does not un-leak a pushed value.

    python3 scripts/backend/scan_release_secrets.py [--root PATH]
"""
from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# (name, pattern). Patterns match the credential's own format, not variable names.
PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("stripe live/test secret key", re.compile(r"\b[sr]k_(?:live|test)_[0-9A-Za-z]{16,}")),
    ("stripe webhook secret", re.compile(r"\bwhsec_[0-9A-Za-z]{16,}")),
    ("private key block", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----")),
    ("aws access key id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("github token", re.compile(r"\b(?:gh[pousr]_[0-9A-Za-z]{30,}|github_pat_[0-9A-Za-z_]{40,})")),
    ("google api key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("google oauth client secret", re.compile(r"\bGOCSPX-[0-9A-Za-z_\-]{20,}")),
    ("slack token", re.compile(r"\bxox[abprs]-[0-9A-Za-z\-]{10,}")),
    ("openai-style key", re.compile(r"\bsk-(?:proj-|ant-)?[0-9A-Za-z_\-]{32,}")),
    ("supabase secret key", re.compile(r"\bsb_secret_[0-9A-Za-z_\-]{16,}")),
    ("jwt", re.compile(r"\beyJ[0-9A-Za-z_\-]{10,}\.eyJ[0-9A-Za-z_\-]{10,}\.[0-9A-Za-z_\-]{10,}")),
]
# Files that legitimately describe these formats (this scanner and its test).
SELF = {"scripts/backend/scan_release_secrets.py", "scripts/backend/test_scan_release_secrets.py"}
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".m4a", ".mp3", ".wav", ".caf", ".mp4", ".mov",
                   ".pdf", ".ttf", ".otf", ".woff", ".woff2", ".ico", ".zip", ".jar", ".keystore", ".car"}
# Reviewed synthetic fixtures: (path, finding label, text the line must also contain).
# Each is a redaction self-test value, not a credential. Keep this list short.
ALLOWED_FIXTURES = {
    ("bridge/runner.py", "github token", "abcdefghijklmnopqrstuvwxyz"),
    # Split so this allowlist entry does not itself look like a key block to diff scanners.
    ("bridge/runner.py", "private key block", '"-----BEGIN ' + 'PRIVATE KEY-----\\nsecret\\n'),
}
# Client build definitions whose provider settings must stay $(...) substitutions.
PLIST_SUBSTITUTED = ("SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "SPATTER_BACKEND_URL", "SDI_OAUTH_PROVIDERS", "SDI_MICROSOFT_TENANT")
FORBIDDEN_CLIENT_KEYS = re.compile(r"service_role|SERVICE_KEY|STRIPE_SECRET|WEBHOOK_SECRET|CLIENT_SECRET|REFRESH_TOKEN|PRIVATE_KEY", re.I)


def tracked_files(root: Path) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], check=True, capture_output=True).stdout
    return [name for name in out.decode().split("\0") if name]


def head(root: Path) -> str:
    result = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True)
    return result.stdout.strip() or "unknown"


def mask(value: str) -> str:
    return value[:4] + "…" + f"({len(value)} chars)"


def scan_text(name: str, text: str) -> list[str]:
    findings = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for label, pattern in PATTERNS:
            for match in pattern.finditer(line):
                if any(path == name and allowed == label and marker in line for path, allowed, marker in ALLOWED_FIXTURES):
                    continue
                findings.append(f"{name}:{lineno}: {label} {mask(match.group(0))}")
    return findings


def check_plist(root: Path) -> list[str]:
    path = root / "StickDeathInfinity/Info.plist"
    if not path.exists():
        return []
    plist = plistlib.loads(path.read_bytes())
    findings = []
    for key in PLIST_SUBSTITUTED:
        value = plist.get(key)
        if value is not None and value != f"$({key})":
            findings.append(f"StickDeathInfinity/Info.plist: {key} is not a $({key}) build substitution")
    for key in plist:
        if FORBIDDEN_CLIENT_KEYS.search(key):
            findings.append(f"StickDeathInfinity/Info.plist: server-only setting {key} in the app bundle")
    return findings


def check_android(root: Path) -> list[str]:
    findings = []
    for relative in ("android/app/build.gradle.kts", "android/app/build.gradle", "android/gradle.properties", "android/app/src/main/AndroidManifest.xml"):
        path = root / relative
        if path.exists():
            for lineno, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                if FORBIDDEN_CLIENT_KEYS.search(line):
                    findings.append(f"{relative}:{lineno}: server-only setting named in the Android build")
    return findings


def scan(root: Path) -> list[str]:
    findings: list[str] = []
    for name in tracked_files(root):
        if name in SELF or Path(name).suffix.lower() in BINARY_SUFFIXES:
            continue
        path = root / name
        if not path.is_file():
            continue
        data = path.read_bytes()
        if b"\0" in data[:4096]:
            continue
        findings.extend(scan_text(name, data.decode("utf-8", errors="replace")))
        if re.search(r"(^|/)\.env(\.|$)", name) and not name.endswith((".example", ".sample", ".template")):
            findings.append(f"{name}: environment file is tracked")
    findings.extend(check_plist(root))
    findings.extend(check_android(root))
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    findings = scan(args.root)
    print(f"SOURCE_COMMIT={head(args.root)}")
    for finding in findings:
        print("FINDING " + finding)
    print(f"RELEASE_SECRET_SCAN={'FAIL' if findings else 'PASS'} ({len(findings)} findings; pattern scan, not a proof of absence)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())

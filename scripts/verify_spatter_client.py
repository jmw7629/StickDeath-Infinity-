#!/usr/bin/env python3
"""Focused source/integration gate; not a substitute for the native Xcode build."""
from pathlib import Path
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def git(*args: str) -> str:
    return subprocess.run(['git', '-C', str(ROOT), *args], check=True,
                          capture_output=True, text=True, timeout=30).stdout

def main() -> None:
    base = os.environ.get('BASE_SHA', 'HEAD')
    if base != 'HEAD' and not re.fullmatch(r'[0-9a-fA-F]{40}', base):
        raise ValueError('BASE_SHA must be an exact commit SHA')
    git('rev-parse', '--verify', base + '^{commit}')
    tracked = set(git('ls-files').splitlines())
    required = [
        'StickDeathInfinity/App/AppConfig.swift',
        'StickDeathInfinity/App/SpatterBackendClient.swift',
        'Tests/SpatterClient/main.swift',
        '.github/workflows/spatter-client-verify.yml',
    ]
    for path in required:
        if path not in tracked or not (ROOT / path).is_file():
            raise ValueError('Required tracked file absent: ' + path)
    forbidden = re.compile(
        r'https://(?:api\.openai\.com|text\.pollinations\.ai|'
        r'generativelanguage\.googleapis\.com|api\.anthropic\.com)\b|'
        r'\b(?:openAIKey|geminiKey|openAIAPIKey|geminiAPIKey|superuserEmails)\b', re.I)
    bad = []
    for path in sorted(tracked):
        if path.startswith('StickDeathInfinity/') and path.endswith('.swift'):
            if forbidden.search((ROOT / path).read_text()):
                bad.append(path)
    if bad:
        raise ValueError('Forbidden client-provider/admin contract in: ' + ', '.join(bad))
    app = ROOT / 'StickDeathInfinity'
    service = (app / 'Services/Spatter/SpatterService.swift').read_text()
    brain = (app / 'AI/SpatterBrainLoader.swift').read_text()
    auth = (app / 'Services/Auth/AuthService.swift').read_text()
    config = (app / 'App/AppConfig.swift').read_text()
    checks = {
        'service uses shared boundary': 'SpatterBackendClient(' in service,
        'embedded knowledge retained': 'SpatterKnowledgeBase.buildContext' in service,
        'runtime knowledge retained': '.from("spatter_knowledge")' in service,
        'no second service HTTP client': 'URLSession' not in service,
        'brain routes to same service': 'SpatterService.shared.chat' in brain,
        'brain retains local lookup': 'brain.getResponse(for:' in brain,
        'no second brain HTTP client': 'URLSession' not in brain,
        'server-owned UI role hint': 'appMetadata["role"]' in auth,
        'config reads public bundle value': 'Bundle.main.infoDictionary' in config,
        'no mutable URL slot': 'static var backendURL: URL? {' in config,
    }
    for name, ok in checks.items():
        if not ok:
            raise ValueError('Integration check failed: ' + name)
    ensure_profile = auth.split('private func ensureProfile(', 1)[1].split('// MARK:', 1)[0]
    if re.search(r'"role"\s*:', ensure_profile):
        raise ValueError('Profile upsert must not assign privileged roles')
    if service.index('guard let sessionToken') > service.index('let supabaseKnowledge'):
        raise ValueError('Session must be checked before runtime knowledge transport')
    prompt = re.compile(r'private let systemPrompt = """(.*?)\n    """', re.S)
    original = git('show', base + ':StickDeathInfinity/Services/Spatter/SpatterService.swift')
    if prompt.search(service).group(1) != prompt.search(original).group(1):
        raise ValueError('Original Spatter personality/knowledge prompt changed')
    pbx = (ROOT / 'StickDeathInfinity.xcodeproj/project.pbxproj').read_text()
    if pbx.count('SpatterBackendClient.swift in Sources') != 2:
        raise ValueError('Backend client must have exactly one Sources entry and build file')
    if 'SpatterBackendClient.swift */,' not in pbx:
        raise ValueError('Backend client is missing from the App project group')
    diff = git('diff', '--unified=0', base, '--')
    added = '\n'.join(line[1:] for line in diff.splitlines() if line.startswith('+') and not line.startswith('+++'))
    secrets = re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|sk-(?:proj-)?[A-Za-z0-9_-]{30,}|'
                         r'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})|'
                         r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')
    if secrets.search(added):
        raise ValueError('Potential credential in added diff (value withheld)')
    git('diff', '--check', base, '--')
    print('SPATTER_SOURCE_SECURITY=PASS')
    print('SPATTER_INTEGRATION_REFERENCES=PASS')
    print('DIFF_CHECK=PASS')
    print('Native compilation is evaluated separately by the Xcode job.')

if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.SubprocessError, OSError, IndexError, AttributeError) as error:
        print('SPATTER_SOURCE_SECURITY=FAIL: ' + str(error), file=sys.stderr)
        sys.exit(1)

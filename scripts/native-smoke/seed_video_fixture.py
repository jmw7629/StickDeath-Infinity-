"""Generate and seed one original video after the caller verifies the CI simulator."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


def seed_video_fixture(udid: str, output: Path) -> None:
    if os.environ.get('GITHUB_ACTIONS') != 'true' or str(uuid.UUID(udid)).lower() != udid.lower():
        raise ValueError('Use the explicit authorized CI simulator')
    if output.is_symlink() or not output.is_dir() or not output.resolve().is_relative_to(Path(os.environ['RUNNER_TEMP']).resolve()):
        raise ValueError('Use the isolated runner-temp evidence directory')
    folder = output / 'video-fixture'
    folder.mkdir(mode=0o700, exist_ok=False)
    repo = Path(__file__).resolve().parents[2]
    movie = folder / 'SDI-generated-video-fixture.mov'
    compiler = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', *[str(repo / p) for p in [
        'StickDeathInfinity/Services/StudioImageImportService.swift',
        'StickDeathInfinity/Services/StudioImageProviderFile.swift',
        'StickDeathInfinity/Services/StudioVideoFrameImportService.swift',
        'Tests/StudioVideoFrameImport/Fixtures.swift',
        'scripts/native-smoke/GenerateVideoFixture.swift']], '-o', str(folder / 'generate-video')]
    records = []
    report = {'simulatorUDID': udid, 'source': 'Original generated H264, variable timestamps, 90-degree orientation',
              'route': 'System Photos library; actual video-only PHPicker selection required', 'attempts': 1, 'status': 'running'}
    try:
        # Run 37557518936 exhausted the 60s cold macOS fixture compiler
        # budget before generation or Photos import began. Keep one attempt;
        # this allocation stays inside the existing native job build budget.
        for name, command, timeout in [('compile', compiler, 180),
            ('generate', [str(folder / 'generate-video'), str(movie)], 45),
            ('addmedia', ['xcrun', 'simctl', 'addmedia', udid, str(movie)], 120)]:
            began = time.monotonic()
            entry = {'stage': name, 'timeoutSeconds': timeout}; records.append(entry)
            try:
                with (folder / (name + '.log')).open('xb') as log:
                    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
                entry['exitCode'] = result.returncode
                if result.returncode: raise subprocess.CalledProcessError(result.returncode, command)
                if name == 'generate':
                    data = movie.read_bytes()
                    if not 0 < len(data) <= 16 * 1024 * 1024: raise ValueError('Generated video exceeds the importer limit')
                    report.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            finally:
                entry['seconds'] = time.monotonic() - began
        report['status'] = 'passed'
    except Exception as error:
        report.update(status='failed', failureClass=type(error).__name__)
        raise
    finally:
        report['stages'] = records
        (folder / 'result.json').write_text(json.dumps(report, indent=2) + '\n')

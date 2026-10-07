"""Generate and seed one original video after the caller verifies the CI simulator."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

from seed_diagnostics import Evidence, collect_failure, result_projection, run_bounded


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
                if name == 'addmedia':
                    evidence = Evidence(udid, folder, namespace='video')
                    try:
                        # Exactly one mutation, unchanged120s work budget. The
                        # extra second is only for reaping this owned child.
                        result = run_bounded(command, began + timeout + 1,
                                             work_deadline=began + timeout)
                        entry['supervision'] = result_projection(result)
                        entry['exitCode'] = result.returncode
                        try:
                            evidence.json('image-seed-command.json', {'stage': name, 'result': entry['supervision']})
                        except Exception as write_error:
                            entry['commandEvidenceWriteErrorClass'] = type(write_error).__name__
                            print(json.dumps({'videoSeedCommandEvidence': 'unavailable',
                                'errorClass': type(write_error).__name__,
                                'actualCommandResultPreserved': True}), flush=True)
                        if result.spawn_error:
                            raise OSError('Video addmedia could not be started')
                        if result.timed_out:
                            raise subprocess.TimeoutExpired(command, timeout)
                        if not result.reaped:
                            raise OSError('Video addmedia child could not be reaped')
                        if result.returncode != 0:
                            raise subprocess.CalledProcessError(result.returncode, command)
                    except Exception:
                        # Read-only30sdiagnostics never retry the import and
                        # cannot replace or downgrade its original failure.
                        try:
                            collect_failure(evidence, udid, 'video-addmedia')
                        except Exception as diagnostic_error:
                            print(json.dumps({'videoSeedDiagnostics': 'unavailable',
                                'errorClass': type(diagnostic_error).__name__,
                                'originalSeedingFailurePreserved': True}), flush=True)
                        raise
                    finally:
                        evidence.close()
                else:
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
        original_failure = sys.exc_info()[1]
        try:
            (folder / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        except Exception as report_error:
            if original_failure is None:
                raise
            print(json.dumps({'videoSeedResultEvidence': 'unavailable',
                'errorClass': type(report_error).__name__,
                'originalSeedingFailurePreserved': True}), flush=True)

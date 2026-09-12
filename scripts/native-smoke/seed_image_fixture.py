#!/usr/bin/env python3
"""Add an original generated still to the explicit ephemeral CI simulator."""
import argparse
import hashlib
import json
import os
import pathlib
import struct
import subprocess
import zlib
import uuid
import time

from seed_diagnostics import Evidence, collect_failure, result_projection, run_bounded


def make_png() -> bytes:
    width, height = 96, 64
    colors = [(255, 0, 0, 255), (0, 0, 255, 255),
              (0, 255, 0, 255), (255, 255, 0, 255)]
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(colors[(2 if y >= height // 2 else 0) + (1 if x >= width // 2 else 0)])
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"sRGB", b"\0") + chunk(b"IDAT", zlib.compress(bytes(rows))) + chunk(b"IEND", b""))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise ValueError("Image fixture seeding is limited to the approved ephemeral CI runner")
    output = args.output.resolve()
    if not output.is_dir() or not output.is_relative_to(pathlib.Path(os.environ["RUNNER_TEMP"]).resolve()):
        raise ValueError("Use an existing isolated runner-temp evidence directory")
    # CoreSimulator can still be busy immediately after bootstatus succeeds.
    # Keep fresh identity/state verification, with a bounded cold-start budget.
    inventory = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], timeout=90))
    selected = [d for runtime, devices in inventory["devices"].items() if ".iOS-" in runtime
                for d in devices if d["udid"] == args.udid and d.get("isAvailable") and d["state"] == "Booted"]
    if len(selected) != 1:
        raise ValueError("Use the explicit available booted iOS test simulator")
    seed_verified_fixture(args.udid, output)


def seed_verified_fixture(udid: str, output: pathlib.Path) -> None:
    """Seed only after the caller verifies the explicit available, booted iOS target.

    The recorder performs native bootstatus immediately before this call; the
    standalone entry point verifies fresh available/Booted inventory above.
    """
    evidence = Evidence(udid, output)
    try:
        data = make_png()
        fixture = evidence.path / "SDI-generated-image-fixture.png"
        evidence.write(fixture.name, data)
        report = {"simulatorUDID": udid, "file": fixture.name, "bytes": len(data),
                  "sha256": hashlib.sha256(data).hexdigest(), "width": 96, "height": 64,
                  "source": "Original generated four-color UI fixture; no third-party corpus",
                  "route": "System Photos library; the app must select through PHPicker"}
        evidence.json('image-seed-start.json', {**report, 'stage': 'addmedia',
                      'timeoutSeconds': 60, 'ownership': 'Caller already verified the explicit available, booted iOS target'})
        command = ["xcrun", "simctl", "addmedia", udid, str(fixture)]
        started = time.monotonic()
        result = None
        try:
            evidence.check()
            # Same 60-second operation gate. One further second only bounds
            # reaping the owned timed-out child; there is never a second seed.
            result = run_bounded(command, started + 61, work_deadline=started + 60)
            if result.spawn_error:
                raise OSError('The addmedia command could not be started')
            if result.timed_out:
                raise subprocess.TimeoutExpired(command, 60)
            if result.returncode != 0:
                raise subprocess.CalledProcessError(result.returncode, command)
        except Exception:
            # Secondary evidence errors never replace the actual seeding error.
            try:
                evidence.json('image-seed-command.json', {'stage': 'addmedia',
                              'result': result_projection(result) if result else {'collectionFailed': True}})
                collect_failure(evidence, udid, 'addmedia')
            except Exception as diagnostic_error:
                print(json.dumps({'imageSeedDiagnostics': 'unavailable',
                                  'errorClass': type(diagnostic_error).__name__,
                                  'originalSeedingFailurePreserved': True}), flush=True)
            raise
        evidence.json('image-seed-command.json', {'stage': 'addmedia', 'result': result_projection(result)})
        evidence.json('image-fixture.json', report)
    finally:
        evidence.close()


if __name__ == "__main__":
    main()

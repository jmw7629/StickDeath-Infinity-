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
    inventory = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], timeout=30))
    selected = [d for runtime, devices in inventory["devices"].items() if ".iOS-" in runtime
                for d in devices if d["udid"] == args.udid and d.get("isAvailable") and d["state"] == "Booted"]
    if len(selected) != 1:
        raise ValueError("Use the explicit available booted iOS test simulator")
    data = make_png()
    fixture = output / "SDI-generated-image-fixture.png"
    with fixture.open("xb") as handle:
        handle.write(data)
    subprocess.run(["xcrun", "simctl", "addmedia", args.udid, str(fixture)], check=True, timeout=60)
    report = {"simulatorUDID": args.udid, "file": fixture.name, "bytes": len(data),
              "sha256": hashlib.sha256(data).hexdigest(), "width": 96, "height": 64,
              "source": "Original generated four-color UI fixture; no third-party corpus",
              "route": "System Photos library; the app must select through PHPicker"}
    with (output / "image-fixture.json").open("x") as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Check the committed `.sdi` fixtures: envelope integrity, agreement with `expectations.json`
and byte-identity with `make_fixtures.py`. Exit code 1 on any mismatch. Run with `python3 -I`."""
import base64
import hashlib
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MAGIC = b"SDIPROJECT000001\n"


def decode(data):
    header = len(MAGIC) + 8 + 32
    if data[:len(MAGIC)] != MAGIC or len(data) < header:
        raise ValueError("bad magic or truncated header")
    (count,) = struct.unpack(">Q", data[len(MAGIC):len(MAGIC) + 8])
    payload = data[header:]
    if count != len(payload):
        raise ValueError("payload length mismatch")
    if hashlib.sha256(payload).digest() != data[len(MAGIC) + 8:header]:
        raise ValueError("digest mismatch")
    root = json.loads(payload)
    if root["version"] != 1:
        raise ValueError("unsupported Revision version")
    project = root["project"]
    archive = json.loads(base64.b64decode(project["editableDocumentData"]))
    document = archive["document"]
    meta = project["metadata"]
    if meta["frameCount"] != len(document["frames"]) or meta["layerCount"] != len(document["layers"]) or \
            len(project["frames"]) != len(document["frames"]) or meta["id"] != document["id"] != project["id"]:
        raise ValueError("metadata does not match the editable document")
    return document


def verify():
    sys.path.insert(0, str(ROOT))
    import make_fixtures  # noqa: E402  (same directory, trusted repository source)
    expected = json.loads((ROOT / "expectations.json").read_text(encoding="utf-8"))
    generated = make_fixtures.fixtures()
    problems = []
    if set(expected) != set(generated):
        problems.append(f"expectations {sorted(expected)} differ from generator {sorted(generated)}")
    for name, info in expected.items():
        path = ROOT / "assets" / name
        if not path.is_file():
            problems.append(f"{name}: missing"); continue
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != info["sha256"] or len(data) != info["bytes"]:
            problems.append(f"{name}: bytes differ from expectations.json")
        if name in generated and generated[name][0] != data:
            problems.append(f"{name}: differs from make_fixtures.py output; regenerate or review")
        try:
            document = decode(data)
        except (ValueError, KeyError, json.JSONDecodeError) as error:
            problems.append(f"{name}: {error}"); continue
        if document["schemaVersion"] != info["schemaVersion"]:
            problems.append(f"{name}: schemaVersion {document['schemaVersion']} != {info['schemaVersion']}")
        if info["android"] == "accept":
            if len(document["layers"]) != info["layers"] or len(document["frames"]) != info["frames"] or \
                    sum(len(f["elements"]) for f in document["frames"]) != info["elements"]:
                problems.append(f"{name}: structure differs from expectations")
        elif not info.get("reason"):
            problems.append(f"{name}: a rejected fixture needs a reason")
    return problems


if __name__ == "__main__":
    issues = verify()
    for issue in issues:
        print("FAIL", issue)
    if not issues:
        print(f"SDI_FIXTURES=PASS ({len(json.loads((ROOT / 'expectations.json').read_text()))} fixtures)")
    sys.exit(1 if issues else 0)

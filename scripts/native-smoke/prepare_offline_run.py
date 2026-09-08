#!/usr/bin/env python3
"""Validate a built test app, then write a separate xctestrun profile.

Never edits the built app or accepts a configured backend. This does not measure
network traffic; the independent production configuration tests remain required.
"""
from __future__ import annotations
import argparse
import json
import pathlib
import plistlib
import re

PUBLIC_SETTINGS = (
    "SPATTER_BACKEND_URL", "SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY",
    "SUPABASE_ANON_KEY", "LIVEKIT_WS_URL",
)


def prepare(source: pathlib.Path, destination: pathlib.Path, commit: str) -> dict:
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("An exact source commit is required")
    if source.resolve() == destination.resolve() or destination.exists():
        raise ValueError("Use a new profile output path; do not overwrite the generated profile")
    document = plistlib.loads(source.read_bytes())
    targets = [(target.get("BlueprintName"), target) for config in document.get("TestConfigurations", [])
               for target in config.get("TestTargets", [])]
    if not targets:  # Xcode format 1 (no test plan)
        targets = [(name, value) for name, value in document.items()
                   if isinstance(value, dict) and "TestBundlePath" in value]
    selected = [target for name, target in targets if name == "StickDeathInfinityUITests"]
    if len(selected) != 1:
        raise ValueError("Expected exactly one StickDeathInfinityUITests target")
    target = selected[0]
    root = source.parent.resolve()
    def resolve_product(value: object, suffix: str, host: pathlib.Path | None = None) -> pathlib.Path:
        expanded = str(value or "").replace("__TESTROOT__", str(root))
        if host is not None:
            expanded = expanded.replace("__TESTHOST__", str(host))
        if not expanded or "__" in expanded:
            raise ValueError("Unresolved built product path")
        product = pathlib.Path(expanded).resolve()
        if not product.is_relative_to(root) or product.suffix != suffix or not product.is_dir():
            raise ValueError("Built app, runner and test bundle must remain inside these isolated build products")
        return product
    app = resolve_product(target.get("UITargetAppPath"), ".app")
    host = resolve_product(target.get("TestHostPath"), ".app")
    resolve_product(target.get("TestBundlePath"), ".xctest", host)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.willisnmb.stickdeathinfinity":
        raise ValueError("Unexpected app identity")
    configured = [key for key in PUBLIC_SETTINGS if str(info.get(key, "")).strip()]
    if configured:
        raise ValueError("Offline smoke requires empty public build settings: " + ", ".join(configured))
    target.setdefault("EnvironmentVariables", {}).update({
        "SDI_SMOKE_OFFLINE_PREFLIGHT": "1", "SDI_SMOKE_SOURCE_COMMIT": commit,
    })
    # Preserve Xcode's original profiles and paths. The copy stays in the same
    # directory so __TESTROOT__ continues to resolve to the actual build products.
    if destination.parent.resolve() != source.parent.resolve():
        raise ValueError("The prepared profile must be beside the generated profile")
    destination.write_bytes(plistlib.dumps(document))
    return {"sourceCommit": commit, "appBundleIdentifier": info["CFBundleIdentifier"],
            "emptyPublicSettings": list(PUBLIC_SETTINGS), "networkRequestsObserved": None,
            "networkMeasurementStatus": "Not measured by this UI preflight"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("destination", type=pathlib.Path)
    parser.add_argument("commit")
    parser.add_argument("--metadata", type=pathlib.Path, required=True)
    args = parser.parse_args()
    metadata = prepare(args.source, args.destination, args.commit)
    args.metadata.write_text(json.dumps(metadata, indent=2) + "\n")
    print("OFFLINE_BUILT_APP_CONFIG_PREFLIGHT=PASS")

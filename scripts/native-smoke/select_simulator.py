#!/usr/bin/env python3
"""Select an existing, available iPhone simulator on the ephemeral CI runner."""
import json
import os
import re
import subprocess

if os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("CI simulator selection is restricted to the ephemeral runner")
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"], timeout=30))["runtimes"]
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], timeout=30))["devices"]
choices = []
for runtime in runtimes:
    if ".iOS-" not in runtime["identifier"] or not runtime.get("isAvailable"):
        continue
    version = tuple(int(part) for part in runtime["version"].split("."))
    for device in devices.get(runtime["identifier"], []):
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            model = re.search(r"iPhone (\d+)", device["name"])
            number = int(model.group(1)) if model else 0
            preferred = device["name"] == "iPhone 16 Pro"
            choices.append((preferred, version, number, device["name"], device["udid"]))
if not choices:
    raise SystemExit("No available installed iOS phone simulator; no runtime was downloaded")
print(sorted(choices, reverse=True)[0][-1])

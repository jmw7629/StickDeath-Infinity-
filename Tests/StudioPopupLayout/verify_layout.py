"""Compile the exact production popup helper with a real macOS SwiftUI host.

The helper is file-private in a UIKit-dependent panel. Extract its verbatim
source (not a second implementation) into the harness compilation unit. The
full native target separately checks its original source membership and context.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--swiftc", default="swiftc")
parser.add_argument("--sdk")
parser.add_argument("--output-directory", required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
panel = root / "StickDeathInfinity/Views/Studio/Panels/ToolSettingsPanel.swift"
harness = Path(__file__).with_name("Harness.swift")
source = panel.read_text()
start_marker = "private struct ToolSettingsContentHeight:"
end_marker = "\nprivate enum StudioImagePlacementField:"
assert source.count(start_marker) == source.count(end_marker) == 1
start = source.index(start_marker)
end = source.index(end_marker, start)
helper = source[start:end]
output = Path(args.output_directory)
output.mkdir(parents=True, exist_ok=False)
unit = output / "ActualPopupLayout.swift"
unit.write_text(harness.read_text() + "\n" + helper)
command = [args.swiftc, "-parse-as-library", "-module-cache-path", str(output / "module-cache")]
if args.sdk:
    command += ["-sdk", args.sdk]
command += [str(unit), "-o", str(output / "popup-layout-tests")]
env = dict(os.environ, TMPDIR=str(output) + "/")
results = {"productionFileSHA256": hashlib.sha256(panel.read_bytes()).hexdigest(),
           "productionHelperSHA256": hashlib.sha256(helper.encode()).hexdigest(),
           "harnessSHA256": hashlib.sha256(harness.read_bytes()).hexdigest()}
for name, cmd, timeout in [("compile", command, 240), ("run", [str(output / "popup-layout-tests")], 30)]:
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
    (output / (name + ".log")).write_text(result.stdout + result.stderr)
    results[name + "ExitCode"] = result.returncode
    (output / "result.json").write_text(json.dumps(results, indent=2) + "\n")
    print(result.stdout + result.stderr, flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)

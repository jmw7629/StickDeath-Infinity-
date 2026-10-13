#!/usr/bin/env python3
"""Compile and run the long-project export benchmark harness (#202) on macOS.

The harness (Tests/StudioExportBenchmark/main.swift) drives the production
movie and PNG exporters with a generated document. This script reuses the
exact production source list of the CI step that compiles
Tests/StudioMovieExport/main.swift, swapping only the test file, so the
benchmark never compiles a stand-in exporter.

    python3 scripts/media/run_export_benchmark.py 1440 1080 1920 24
    python3 scripts/media/run_export_benchmark.py 1440 1080 1920 24 png

Requires Xcode command line tools; on Linux it prints the command it would run
and exits 3 (the numbers must be recorded as DEFERRED until a Mac runs them).
"""
from __future__ import annotations

import platform
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/spatter-client-verify.yml"
TEST_SOURCE = "Tests/StudioMovieExport/main.swift"
BENCHMARK_SOURCE = "Tests/StudioExportBenchmark/main.swift"


def production_sources() -> list[str]:
    text = WORKFLOW.read_text().replace("\\\n", " ")
    for command in re.findall(r"(?m)^\s*swiftc\s+[^\n]+", text):
        tokens = shlex.split(command)
        sources = [token for token in tokens if token.endswith(".swift")]
        if TEST_SOURCE in sources:
            return [BENCHMARK_SOURCE if source == TEST_SOURCE else source for source in sources]
    raise SystemExit(f"no CI step compiles {TEST_SOURCE}")


def main(argv: list[str]) -> int:
    if len(argv) < 5:
        print(__doc__)
        return 2
    sources = production_sources()
    for source in sources:
        if not (ROOT / source).is_file():
            print(f"missing source {source}")
            return 2
    output = Path(tempfile.gettempdir()) / "sdi-export-benchmark"
    compile_command = ["swiftc", "-swift-version", "5", "-parse-as-library", "-O", *sources, "-o", str(output)]
    run_command = [str(output), *argv[1:]]
    if platform.system() != "Darwin":
        print("EXPORT_BENCHMARK=DEFERRED (not run) this harness needs macOS with AVFoundation; would run:")
        print("  " + " ".join(shlex.quote(part) for part in compile_command))
        print("  " + " ".join(shlex.quote(part) for part in run_command))
        return 3
    subprocess.run(compile_command, cwd=ROOT, check=True)
    completed = subprocess.run(run_command, cwd=ROOT)
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv))

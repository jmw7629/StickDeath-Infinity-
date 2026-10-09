#!/usr/bin/env python3
"""Fail early on broken standalone Swift source lists; never substitutes for Swift compilation."""
from pathlib import Path
import re
import shlex

ROOT = Path(__file__).resolve().parents[1]
# These production types refer to each other directly. Keep the real catalogue
# in tests that compile preview sessions; a test-only stand-in would hide wiring.
DEPENDENCIES = {
    "StickDeathInfinity/Services/StudioAudioPreviewSession.swift": {
        "StickDeathInfinity/Services/StudioSoundCatalogue.swift",
        "StickDeathInfinity/Services/StudioAudioImportService.swift",
    },
    "StickDeathInfinity/Services/StudioSoundCatalogue.swift": {
        "StickDeathInfinity/Services/StudioAudioImportService.swift",
    },
}


def verify(workflow: str, root: Path = ROOT) -> int:
    commands = re.findall(r"(?m)^\s*swiftc\s+[^\n]+", workflow.replace("\\\n", " "))
    if not commands:
        raise ValueError("No standalone Swift compilation commands found")
    for index, command in enumerate(commands, 1):
        sources = [token for token in shlex.split(command) if token.endswith(".swift")]
        if not sources:
            # Version diagnostics do not compile source.
            if shlex.split(command) == ["swiftc", "--version"]:
                continue
            raise ValueError(f"Swift command {index} has no explicit source list")
        if len(sources) != len(set(sources)):
            raise ValueError(f"Swift command {index} repeats a source file")
        for source in sources:
            path = root / source
            if Path(source).is_absolute() or ".." in Path(source).parts or not path.is_file():
                raise ValueError(f"Swift command {index} has an invalid source: {source}")
            missing = DEPENDENCIES.get(source, set()) - set(sources)
            if missing:
                raise ValueError(f"Swift command {index}: {source} requires {', '.join(sorted(missing))}")
    return len(commands)


if __name__ == "__main__":
    count = verify((ROOT / ".github/workflows/spatter-client-verify.yml").read_text())
    print(f"NATIVE_COMPILE_SOURCE_LISTS=PASS ({count} commands; native compilation remains required)")

#!/usr/bin/env python3
"""Convert a cached issue directory into the JSON array audit_queue.py reads (#128).

The cache layout is one Markdown file per issue, ``<number>.md``::

    # #264 [SDI QA01] Verify accessibility and adaptive layouts across the native app
    labels: sdi:later,P1

    <body …>

An optional ``state: open|closed`` line in that header is honoured. Without it
every cached issue is reported as **open**, because the cache only holds issues
that were open when it was taken; the adapter records that assumption in the
JSON (``"stateAssumed": true``) so a report can say so. An optional
``INDEX.tsv`` (``number<TAB>title<TAB>labels…``) is used only to warn about
files missing from the directory. The adapter reads files and prints JSON; it
never contacts GitHub or edits anything.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TITLE = re.compile(r"^#\s+#(\d+)\s+(.*)$")
HEADER_KEYS = {"labels", "state"}


def parse_issue(text: str, number_hint: int | None = None) -> dict:
    lines = text.splitlines()
    if not lines:
        raise ValueError("Empty issue file")
    match = TITLE.match(lines[0].strip())
    if not match:
        raise ValueError(f"First line must be '# #<number> <title>', got {lines[0]!r}")
    number = int(match.group(1))
    if number_hint is not None and number != number_hint:
        raise ValueError(f"File name says #{number_hint} but the heading says #{number}")
    header: dict[str, str] = {}
    index = 1
    while index < len(lines):
        line = lines[index].strip()
        key, separator, value = line.partition(":")
        if separator and key.strip().lower() in HEADER_KEYS:
            header[key.strip().lower()] = value.strip()
            index += 1
            continue
        break
    body = "\n".join(lines[index:]).strip("\n")
    labels = [label.strip() for label in header.get("labels", "").split(",") if label.strip()]
    state = header.get("state", "").lower()
    assumed = state == ""
    if assumed:
        state = "open"
    if state not in {"open", "closed"}:
        raise ValueError(f"Issue #{number} has an unknown state {state!r}")
    return {"number": number, "title": match.group(2).strip(), "state": state.upper(),
            "labels": [{"name": label} for label in labels], "body": body,
            "url": f"cache://issues/{number}", "stateAssumed": assumed}


def load_cache(directory: Path) -> tuple[list[dict], list[str]]:
    if not directory.is_dir():
        raise ValueError(f"{directory} is not a directory")
    issues: list[dict] = []
    warnings: list[str] = []
    for path in sorted(directory.glob("*.md"), key=lambda p: (len(p.stem), p.stem)):
        if not path.stem.isdigit():
            continue
        issues.append(parse_issue(path.read_text(encoding="utf-8", errors="replace"), int(path.stem)))
    numbers = {issue["number"] for issue in issues}
    index = directory / "INDEX.tsv"
    if index.is_file():
        for line in index.read_text(encoding="utf-8", errors="replace").splitlines():
            cells = line.split("\t")
            if cells and cells[0].strip().isdigit() and int(cells[0]) not in numbers:
                warnings.append(f"INDEX.tsv lists #{cells[0]} but {cells[0]}.md is missing from the cache")
    if not issues:
        raise ValueError(f"No <number>.md issue files in {directory}")
    return issues, warnings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("cache", type=Path, help="directory of <number>.md files (optional INDEX.tsv)")
    parser.add_argument("--output", type=Path, default=None, help="write the JSON array here instead of stdout")
    arguments = parser.parse_args(argv)
    try:
        issues, warnings = load_cache(arguments.cache)
    except (OSError, ValueError) as error:
        print(f"issue_cache_adapter: {error}", file=sys.stderr)
        return 2
    for warning in warnings:
        print("issue_cache_adapter: " + warning, file=sys.stderr)
    payload = json.dumps(issues, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.write_text(payload, encoding="utf-8")
    else:
        sys.stdout.write(payload)
    assumed = sum(issue["stateAssumed"] for issue in issues)
    print(f"issue_cache_adapter: {len(issues)} issues, {assumed} with state assumed open (no state line)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

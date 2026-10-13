#!/usr/bin/env python3
"""Merge the ``## Ledger`` sections of several agent REPORT.md files (#128).

Each wave-3 report carries one line per assigned issue::

    #264 | DONE-in-source | one-line evidence

Accepted line shapes inside the ``## Ledger`` section (until the next ``## ``
heading): a bare ``#NNN | STATE | evidence`` line, the same with a leading
``- `` or ``* `` bullet, or a Markdown table row ``| #NNN | STATE | evidence |``.
Table separator rows and header rows without an issue number are skipped.

Output is one Markdown table sorted by issue number (then report), followed by
counts per state and a list of issues that different reports rate differently.
The script reads files only; states are reproduced verbatim (``DONE-in-source``,
``DEFERRED-native-verification``, ``OWNER-GATED ⭐``, ``PARTIAL``,
``NOT-STARTED`` or anything else a report wrote).
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

LEDGER_HEADING = re.compile(r"^##\s+Ledger\s*$", re.IGNORECASE)
HEADING = re.compile(r"^##\s+")
ROW = re.compile(r"^\s*(?:[-*]\s+)?\|?\s*#(\d+)\s*\|\s*([^|]+?)\s*(?:\|\s*(.*?))?\s*\|?\s*$")
KNOWN_STATES = ("DONE-in-source", "DEFERRED-native-verification", "OWNER-GATED ⭐", "PARTIAL", "NOT-STARTED")


def ledger_lines(text: str) -> list[str]:
    inside = False
    lines: list[str] = []
    for line in text.splitlines():
        if LEDGER_HEADING.match(line.strip()):
            inside = True
            continue
        if inside and HEADING.match(line):
            break
        if inside:
            lines.append(line)
    return lines


def parse_ledger(text: str, source: str) -> list[dict]:
    entries: list[dict] = []
    for line in ledger_lines(text):
        stripped = line.strip()
        if not stripped or set(stripped) <= set("|-: "):
            continue
        match = ROW.match(line)
        if not match:
            continue
        evidence = (match.group(3) or "").strip()
        if evidence.endswith("|"):
            evidence = evidence[:-1].strip()
        entries.append({"issue": int(match.group(1)), "state": match.group(2).strip(),
                        "evidence": evidence, "source": source})
    return entries


def merge(paths: list[Path]) -> dict:
    entries: list[dict] = []
    missing_ledger: list[str] = []
    for path in paths:
        text = path.read_text(encoding="utf-8", errors="replace")
        found = parse_ledger(text, path.as_posix())
        if not any(LEDGER_HEADING.match(line.strip()) for line in text.splitlines()):
            missing_ledger.append(path.as_posix())
        entries.extend(found)
    entries.sort(key=lambda e: (e["issue"], e["source"]))
    states = Counter(e["state"] for e in entries)
    by_issue: dict[int, set[str]] = defaultdict(set)
    for entry in entries:
        by_issue[entry["issue"]].add(entry["state"])
    conflicts = {issue: sorted(values) for issue, values in sorted(by_issue.items()) if len(values) > 1}
    unknown = sorted({e["state"] for e in entries} - set(KNOWN_STATES))
    return {"entries": entries, "counts": dict(sorted(states.items())), "conflicts": conflicts,
            "reportsWithoutLedger": missing_ledger, "unknownStates": unknown,
            "issueCount": len(by_issue), "entryCount": len(entries)}


def escape(cell: str) -> str:
    return cell.replace("|", "\\|")


def render(result: dict) -> str:
    lines = ["| Issue | State | Evidence | Report |", "| --- | --- | --- | --- |"]
    for entry in result["entries"]:
        lines.append(f"| #{entry['issue']} | {escape(entry['state'])} | {escape(entry['evidence'])} | {escape(entry['source'])} |")
    lines.append("")
    lines.append(f"{result['entryCount']} ledger lines covering {result['issueCount']} issues.")
    lines.append("")
    lines.append("| State | Count |")
    lines.append("| --- | ---: |")
    for state, count in result["counts"].items():
        lines.append(f"| {escape(state)} | {count} |")
    if result["conflicts"]:
        lines.append("")
        lines.append("Issues rated differently by different reports (resolve before publishing):")
        for issue, states in result["conflicts"].items():
            lines.append(f"- #{issue}: " + ", ".join(states))
    if result["unknownStates"]:
        lines.append("")
        lines.append("States outside the common brief vocabulary: " + ", ".join(result["unknownStates"]))
    if result["reportsWithoutLedger"]:
        lines.append("")
        lines.append("Reports without a `## Ledger` section: " + ", ".join(result["reportsWithoutLedger"]))
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("reports", nargs="+", type=Path, help="REPORT.md files to merge")
    parser.add_argument("--output", type=Path, default=None, help="write the Markdown here instead of stdout")
    arguments = parser.parse_args(argv)
    try:
        result = merge(arguments.reports)
    except OSError as error:
        print(f"issue_ledger: {error}", file=sys.stderr)
        return 2
    text = render(result)
    if arguments.output:
        arguments.output.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 1 if result["conflicts"] else 0


if __name__ == "__main__":
    sys.exit(main())

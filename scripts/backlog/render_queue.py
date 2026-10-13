#!/usr/bin/env python3
"""Render a dependency-ordered next queue from an issues export (#128, read-only).

Input is the same JSON array ``audit_queue.py`` reads (gh CLI, REST, or the
output of ``issue_cache_adapter.py``). Output is Markdown:

* a header with the audit facts (counts, cycles, duplicates, missing references);
* a numbered queue of open, non-epic issues in dependency order — an issue is
  listed only after every open blocking dependency present in the export — with
  ties broken by priority label (P0 < P1 < P2 < none), lane (``sdi:next`` before
  unlabelled before ``sdi:later`` before ``sdi:owner-gate``) and number;
* owner-gated items in their own section, epics as tracking-only.

Each row shows its open blockers and any dependency missing from the export,
so a partial export never looks like a cleared dependency. The script creates
no issues and never changes the export. A queue row is a planning fact, not an
acceptance claim.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("sdi_audit_queue", HERE / "audit_queue.py")
audit_queue = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(audit_queue)

PRIORITY = re.compile(r"^P(\d)$")
EPIC_LABEL = "sdi:epic"
OWNER_GATE_LABEL = "sdi:owner-gate"
LATER_LABEL = "sdi:later"


def priority_rank(labels: list[str]) -> int:
    ranks = [int(m.group(1)) for label in labels for m in [PRIORITY.match(label)] if m]
    return min(ranks) if ranks else 9


def lane(labels: list[str]) -> str:
    if OWNER_GATE_LABEL in labels:
        return "owner-gate"
    if audit_queue.NEXT_LABEL in labels:
        return "next"
    if LATER_LABEL in labels:
        return "later"
    return "unlabelled"


LANE_RANK = {"next": 0, "unlabelled": 1, "later": 2, "owner-gate": 3}


def plan(issues: list[dict]) -> dict:
    by_number = {issue["number"]: issue for issue in issues}
    blocking: dict[int, set[int]] = {}
    missing: dict[int, set[int]] = {}
    for issue in issues:
        deps, _ = audit_queue.parse_dependencies(issue["body"])
        deps.discard(issue["number"])
        blocking[issue["number"]] = deps
        missing[issue["number"]] = {d for d in deps if d not in by_number}
    candidates = [i for i in issues if i["state"] == "open" and EPIC_LABEL not in i["labels"]]
    queue_members = {i["number"] for i in candidates if lane(i["labels"]) != "owner-gate"}
    gated = sorted((i for i in candidates if lane(i["labels"]) == "owner-gate"),
                   key=lambda i: (priority_rank(i["labels"]), i["number"]))
    epics = sorted((i for i in issues if i["state"] == "open" and EPIC_LABEL in i["labels"]), key=lambda i: i["number"])

    def open_blockers(number: int) -> list[int]:
        return sorted(d for d in blocking[number] if d in by_number and by_number[d]["state"] == "open")

    def key(number: int) -> tuple:
        labels = by_number[number]["labels"]
        return (priority_rank(labels), LANE_RANK[lane(labels)], number)

    remaining = set(queue_members)
    placed: set[int] = set()
    ordered: list[dict] = []
    while remaining:
        ready = [n for n in remaining if all(b in placed or b not in remaining for b in open_blockers(n))]
        if not ready:
            # A cycle among the remaining items: emit them in key order and say so.
            ready = sorted(remaining, key=key)
            for number in ready:
                ordered.append(_row(by_number[number], open_blockers(number), missing[number], cyclic=True))
            break
        number = min(ready, key=key)
        ordered.append(_row(by_number[number], open_blockers(number), missing[number], cyclic=False))
        placed.add(number)
        remaining.discard(number)
    return {
        "queue": ordered,
        "ownerGated": [_row(i, open_blockers(i["number"]), missing[i["number"]], cyclic=False) for i in gated],
        "epics": [{"number": i["number"], "title": i["title"]} for i in epics],
        "audit": audit_queue.audit(issues),
    }


def _row(issue: dict, blockers: list[int], missing: set[int], cyclic: bool) -> dict:
    return {"number": issue["number"], "title": issue["title"], "priority": priority_rank(issue["labels"]),
            "lane": lane(issue["labels"]), "labels": issue["labels"], "openBlockers": blockers,
            "missingDependencies": sorted(missing), "cyclic": cyclic,
            "stateAssumed": bool(issue.get("stateAssumed"))}


def render(result: dict, source_note: str, limit: int) -> str:
    audit = result["audit"]
    lines = ["# Backlog next queue — dependency ordered", ""]
    if source_note:
        lines += [source_note, ""]
    lines += [f"Export: {audit['issueCount']} issues, {audit['openCount']} open; {audit['nextOpenCount']} open `sdi:next` "
              f"({'within' if audit['queueWithinTarget'] else 'outside'} the 50–100 target). "
              "Inventory and ordering only; nothing here is finished or verified software.", ""]
    cycles = audit["blockingCycles"]
    lines.append("Blocking cycles: " + (", ".join(" -> ".join(f"#{n}" for n in c + c[:1]) for c in cycles) or "none"))
    duplicates = audit["duplicateTitles"]
    lines.append("Duplicate titles: " + ("; ".join(f"{k!r}: " + ", ".join(f"#{n}" for n in v) for k, v in duplicates.items()) or "none"))
    if audit["missingReferences"]:
        lines.append("Dependencies referenced but absent from the export (partial export, listed per row below): "
                     + ", ".join(sorted({f"#{d}" for v in audit["missingReferences"].values() for d in v}, key=lambda s: int(s[1:]))))
    lines.append("")
    queue = result["queue"]
    shown = queue[:limit]
    lines += [f"## Queue ({len(shown)} of {len(queue)} open non-epic items; dependency order, then P0 < P1 < P2, next < later)", "",
              "| # | Issue | P | Lane | Open blockers | Deps not in export | Note |", "| ---: | --- | --- | --- | --- | --- | --- |"]
    for position, row in enumerate(shown, 1):
        note = []
        if row["cyclic"]:
            note.append("in a dependency cycle")
        if row["stateAssumed"]:
            note.append("state assumed open")
        lines.append(f"| {position} | #{row['number']} {row['title']} | {'P' + str(row['priority']) if row['priority'] < 9 else '—'} | {row['lane']} | "
                     f"{', '.join(f'#{b}' for b in row['openBlockers']) or '—'} | {', '.join(f'#{m}' for m in row['missingDependencies']) or '—'} | {'; '.join(note) or '—'} |")
    if len(queue) > limit:
        lines += ["", f"{len(queue) - limit} further open items follow the same ordering and are omitted by the {limit}-row limit."]
    lines += ["", f"## Owner-gated ({len(result['ownerGated'])})", ""]
    if result["ownerGated"]:
        lines += ["| Issue | P | Open blockers |", "| --- | --- | --- |"]
        lines += [f"| #{r['number']} {r['title']} | {'P' + str(r['priority']) if r['priority'] < 9 else '—'} | {', '.join(f'#{b}' for b in r['openBlockers']) or '—'} |" for r in result["ownerGated"]]
    else:
        lines.append("none")
    lines += ["", f"## Epics (tracking only, {len(result['epics'])})", ""]
    lines += [f"- #{e['number']} {e['title']}" for e in result["epics"]] or ["none"]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export", type=Path)
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--limit", type=int, default=100, help="maximum numbered queue rows (default 100)")
    parser.add_argument("--source-note", default="", help="one line describing where the export came from")
    arguments = parser.parse_args(argv)
    try:
        issues = audit_queue.load_issues(json.loads(arguments.export.read_text()))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"render_queue: {error}", file=sys.stderr)
        return 2
    text = render(plan(issues), arguments.source_note, max(1, arguments.limit))
    if arguments.output:
        arguments.output.write_text(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Audit a GitHub issues export for the #128 next-queue rules (offline, read-only).

Input: a JSON array of issues. Two shapes are accepted:

  * gh CLI:   gh issue list --state all --limit 1000 \
                  --json number,title,state,labels,body,url > issues.json
              (state is "OPEN"/"CLOSED"; labels are [{"name": ...}, ...])
  * REST API: GET /repos/{owner}/{repo}/issues?state=all&per_page=100 (paged,
              concatenated into one array; state is "open"/"closed"; entries
              with a "pull_request" key are skipped).

Dependency text parsed from each body (case-insensitive):
  "depends on #N", "after #N", "Dependencies: #A, #B" (blocking edges) and
  "Part of #N" (parent edges). "Dependencies: No child-task dependency" adds
  nothing.

Report (text, or --json): count of open `sdi:next` items, dependency cycles,
duplicate normalized titles, open items whose blocking dependencies are all
closed (ready), open items blocked by open dependencies, and dependency or
parent references to issues missing from the export (a partial export, not a
defect by itself). It prints facts about the
export; it never edits, closes or creates issues.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

NEXT_LABEL = "sdi:next"
BLOCKING = re.compile(r"\b(?:depends on|after)\s+#(\d+)", re.IGNORECASE)
DEPENDENCIES_LINE = re.compile(r"\*{0,2}Dependencies:?\*{0,2}:?\s*([^\n]*)", re.IGNORECASE)
PARENT = re.compile(r"\bPart of\s+((?:#\d+(?:\s*(?:,|and)\s*)?)+)", re.IGNORECASE)
NUMBER = re.compile(r"#(\d+)")


def normalize_title(title: str) -> str:
    text = re.sub(r"^\s*(\[[^\]]*\]\s*)+", "", title or "")
    text = re.sub(r"[^a-z0-9]+", " ", text.lower())
    return text.strip()


def load_issues(payload) -> list[dict]:
    if not isinstance(payload, list):
        raise ValueError("Expected a JSON array of issues")
    issues = []
    for raw in payload:
        if not isinstance(raw, dict) or "number" not in raw:
            raise ValueError("Each issue needs a number")
        if "pull_request" in raw:
            continue
        labels = raw.get("labels") or []
        names = sorted({(l.get("name") if isinstance(l, dict) else str(l)) for l in labels if l})
        state = str(raw.get("state", "")).lower()
        if state not in {"open", "closed"}:
            raise ValueError(f"Issue #{raw['number']} has an unknown state {raw.get('state')!r}")
        issues.append({"number": int(raw["number"]), "title": raw.get("title") or "", "state": state,
                       "labels": names, "body": raw.get("body") or "", "url": raw.get("url") or raw.get("html_url") or ""})
    numbers = [i["number"] for i in issues]
    if len(numbers) != len(set(numbers)):
        raise ValueError("Duplicate issue numbers in export")
    return sorted(issues, key=lambda i: i["number"])


def parse_dependencies(body: str) -> tuple[set[int], set[int]]:
    """Return (blocking, parents) issue numbers referenced by the body."""
    blocking = {int(n) for n in BLOCKING.findall(body)}
    for line in DEPENDENCIES_LINE.findall(body):
        blocking.update(int(n) for n in NUMBER.findall(line))
    parents = set()
    for group in PARENT.findall(body):
        parents.update(int(n) for n in NUMBER.findall(group))
    return blocking, parents


def find_cycles(edges: dict[int, set[int]]) -> list[list[int]]:
    """Elementary cycles via DFS; each cycle reported once, rotated to its smallest node."""
    cycles: set[tuple[int, ...]] = set()
    nodes = sorted(set(edges) | {t for ts in edges.values() for t in ts})
    for start in nodes:
        stack = [(start, [start])]
        while stack:
            node, path = stack.pop()
            for target in sorted(edges.get(node, ())):
                if target == start:
                    cycle = path[:]
                    pivot = cycle.index(min(cycle))
                    cycles.add(tuple(cycle[pivot:] + cycle[:pivot]))
                elif target not in path and target > start:
                    stack.append((target, path + [target]))
    return [list(c) for c in sorted(cycles)]


def audit(issues: list[dict]) -> dict:
    by_number = {i["number"]: i for i in issues}
    blocking_edges: dict[int, set[int]] = {}
    parent_edges: dict[int, set[int]] = {}
    missing: dict[int, set[int]] = defaultdict(set)
    missing_parents: dict[int, set[int]] = defaultdict(set)
    for issue in issues:
        blocking, parents = parse_dependencies(issue["body"])
        blocking.discard(issue["number"])
        parents.discard(issue["number"])
        blocking_edges[issue["number"]] = blocking
        parent_edges[issue["number"]] = parents
        for target in blocking:
            if target not in by_number:
                missing[issue["number"]].add(target)
        for target in parents:
            if target not in by_number:
                missing_parents[issue["number"]].add(target)
    next_open = [i["number"] for i in issues if NEXT_LABEL in i["labels"] and i["state"] == "open"]
    next_closed = [i["number"] for i in issues if NEXT_LABEL in i["labels"] and i["state"] == "closed"]
    titles: dict[str, list[int]] = defaultdict(list)
    for issue in issues:
        key = normalize_title(issue["title"])
        if key:
            titles[key].append(issue["number"])
    duplicates = {key: nums for key, nums in sorted(titles.items()) if len(nums) > 1}
    ready, blocked = [], {}
    for issue in issues:
        if issue["state"] != "open":
            continue
        deps = blocking_edges[issue["number"]]
        known = [d for d in deps if d in by_number]
        open_deps = sorted(d for d in known if by_number[d]["state"] == "open")
        if deps and not open_deps and len(known) == len(deps):
            ready.append(issue["number"])
        elif open_deps:
            blocked[issue["number"]] = open_deps
    closed_dependencies = sorted({d for deps in blocking_edges.values() for d in deps if d in by_number and by_number[d]["state"] == "closed"})
    return {
        "issueCount": len(issues),
        "openCount": sum(i["state"] == "open" for i in issues),
        "nextOpen": sorted(next_open), "nextOpenCount": len(next_open), "nextClosedStillLabelled": sorted(next_closed),
        "queueWithinTarget": 50 <= len(next_open) <= 100,
        "blockingCycles": find_cycles(blocking_edges),
        "parentCycles": find_cycles(parent_edges),
        "duplicateTitles": duplicates,
        "readyOpenItemsWithAllDependenciesClosed": sorted(ready),
        "blockedOpenItems": {str(k): v for k, v in sorted(blocked.items())},
        "closedDependencies": closed_dependencies,
        "missingReferences": {str(k): sorted(v) for k, v in sorted(missing.items())},
        "missingParents": {str(k): sorted(v) for k, v in sorted(missing_parents.items())},
    }


def render(report: dict) -> str:
    lines = [f"Issues in export: {report['issueCount']} ({report['openCount']} open). Inventory only; not finished software.",
             f"Open {NEXT_LABEL} items: {report['nextOpenCount']} (target 50–100 while substantive work remains: "
             f"{'within' if report['queueWithinTarget'] else 'outside'} target)"]
    if report["nextClosedStillLabelled"]:
        lines.append("Closed issues still labelled sdi:next: " + ", ".join(f"#{n}" for n in report["nextClosedStillLabelled"]))
    lines.append("Blocking dependency cycles: " + (", ".join(" -> ".join(f"#{n}" for n in c + c[:1]) for c in report["blockingCycles"]) or "none"))
    lines.append("Parent (Part of) cycles: " + (", ".join(" -> ".join(f"#{n}" for n in c + c[:1]) for c in report["parentCycles"]) or "none"))
    if report["duplicateTitles"]:
        lines.append("Duplicate normalized titles:")
        lines.extend(f"  {key!r}: " + ", ".join(f"#{n}" for n in nums) for key, nums in report["duplicateTitles"].items())
    else:
        lines.append("Duplicate normalized titles: none")
    lines.append("Open items whose blocking dependencies are all closed: " + (", ".join(f"#{n}" for n in report["readyOpenItemsWithAllDependenciesClosed"]) or "none"))
    lines.append("Closed issues referenced as dependencies: " + (", ".join(f"#{n}" for n in report["closedDependencies"]) or "none"))
    if report["blockedOpenItems"]:
        lines.append("Open items blocked by open dependencies: " + "; ".join(f"#{k} <- {', '.join(f'#{d}' for d in v)}" for k, v in report["blockedOpenItems"].items()))
    if report["missingReferences"]:
        lines.append("Dependency references missing from the export: " + "; ".join(f"#{k} -> {', '.join(f'#{d}' for d in v)}" for k, v in report["missingReferences"].items()))
    if report["missingParents"]:
        lines.append("Parent (Part of) references missing from the export: " + "; ".join(f"#{k} -> {', '.join(f'#{d}' for d in v)}" for k, v in report["missingParents"].items()))
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export", type=Path, help="JSON file from gh issue list --json ... or the REST issues API")
    parser.add_argument("--json", action="store_true", help="print the report as JSON instead of text")
    arguments = parser.parse_args(argv)
    try:
        report = audit(load_issues(json.loads(arguments.export.read_text())))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"audit_queue: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, sort_keys=True) if arguments.json else render(report))
    return 1 if report["blockingCycles"] or report["parentCycles"] else 0


if __name__ == "__main__":
    sys.exit(main())

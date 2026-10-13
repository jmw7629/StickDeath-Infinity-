#!/usr/bin/env python3
"""Keep the app target's Swift source list in StickDeathInfinity.xcodeproj in sync with disk.

Every `.swift` file under StickDeathInfinity/ belongs to the app target (the UI
test and performance targets live under Tests/). The project file lists each
file explicitly, so a file added on a Linux host without Xcode is invisible to
the native build until it is registered here.

  python3 scripts/sync_pbxproj_sources.py          # report (exit 1 when out of sync)
  python3 scripts/sync_pbxproj_sources.py --write  # register new files, drop deleted ones

Identifiers are derived from the path so repeated runs are byte-stable.
"""
from __future__ import annotations

import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "StickDeathInfinity.xcodeproj", "project.pbxproj")
APP_DIR = "StickDeathInfinity"
APP_SOURCES_PHASE = "3115848BD7CB6292DE2A6A32"
MAIN_GROUP_PATH = "StickDeathInfinity"

FILE_REF = re.compile(
    r'^\t+(?P<id>[0-9A-F]{24}) /\* (?P<name>[^*]+) \*/ = \{isa = PBXFileReference; '
    r'lastKnownFileType = sourcecode\.swift; path = "?(?P<path>[^";]+)"?; sourceTree = (?P<tree>[^;]+); \};$',
    re.M,
)


def ident(kind: str, path: str) -> str:
    return hashlib.sha1(f"{kind}:{path}".encode()).hexdigest()[:24].upper()


def on_disk() -> set[str]:
    found = set()
    for base, _dirs, files in os.walk(os.path.join(ROOT, APP_DIR)):
        for name in files:
            if name.endswith(".swift"):
                found.add(os.path.relpath(os.path.join(base, name), ROOT))
    return found


def parse_groups(text: str) -> dict[str, dict]:
    """Return group id -> {name/path, children[]} for every PBXGroup."""
    section = text[text.index("/* Begin PBXGroup section */"): text.index("/* End PBXGroup section */")]
    groups: dict[str, dict] = {}
    for match in re.finditer(r'\t\t(?P<id>[0-9A-F]{24})(?: /\* (?P<comment>[^*]*) \*/)? = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \((?P<children>.*?)\);\n(?P<rest>.*?)\n\t\t\};', section, re.S):
        rest = match.group("rest")
        path = re.search(r'path = "?([^";]+)"?;', rest)
        name = re.search(r'name = "?([^";]+)"?;', rest)
        children = re.findall(r'([0-9A-F]{24})', match.group("children"))
        groups[match.group("id")] = {
            "path": path.group(1) if path else None,
            "name": name.group(1) if name else (match.group("comment") or None),
            "children": children,
        }
    return groups


def group_paths(groups: dict[str, dict]) -> dict[str, str]:
    """Map directory (relative to repo root) -> group id by walking from the main app group."""
    main = next((gid for gid, g in groups.items() if g["path"] == MAIN_GROUP_PATH), None)
    if main is None:
        raise SystemExit("main app group not found")
    result: dict[str, str] = {}

    def walk(gid: str, prefix: str) -> None:
        result[prefix] = gid
        for child in groups[gid]["children"]:
            if child in groups and groups[child]["path"]:
                walk(child, os.path.join(prefix, groups[child]["path"]))

    walk(main, MAIN_GROUP_PATH)
    return result


def main(argv: list[str]) -> int:
    write = "--write" in argv
    text = open(PBX, encoding="utf-8").read()
    registered = {m.group("path"): m for m in FILE_REF.finditer(text) if m.group("path").startswith(APP_DIR + "/")}
    # Relative references inside groups (sourceTree = "<group>") are resolved through their group path.
    groups = parse_groups(text)
    dir_to_group = group_paths(groups)
    group_to_dir = {v: k for k, v in dir_to_group.items()}
    for m in FILE_REF.finditer(text):
        if m.group("tree") == '"<group>"':
            owner = next((gid for gid, g in groups.items() if m.group("id") in g["children"]), None)
            if owner in group_to_dir:
                registered[os.path.join(group_to_dir[owner], m.group("path"))] = m
    disk = on_disk()
    missing = sorted(disk - set(registered))
    stale = sorted(p for p in registered if p not in disk)
    print(f"PBXPROJ_SOURCES registered={len(registered)} disk={len(disk)} missing={len(missing)} stale={len(stale)}")
    for p in missing:
        print(f"  missing: {p}")
    for p in stale:
        print(f"  stale:   {p}")
    if not write:
        return 1 if (missing or stale) else 0

    # Remove stale references everywhere they appear.
    for path in stale:
        ref = registered[path]
        ref_id, name = ref.group("id"), ref.group("name")
        build_ids = re.findall(rf'\t\t([0-9A-F]{{24}}) /\* {re.escape(name)} in Sources \*/ = \{{isa = PBXBuildFile; fileRef = {ref_id} ', text)
        text = re.sub(rf'^\t\t{ref_id} /\* {re.escape(name)} \*/ = \{{isa = PBXFileReference;[^\n]*\n', "", text, flags=re.M)
        text = re.sub(rf'^\t\t\t\t{ref_id} /\* {re.escape(name)} \*/,\n', "", text, flags=re.M)
        for bid in build_ids:
            text = re.sub(rf'^\t\t{bid} /\* {re.escape(name)} in Sources \*/ = \{{isa = PBXBuildFile;[^\n]*\n', "", text, flags=re.M)
            text = re.sub(rf'^\t\t\t\t{bid} /\* {re.escape(name)} in Sources \*/,\n', "", text, flags=re.M)

    # Add missing files: file reference, build file, group child, Sources phase entry.
    for path in missing:
        name = os.path.basename(path)
        ref_id, build_id = ident("fileref", path), ident("buildfile", path)
        directory = os.path.dirname(path)
        # Ensure a group exists for the directory, creating nested groups as needed.
        parts = directory.split("/")
        current = MAIN_GROUP_PATH
        for part in parts[1:]:
            nxt = os.path.join(current, part)
            if nxt not in dir_to_group:
                gid = ident("group", nxt)
                parent = dir_to_group[current]
                text = text.replace(
                    "\t\t/* End PBXGroup section */",
                    f"\t\t{gid} /* {part} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t);\n\t\t\tpath = {part};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n\t\t/* End PBXGroup section */",
                )
                text = re.sub(rf'(\t\t{parent}(?: /\* [^*]* \*/)? = \{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)',
                              rf'\g<1>\t\t\t\t{gid} /* {part} */,\n', text, count=1)
                dir_to_group[nxt] = gid
                groups[gid] = {"path": part, "name": part, "children": []}
            current = nxt
        gid = dir_to_group[directory]
        text = text.replace(
            "\t\t/* End PBXFileReference section */",
            f'\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = SOURCE_ROOT; }};\n\t\t/* End PBXFileReference section */',
        )
        text = text.replace(
            "\t\t/* End PBXBuildFile section */",
            f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n\t\t/* End PBXBuildFile section */",
        )
        text = re.sub(rf'(\t\t{gid}(?: /\* [^*]* \*/)? = \{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)',
                      rf'\g<1>\t\t\t\t{ref_id} /* {name} */,\n', text, count=1)
        text = re.sub(rf'(\t\t{APP_SOURCES_PHASE} /\* Sources \*/ = \{{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n)',
                      rf'\g<1>\t\t\t\t{build_id} /* {name} in Sources */,\n', text, count=1)
    open(PBX, "w", encoding="utf-8").write(text)
    print(f"PBXPROJ_SOURCES updated: +{len(missing)} -{len(stale)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

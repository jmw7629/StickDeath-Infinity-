#!/usr/bin/env python3
"""Generate and verify docs/control-evidence-map.csv from the real native source (#125).

The map lists every *static* `.accessibilityIdentifier("literal")` in
StickDeathInfinity/**/*.swift with the file, enclosing view, a short operation
summary from the surrounding code, whether the operation reaches the document
command/undo path, the best-effort issue mapping from docs/STUDIO_* and the
native UI-test functions that reference the identifier.

Interpolated or concatenated identifiers (`"studio.frame." + frame.id`) are
dynamic; they are counted in the summary but have no rows.

Contract:
  * identifier, file, history and uiTest are regenerated from source and must
    match the CSV exactly (a stale uiTest cell fails verification); uiTest lists
    test functions first, then "helper:<name>" for shared helpers that use the id;
  * screen and operation are regenerated on --write and must be non-empty;
  * issue is curated: --write keeps an existing non-"unmapped" cell when the
    heuristic finds nothing, so owners can map controls by hand.

A row in this CSV is a source mapping, not acceptance evidence. "deferred" in
uiTest means no native UI test references the identifier; it never means passed.
"""
from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = "StickDeathInfinity"
CSV_PATH = "docs/control-evidence-map.csv"
UI_TEST_PATH = "Tests/NativeUI/StudioSmokeUITests.swift"
INDEX_DOC = "docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md"
COLUMNS = ["identifier", "file", "screen", "operation", "history", "issue", "uiTest"]
STATIC = re.compile(r'\.accessibilityIdentifier\(\s*"((?:[^"\\]|\\[^(])*)"\s*\)')
DYNAMIC = re.compile(r'\.accessibilityIdentifier\(')
HISTORY_MARKERS = ("command {", "command(", "StudioCommandExecutor.execute", "applyStudioCommands(",
                   "$0.undo()", "$0.redo()", "editor.undo(", "editor.redo(")
# Files excluded from the native target (project.yml excludes, mirrored by
# scripts/verify_retired_communications.py). Their identifiers stay listed so a
# retired screen cannot be mistaken for a shipping control.
RETIRED_PREFIXES = ("Views/Messages/", "Views/Collab/CreatorRoomView.swift", "Services/LiveKit", "Services/Message")
# Identifier-prefix mapping taken from the issue numbers each verification doc cites.
# The implementation index table is matched separately by control words.
PREFIX_ISSUES = [
    # 2026-10-12 (#125): groups that were "unmapped" at ee35143, mapped to the
    # delivery issue whose title owns the control family (scratch issue index).
    ("studio.export", "#182 #183 #184 #185", "export issues EX01–EX04"),
    ("studio.storage", "#171 #167", "local storage bounds and the project browser"),
    ("studio.frame-menu", "#161", "frames, duration, duplication, reordering"),
    ("studio.frame-timing", "#161", "frames, duration, duplication, reordering"),
    ("studio.frames-viewer", "#161", "frames, duration, duplication, reordering"),
    ("studio.frame-timeline", "#161", "frames, duration, duplication, reordering"),
    ("studio.add-frame", "#161", "frames, duration, duplication, reordering"),
    ("studio.timeline", "#161", "frames, duration, duplication, reordering"),
    ("studio.onion", "#162", "onion skin, thumbnails, playback"),
    ("studio.grid", "#151", "Hand, zoom, fit and canvas navigation"),
    ("studio.tween", "#166", "tweening and easing"),
    ("studio.dodge-burn", "#149", "gradient, blur, smudge, sharpen, burn"),
    ("studio.blur", "#149", "gradient, blur, smudge, sharpen, burn"),
    ("studio.sharpen", "#149", "gradient, blur, smudge, sharpen, burn"),
    ("studio.smudge", "#149", "gradient, blur, smudge, sharpen, burn"),
    ("studio.color", "#146", "eyedropper and color editing"),
    ("studio.eyedropper", "#146", "eyedropper and color editing"),
    ("studio.toolbar", "#139", "sole floating toolbar"),
    ("studio.show-tools", "#139", "sole floating toolbar"),
    ("studio.settings", "#292 #167", "project settings card"),
    ("studio.project", "#292 #167", "project creation card"),
    ("studio.new-project", "#292 #167", "project creation card"),
    ("studio.background", "#292", "project background in the creation card"),
    ("studio.back", "#293", "Studio back navigation"),
    ("studio.undo", "#163", "transactional undo/redo"),
    ("studio.redo", "#163", "transactional undo/redo"),
    ("studio.save", "#168", "atomic saves and recovery checkpoints"),
    ("studio.status", "#168", "save/recovery status"),
    ("studio.brush-library", "#142", "brush behaviour"),
    ("studio.brush-discard", "#142", "brush behaviour"),
    ("studio.brush-retry", "#142", "brush behaviour"),
    ("studio.eraser", "#140", "docs/TOOL_PREFERENCES_VERIFICATION.md, docs/ERASER_VERIFICATION.md"),
    ("studio.layer", "#158", "docs/LAYER_RENAME_VERIFICATION.md"),
    ("studio.image-delete", "#196", "docs/IMAGE_DELETE_CONFIRMATION_VERIFICATION.md"),
    ("studio.image-move", "#196", "docs/IMAGE_CANVAS_DRAG_VERIFICATION.md"),
    ("studio.spatter", "#203", "Spatter in Studio"),
    ("profile.sign-in", "#134 #136 #137", "docs/ENTRY_FLOW_VERIFICATION.md"),
    ("profile.delete-account", "#135 #262", "account deletion entry points"),
    ("profile.subscription-status", "#258", "billing states"),
    ("profile.projects", "#294", "reference profile"),
    ("profile.identity", "#294", "reference profile"),
    ("profile", "#224", "profile editing and portfolios"),
    ("admin", "#210 #285", "admin roles, MFA, user directory"),
    ("spattercc", "#210", "admin credentials"),
    ("calendar", "#297", "native Calendar"),
    ("rooms.warRoom", "#221", "War Room matchups"),
    ("rooms.watchTogether", "#296", "Watch Together without chat or calls"),
    ("rooms.calendar", "#297", "native Calendar"),
    ("rooms.sign-in", "#134 #136 #137", "docs/ENTRY_FLOW_VERIFICATION.md"),
    ("rooms", "#228 #234", "project-scoped rooms"),
    ("warRoom", "#221 #226", "War Room matchups and records"),
    ("watchTogether", "#296", "Watch Together without chat or calls"),
    ("studio.lasso", "#152", "docs/AREA_SELECTION_VERIFICATION.md"),
    ("studio.selection.polygon", "#152", "docs/AREA_SELECTION_VERIFICATION.md"),
    ("studio.selection", "#154", "docs/SELECTION_HANDLE_VERIFICATION.md, docs/SELECTION_TRANSFORM_VERIFICATION.md"),
    ("studio.copy", "#155", "docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md clipboard rows"),
    ("studio.paste", "#155", "docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md clipboard rows"),
    ("studio.delete-selection", "#155", "docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md clipboard rows"),
    ("studio.wand", "#153", "docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md"),
    ("studio.text", "#148", "docs/EDITABLE_TEXT_VERIFICATION.md"),
    ("studio.line", "#147", "docs/STUDIO_TOOL_ACCEPTANCE.md"),
    ("studio.shape", "#147", "docs/STUDIO_TOOL_ACCEPTANCE.md"),
    ("studio.tool-settings", "#140", "docs/TOOL_PREFERENCES_VERIFICATION.md"),
    ("studio.brush", "#140", "docs/TOOL_PREFERENCES_VERIFICATION.md"),
    ("studio.fill", "#140", "docs/TOOL_PREFERENCES_VERIFICATION.md, docs/STUDIO_FILL_VERIFICATION.md"),
    ("studio.image-library", "#195", "docs/IMAGE_LIBRARY_VERIFICATION.md"),
    ("studio.image-crop", "#196", "docs/STUDIO_IMAGE_CROP.md, docs/IMAGE_PLACEMENT_VERIFICATION.md"),
    ("studio.image-placement", "#196", "docs/IMAGE_PLACEMENT_VERIFICATION.md"),
    ("studio.image-order", "#196", "docs/IMAGE_DELETION_VERIFICATION.md"),
    ("studio.image", "#196", "docs/IMAGE_CANVAS_DRAG_VERIFICATION.md, docs/IMAGE_DELETE_CONFIRMATION_VERIFICATION.md"),
    ("studio.layers", "#158", "docs/LAYER_DELETE_VERIFICATION.md, docs/LAYER_RENAME_VERIFICATION.md"),
    ("studio.add-layer", "#158", "docs/LAYER_DELETE_VERIFICATION.md"),
    ("studio.video", "#201", "docs/STUDIO_VIDEO_AUDIO.md"),
    ("studio.audio.fades", "#179", "docs/STUDIO_AUDIO_FADES.md"),
    ("studio.audio.trim", "#178", "docs/AUDIO_NUMERIC_TRIM_VERIFICATION.md"),
    ("studio.audio.volume", "#179", "docs/AUDIO_CLIP_VOLUME_VERIFICATION.md"),
    ("studio.audio.clip-mute", "#179", "docs/AUDIO_TRACK_MUTE_VERIFICATION.md"),
    ("studio.library.import-backup", "#286", "docs/PROJECT_INTERCHANGE.md"),
    ("studio.library.transfer", "#286", "docs/PROJECT_INTERCHANGE.md"),
    ("welcome", "#134 #136 #137", "docs/ENTRY_FLOW_VERIFICATION.md"),
    ("startup", "#134 #136 #137", "docs/ENTRY_FLOW_VERIFICATION.md"),
    ("auth", "#134 #136 #137", "docs/ENTRY_FLOW_VERIFICATION.md"),
    ("onboarding", "#134 #136 #137", "docs/ENTRY_FLOW_VERIFICATION.md"),
    ("spatter.motion", "#203", "docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md Spatter rows"),
    ("spatter.studio", "#203 #207", "docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md Spatter rows"),
    ("spatter.messages", "#203 #207", "docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md Spatter rows"),
    ("spatter.selection", "#207", "docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md"),
    ("spatter", "#203", "docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md Spatter rows"),
]
# Identifier segment -> words that may appear in the index table's Control cell.
TOKEN_ALIASES = {
    "selection": ("move", "selection"), "lasso": ("lasso",), "wand": ("wand",), "audio": ("audio",),
    "image-library": ("image library", "image favorites", "image thumbnail", "image pack"),
    "image": ("image",), "spatter": ("spatter",), "mode": ("new / add / subtract",), "sampling": ("active image",),
    "tolerance": ("tolerance",), "contiguous": ("connected",), "select-all": ("select all",), "invert": ("invert",),
    "grow": ("grow",), "shrink": ("shrink",), "copy": ("copy",), "cut": ("cut",), "delete": ("delete",),
    "lift": ("move on canvas",), "move": ("move on canvas",), "dx": ("numeric move",), "dy": ("numeric move",),
    "keep-proportions": ("keep proportions",), "duplicate": ("duplicate",), "split": ("split",), "repeat": ("repeat",),
    "loop": ("loop",), "nudge-earlier": ("earlier",), "nudge-later": ("later",), "place-track": ("track placement",),
    "volume": ("volume",), "clip-mute": ("mute",), "analyze-waveform": ("waveform",), "selected-waveform": ("waveform",),
    "trim": ("trim",), "search": ("search",), "category": ("category",), "weapons": ("advisory",),
    "favorites": ("favorites",), "pack-list": ("pack",), "timelinePlay": ("play",),
}


def swift_files(root: Path) -> list[Path]:
    return sorted(p for p in (root / SOURCE_DIR).rglob("*.swift") if p.is_file())


def relative(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def is_retired(file: str) -> bool:
    inner = file.split(SOURCE_DIR + "/", 1)[-1]
    return any(inner.startswith(prefix) for prefix in RETIRED_PREFIXES)


def strip_strings(text: str) -> str:
    """Replace string-literal contents so brace matching ignores them (best effort)."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            out.append('"')
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                out.append(" ")
                i += 1
            out.append('"')
            i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def function_bodies(text: str) -> dict[str, str]:
    """Map `func name` -> body text, using rough brace matching on string-stripped source."""
    clean = strip_strings(text)
    bodies: dict[str, str] = {}
    for match in re.finditer(r"\bfunc\s+(\w+)\s*(?:<[^>]*>)?\s*\(", clean):
        name = match.group(1)
        depth, i = 1, match.end()
        while i < len(clean) and depth:
            depth += {"(": 1, ")": -1}.get(clean[i], 0)
            i += 1
        start = clean.find("{", i)
        semicolon_or_func = re.search(r"\bfunc\b|\bvar\b|\blet\b|\binit\b", clean[i:start if start >= 0 else len(clean)])
        if start < 0 or semicolon_or_func:
            continue  # protocol requirement or declaration without a body
        depth, j = 1, start + 1
        while j < len(clean) and depth:
            depth += {"{": 1, "}": -1}.get(clean[j], 0)
            j += 1
        body = clean[start + 1:j - 1]
        bodies[name] = bodies.get(name, "") + "\n" + body
    return bodies


def history_index(root: Path) -> dict[str, bool]:
    """StudioViewModel methods that reach the document command/undo path (transitively)."""
    bodies: dict[str, str] = {}
    for path in swift_files(root):
        text = path.read_text(errors="replace")
        if "class StudioViewModel" in text or "extension StudioViewModel" in text:
            for name, body in function_bodies(text).items():
                bodies[name] = bodies.get(name, "") + body
    reaches = {name: any(marker in body for marker in HISTORY_MARKERS) for name, body in bodies.items()}
    for _ in range(3):
        changed = False
        for name, body in bodies.items():
            if reaches[name]:
                continue
            calls = set(re.findall(r"\b(\w+)\s*\(", body))
            if any(reaches.get(call) for call in calls if call != name):
                reaches[name] = changed = True
        if not changed:
            break
    return reaches


DECLARATION = re.compile(r"\s*(?:private |fileprivate |public |internal )?(?:final )?(?:struct|class|enum|extension)\s+(\w+)(.*)")


def enclosing_view(lines: list[str], index: int) -> str:
    """Nearest preceding View-conforming declaration, else the nearest declaration of any kind."""
    fallback = ""
    for i in range(index, -1, -1):
        match = DECLARATION.match(lines[i])
        if match:
            if re.search(r"\bView\b", match.group(2)):
                return match.group(1)
            fallback = fallback or match.group(1)
    return fallback or "unknown"


def control_context(lines: list[str], index: int, window: int = 14) -> list[str]:
    start = max(0, index - window)
    for i in range(index - 1, start - 1, -1):
        if "accessibilityIdentifier(" in lines[i]:
            start = i + 1
            break
    return lines[start:index + 1]


CONTROL_KINDS = [
    (r"\bBottomBarButton\(", "button"), (r"\bStickerTabButton\(", "button"), (r"\bZoomButton\(", "button"),
    (r"\bButton\(|\bButton\s*\{", "button"), (r"\bToggle\(", "toggle"), (r"\bSlider\(", "slider"), (r"\bStepper\(", "stepper"),
    (r"\bPicker\(", "picker"), (r"\bTextField\(|\bSecureField\(", "text field"), (r"\bTextEditor\(", "text editor"),
    (r"\bMenu\(|\bMenu\s*\{", "menu"), (r"\bNavigationLink\(", "navigation link"), (r"\bScrollView\b", "scroll view"),
    (r"\bList\b", "list"), (r"\bLazyVGrid\b|\bLazyHGrid\b|\bLazyVStack\b|\bLazyHStack\b", "grid"),
    (r"\.onTapGesture", "tap target"), (r"\.gesture\(|DragGesture", "gesture target"),
    (r"\bProgressView\(", "progress"), (r"\bText\(", "text"), (r"\bLabel\(", "label"), (r"\bImage\(", "image"),
    (r"\bColorPicker\(", "color picker"), (r"\bDatePicker\(", "date picker"), (r"\bVideoPlayer\(", "video player"),
]


# Containers and indicators whose identifier sits on a view with no label or
# action in the surrounding lines. The identifier's last segment names the
# element kind; the row still says "review source" so nobody reads it as a
# verified operation.
IDENTIFIER_KINDS = {
    "scroll": "scroll container", "content": "scroll container", "list": "list container", "grid": "grid container",
    "progress": "progress indicator", "examples": "example-command chips", "glow-examples": "example-command chips",
    "labels": "track-label column", "track-labels": "track-label column", "toolbar": "toolbar container",
    "tool-settings": "tool settings popup", "frame-timeline": "frame timeline strip", "repeat": "frame repeat menu entry",
    "camera": "camera import option", "unreadable": "unreadable-project notice", "total": "storage total text",
    "project-picker": "project picker", "pack-list": "image pack list", "next": "next-page button",
    "warRoom": "navigation entry", "watchTogether": "navigation entry",
}


def identifier_fallback(identifier: str) -> str:
    segment = identifier.rsplit(".", 1)[-1]
    kind = IDENTIFIER_KINDS.get(segment, "container")
    return f"{kind} '{identifier}' (identifier-derived; review source)"


def describe_operation(context: list[str], identifier: str = "") -> str:
    joined = "\n".join(context)
    kind = ""
    for line in reversed(context):
        for pattern, name in CONTROL_KINDS:
            if re.search(pattern, line):
                kind = name
                break
        if kind:
            break
    label = ""
    for pattern in (r'\.accessibilityLabel\("([^"\\]*)"\)', r'(?:Button|Toggle|Picker|TextField|TextEditor|Stepper|Menu|Label|Slider|SecureField)\("([^"\\]*)"',
                    r'label:\s*"([^"\\]*)"', r'Text\("([^"\\]*)"\)', r'Text\(verbatim:\s*"([^"\\]*)"\)'):
        found = re.findall(pattern, joined)
        if found:
            label = next((f for f in reversed(found) if f.strip()), "")
            if label:
                break
    actions: list[str] = []
    for pattern in (r"\b((?:vm|session|movie|gif|library|catalogue|auth|authVM|model|viewModel|storage|scope|dismiss|onDismiss|onSelect|onApply|onCancel|action|generate|insert|apply|cancel|perform|load|refresh|submit|toggle)\b(?:\.\w+)*\s*\()",
                    r"\b(vm\.\w+(?:\.\w+)*)\s*(?:=|\.toggle\(\))", r"(\$vm\.\w+(?:\.\w+)*)", r"(\$\w+(?:\.\w+)*)", r"\b(Task\s*\{)"):
        for found in re.findall(pattern, joined):
            cleaned = found.rstrip("(").strip()
            if cleaned.startswith("Task"):
                continue
            if cleaned.startswith("$"):
                cleaned = "binds " + cleaned[1:]
            if cleaned not in actions:
                actions.append(cleaned)
    actions = actions[:3]
    pieces = []
    if kind:
        pieces.append(kind)
    if label:
        pieces.append("'" + label.replace("'", "").strip()[:48] + "'")
    if actions:
        pieces.append("-> " + ", ".join(actions))
    text = " ".join(pieces).strip()
    if not text:
        return identifier_fallback(identifier) if identifier else "unresolved (review source)"
    return text[:140]


def history_for(context: list[str], file: str, file_text: str, reaches: dict[str, bool]) -> str:
    joined = "\n".join(context)
    if "StudioViewModel" not in file_text and "vm." not in file_text and "vm:" not in file_text:
        return "n-a"
    if any(marker in joined for marker in ("applyStudioCommands(", "StudioCommandExecutor.execute", "vm.undo()", "vm.redo()")):
        return "yes"
    calls = re.findall(r"\bvm\.(\w+)\s*\(", joined)
    if any(reaches.get(call) for call in calls):
        return "yes"
    return "no"


def index_rows(root: Path) -> list[tuple[str, str]]:
    path = root / INDEX_DOC
    if not path.is_file():
        return []
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        if not line.startswith("|") or line.startswith("| ---") or line.startswith("| Control"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 2:
            issues = " ".join(re.findall(r"#\d+", cells[-1]))
            if issues:
                rows.append((cells[0].lower(), issues))
    return rows


def issue_for(identifier: str, rows: list[tuple[str, str]]) -> str:
    segments = [s for s in re.split(r"[.]", identifier) if s and s not in ("studio", "spatter")]
    if not segments:
        return "unmapped"
    group = segments[0]
    group_words = TOKEN_ALIASES.get(group, (group.replace("-", " "),))
    best, best_score = "", 0
    for control, issues in rows:
        if not any(word in control for word in group_words):
            continue
        score = 1
        for segment in segments[1:]:
            words = TOKEN_ALIASES.get(segment, (segment.replace("-", " "),))
            if any(word in control for word in words):
                score += 2
        if score > best_score:
            best, best_score = issues, score
    if best_score >= 3:
        return best
    for prefix, issues, _ in PREFIX_ISSUES:
        if identifier == prefix or identifier.startswith(prefix + "."):
            return issues
    return best or "unmapped"


def member_functions(text: str) -> list[tuple[int, str]]:
    """Type-member `func` declarations (the least-indented ones); nested local funcs belong to their member."""
    found = [(m.start(), len(m.group(1)), m.group(2)) for m in re.finditer(r"(?m)^([ \t]*)(?:@\w+(?:\([^)]*\))?\s+)*(?:private |fileprivate |public |internal )?(?:static |class )?func\s+(\w+)\s*\(", text)]
    if not found:
        return []
    shallowest = min(indent for _, indent, _ in found)
    return [(start, name) for start, indent, name in found if indent == shallowest]


def ui_test_references(root: Path, identifiers: set[str]) -> dict[str, list[str]]:
    path = root / UI_TEST_PATH
    text = path.read_text(errors="replace") if path.is_file() else ""
    funcs = member_functions(text)
    references: dict[str, set[str]] = {}
    for match in re.finditer(r'"((?:[^"\\]|\\.)*)"', text):
        literal = match.group(1)
        if literal not in identifiers:
            continue
        owner = ""
        for start, name in funcs:
            if start < match.start():
                owner = name
            else:
                break
        if owner:
            # Non-test helpers are referenced indirectly; keep them visible but distinguishable.
            references.setdefault(literal, set()).add(owner if owner.startswith("test") else "helper:" + owner)
    return {k: sorted(v, key=lambda n: (n.startswith("helper:"), n)) for k, v in references.items()}


def test_function_names(root: Path) -> set[str]:
    path = root / UI_TEST_PATH
    if not path.is_file():
        return set()
    return {name for _, name in member_functions(path.read_text(errors="replace"))}


def generate(root: Path) -> tuple[list[dict[str, str]], dict[str, int]]:
    reaches = history_index(root)
    rows_index = index_rows(root)
    occurrences: dict[tuple[str, str], dict[str, str]] = {}
    dynamic = 0
    for path in swift_files(root):
        text = path.read_text(errors="replace")
        if "accessibilityIdentifier(" not in text:
            continue
        file = relative(root, path)
        lines = text.splitlines()
        for i, line in enumerate(lines):
            static = STATIC.findall(line)
            dynamic += len(DYNAMIC.findall(line)) - len(static)
            for identifier in static:
                key = (identifier, file)
                if key in occurrences:
                    continue
                context = control_context(lines, i)
                screen = enclosing_view(lines, i)
                if is_retired(file):
                    screen += " (retired; excluded from native target)"
                occurrences[key] = {
                    "identifier": identifier, "file": file, "screen": screen,
                    "operation": describe_operation(context, identifier),
                    "history": history_for(context, file, text, reaches),
                    "issue": issue_for(identifier, rows_index), "uiTest": "deferred",
                }
    references = ui_test_references(root, {k[0] for k in occurrences})
    for (identifier, _), row in occurrences.items():
        names = references.get(identifier)
        row["uiTest"] = " ".join(names) if names else "deferred"
    rows = [occurrences[key] for key in sorted(occurrences)]
    summary = {"identifiers": len({r["identifier"] for r in rows}), "rows": len(rows),
               "files": len({r["file"] for r in rows}), "dynamic": dynamic,
               "deferred": sum(r["uiTest"] == "deferred" for r in rows),
               "unmapped": sum(r["issue"] == "unmapped" for r in rows),
               "unresolved": sum("review source" in r["operation"] for r in rows),
               "historyYes": sum(r["history"] == "yes" for r in rows),
               "historyNo": sum(r["history"] == "no" for r in rows),
               "historyNA": sum(r["history"] == "n-a" for r in rows)}
    return rows, summary


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != COLUMNS:
            raise ValueError(f"{path} must have columns {','.join(COLUMNS)}")
        return [dict(row) for row in reader]


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=COLUMNS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def merge_curated(generated: list[dict[str, str]], existing: list[dict[str, str]]) -> list[dict[str, str]]:
    curated = {(r["identifier"], r["file"]): r for r in existing}
    for row in generated:
        previous = curated.get((row["identifier"], row["file"]))
        if previous and previous.get("issue", "").strip() and previous["issue"] != "unmapped" and row["issue"] == "unmapped":
            row["issue"] = previous["issue"]
    return generated


def verify(root: Path, csv_path: Path | None = None) -> tuple[list[str], dict[str, int]]:
    csv_path = csv_path or root / CSV_PATH
    generated, summary = generate(root)
    problems: list[str] = []
    if not csv_path.is_file():
        return [f"{csv_path} is missing; run scripts/verify_control_index.py --write"], summary
    try:
        existing = read_csv(csv_path)
    except ValueError as error:
        return [str(error)], summary
    expected = {(r["identifier"], r["file"]): r for r in generated}
    actual: dict[tuple[str, str], dict[str, str]] = {}
    for row in existing:
        key = (row["identifier"], row["file"])
        if key in actual:
            problems.append(f"duplicate row for {key[0]} in {key[1]}")
        actual[key] = row
    for key in sorted(set(expected) - set(actual)):
        problems.append(f"identifier in source missing from CSV: {key[0]} ({key[1]})")
    for key in sorted(set(actual) - set(expected)):
        problems.append(f"CSV row references an identifier/file no longer in source: {key[0]} ({key[1]})")
    tests = test_function_names(root)
    for key in sorted(set(expected) & set(actual)):
        want, have = expected[key], actual[key]
        if have["uiTest"] != want["uiTest"]:
            problems.append(f"stale uiTest for {key[0]} ({key[1]}): CSV '{have['uiTest']}' vs source '{want['uiTest']}'")
        if have["history"] != want["history"]:
            problems.append(f"stale history for {key[0]} ({key[1]}): CSV '{have['history']}' vs source '{want['history']}'")
        for column in ("screen", "operation", "issue"):
            if not have[column].strip():
                problems.append(f"empty {column} for {key[0]} ({key[1]})")
        if have["uiTest"] != "deferred":
            for name in have["uiTest"].split():
                if name.removeprefix("helper:") not in tests:
                    problems.append(f"uiTest '{name}' for {key[0]} does not exist in {UI_TEST_PATH}")
    return problems, summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--csv", type=Path, default=None, help="CSV path (default docs/control-evidence-map.csv under root)")
    parser.add_argument("--write", action="store_true", help="regenerate the CSV (keeps curated issue cells)")
    arguments = parser.parse_args(argv)
    root = arguments.root.resolve()
    csv_path = (arguments.csv or root / CSV_PATH).resolve()
    if arguments.write:
        rows, summary = generate(root)
        if csv_path.is_file():
            rows = merge_curated(rows, read_csv(csv_path))
        write_csv(csv_path, rows)
        print(f"CONTROL_EVIDENCE_MAP=WRITTEN {csv_path} rows={summary['rows']} identifiers={summary['identifiers']}")
    problems, summary = verify(root, csv_path)
    for problem in problems:
        print("CONTROL_EVIDENCE_MAP: " + problem, file=sys.stderr)
    status = "FAIL" if problems else "PASS"
    print(f"CONTROL_EVIDENCE_MAP={status} rows={summary['rows']} identifiers={summary['identifiers']} files={summary['files']} "
          f"dynamicIdentifiers={summary['dynamic']} uiTestDeferred={summary['deferred']} issueUnmapped={summary['unmapped']} "
          f"operationUnresolved={summary['unresolved']} history(yes/no/n-a)={summary['historyYes']}/{summary['historyNo']}/{summary['historyNA']} "
          "(source mapping only; not native acceptance)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

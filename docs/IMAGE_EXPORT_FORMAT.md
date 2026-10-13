# Native PNG export and atlas manifest

Studio image exports contain lossless PNG files and `manifest.json`. They are rendered outputs, not editable project backups. Audio, selection outlines, editor grid and onion skin are excluded. The manifest records the captured project ID/revision, FPS, dimensions, export background and ordered frames.

## Frame selection

All exports the entire timeline. Current exports the active frame. Range includes both endpoints, using the one-based frame numbers shown in Studio. The service accepts stable frame IDs and always preserves source timeline order. Empty or unknown selections are rejected. The source project and its active frame remain unchanged.

Output filenames and `index` are zero-based within the export. A subset records each frame's zero-based `sourceFrameIndex` and stable `id`. For documents with frame exposures, `durationTicks` is preserved and `startTick` is rebased to the exported sequence starting at zero. Divide ticks by `fps` for seconds; skipped source frames do not add gaps.

## Atlas layout

Automatic columns use the ceiling of the square root of the exported frame count. Explicit columns range from one to that count. Padding is 0–32 pixels on **each** edge of each frame cell; adjacent frames therefore have twice that amount between their image rectangles. Padding follows the selected White or Transparent background. It does not extrude edge pixels.

For canvas W×H, padding P, columns C and N frames:

- Cell size: `(W + 2P) × (H + 2P)`.
- Rows: `ceil(N / C)`.
- Sheet size: `C × (W + 2P)` by `rows × (H + 2P)`.
- Frame i: `x = (i % C) × (W + 2P) + P`, `y = floor(i / C) × (H + 2P) + P`.

Manifest x/y use a top-left origin. Each rectangle's width/height remain W/H and exclude padding. Empty cells use the export background. Original frame resolution is preserved, without silent scaling or dropped frames. Bounds remain 240 exported frames, 8192-pixel sheet edges, 16,777,216 sheet pixels and 256 MiB output, with additional production source/total-pixel limits.

## Version handling

- v1: base frame and canvas metadata.
- v2: exposure timing.
- v3: validated image credits.
- v4: custom atlas `sheetColumns` and `cellPadding`.
- v5: selected-frame `sourceFrameIndex`, optionally combined with v4 layout and credits.

Default full-timeline exports retain their earlier manifest versions. Optional fields may be absent; consumers should use the explicit frame rectangles and reject unsupported semantics rather than assume square cells or unit exposure. PNG sequences reject atlas-only settings. Cancellation and failure retain the existing staged-output cleanup behavior.

Production decode and metadata regressions are in `Tests/StudioExport/main.swift`; this format description does not claim device or release acceptance.

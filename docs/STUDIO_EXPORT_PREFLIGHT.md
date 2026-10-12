# Studio export preflight, naming, sizing and codec policy

Covers issues #182, #184, #185 and #202 for the native MP4, GIF, PNG and spritesheet exporters. Everything below describes code in this branch; the "Verification" section says what has and has not been run.

## Preflight before any rendering (#202)

`StudioExportPreflight` (in `StickDeathInfinity/Services/StudioExportService.swift`) runs in `StudioMovieExportSession.start`, `StudioGIFExportSession.start` and the PNG `StudioExportSession.start` before a snapshot is captured or a frame is rendered.

- Free space: `volumeAvailableCapacityForImportantUsage` of the destination volume must be at least **2 × the estimated output**. The failure message states both numbers in MB and that nothing was exported.
- Thermal state: `ProcessInfo.thermalState == .critical` refuses the export with a cool-down message. `.serious` and below proceed.
- Unknown capacity (the resource value is unavailable) never blocks an export; the check only acts on measured values.

Estimates are documented heuristics, not measurements:

| Output | Estimate |
| --- | --- |
| PNG sequence / spritesheet | 1 byte × pixels × frames + 64 KiB |
| GIF | 0.5 byte × pixels × frames + 64 KiB |
| MP4 (animation only) | configured bit rate (clamped 2–12 Mb/s, `w·h·fps·2`) × duration ÷ 8 + 1 MiB |
| MP4 with audio | twice the video estimate (the video component and final file coexist) + float CAF mix (8 bytes per 48 kHz frame) + AAC (≈24 kB/s) + 1 MiB |

## Filenames from the project name (#185)

`StudioExportFilename.base(for:)` keeps ASCII letters, digits, `-` and `_`; every other run of characters collapses to one `-`; leading/trailing `-` are trimmed; the result is cut to 40 characters; an empty result falls back to `animation`.

- MP4: `<base>.mp4` (animation-only and mixed exports), GIF: `<base>.gif`, PNG sequence: `<base>_000000.png`…, spritesheet: `<base>_spritesheet.png`.
- The services default to the historical names (`animation.mp4`, `animation.gif`, `frame_%06d.png`, `spritesheet.png`) when no base is passed; only the panel sessions pass the project name. Manifests keep `projectID`, `documentRevision` and every `FrameRecord.filename`; the PNG manifest adds `filenameBase`, the MP4 manifest/receipt adds `movieFilename`.
- `Tests/NativeUI/StudioSmokeUITests.swift` lines 7295, 7370 and 7500 still assert `animation.mp4` / `animation.gif`; they need updating by that file's owner to the project-derived names.

## MP4 output size rule (#182, #185)

`StudioMovieExportService.RenderPlan.make(canvasWidth:canvasHeight:preset:)` is the single rule, recorded in every MP4 manifest (`renderPlan`, `renderRule`, `canvasWidth`, `canvasHeight`) and in the mux proof:

1. `scale = targetShortSide / min(canvasWidth, canvasHeight)`; `targetShortSide` is 480/720/1080 for the `ExportQuality` presets Standard/HD/Full HD and the scale is 1 for Original.
2. `contentWidth = round(canvasWidth × scale)`, `contentHeight = round(canvasHeight × scale)`, drawn from the top-left origin with the vector compositor (no resampling of a bitmap).
3. If `contentWidth` is odd, one white pixel column is appended on the right; if `contentHeight` is odd, one white pixel row is appended at the bottom. Nothing is cropped or stretched. Odd canvases therefore export instead of failing with "requires even canvas dimensions".
4. Pixel limits (4,194,304 per frame, 134,217,728 total) apply to the output size, so very wide 1080p outputs are refused explicitly.

The "Transparent (unsupported)" MP4 option was removed; the panel states that MP4 has no alpha channel and always renders on white.

## Codec (#182)

`StudioMovieExportService.Codec` offers H.264 (default) and HEVC. HEVC uses `AVVideoCodecType.hevc` with `kVTProfileLevel_HEVC_Main_AutoLevel` only when `AVAssetWriter.canApply(outputSettings:forMediaType:)` accepts it; otherwise the export fails with `codecUnavailable` and a message, never a silent fallback. Verification checks the written stream's media subtype against the requested codec. The mixed-MP4 mux passes the HEVC stream through and records `"HEVC passthrough"`.

## PNG decode-back verification (#184)

After `CGImageDestinationFinalize`, `StudioExportService.writePNG` reopens the written file with `CGImageSourceCreateWithURL` and requires: PNG type, exactly one image, declared and decoded sizes equal to the rendered bitmap, and complete source/image status. A mismatch throws `verificationFailed` and no export is published.

## Sharing

The Export panel's four destination rows (Camera Roll / TikTok / YouTube / Instagram) were replaced with one explanation: completed files go to the iOS share sheet; Studio does not post to any social network itself.

## Verification

- Linux (this host): `swiftc -parse` passes for every edited Swift file. The Foundation-only logic (`StudioExportFilename`, `StudioExportPreflight.decide`/estimates, `RenderPlan`, `StudioAudioPreviewSilence`, the hold-tick arithmetic) was extracted verbatim and executed with the Linux toolchain: 5/5 harness groups pass.
- Deferred (needs macOS/Xcode): `Tests/StudioExport` (filename, PNG decode-back, preflight), `Tests/StudioMovieExport` (render plan, odd-canvas padding export, 480p preset, HEVC-or-explicit-refusal), the full workflow suites and the native UI journeys. None of these has been run for this commit; nothing here is claimed as passed on Apple platforms.

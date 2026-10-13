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

## Wave 3 additions (2026-10-13; nothing below has run on Apple hardware)

### Frame cap raised by streaming (#182)

`StudioMovieExportService.Limits.maximumFrames` is 1,440 and `maximumTotalPixels` is 2,985,984,000 (1,440 × 1920 × 1080). Frames were already rendered one at a time into a pixel-buffer pool entry, so the cap bounds encoder time rather than memory; the 300-second operation timeout and the 64 MiB output cap are unchanged. `StudioMuxCapture` applies the same caps to mixed exports, whose audio side still has to fit one 120-second mix (5,760,000 samples at 48 kHz), so a 1,440-frame mixed MP4 needs 12 fps or more. The PNG sequence exporter (`StudioExportService.maximumFrames`) takes the same 1,440-image cap because it writes each PNG before rendering the next; spritesheets keep their 16.7-megapixel sheet bound. GIF keeps 240 frames and 8.4 million aggregate pixels because Image I/O retains frame bitmaps until finalisation (memory-bound, measured earlier).

Tests added, DEFERRED (not run here): `Tests/StudioMovieExport` "frames stream through one pool buffer so 300 frames export above the former 240 cap"; the `Tests/StudioExport` limit test now rejects 1,441 images.

### PNG scale and separate layers (#184)

`StudioExportService.export(..., scale:, separateLayers:)`. `Scale` is 50 % / 100 % / 200 %: the compositor draws vectors and placed rasters at the output size through `render(outputSize:)`; nothing is resampled afterwards, and the per-image pixel caps apply to the output size. `separateLayers` (PNG sequence only) writes every frame once per visible, non-reference layer as `<base>_<frame>_L<nn>.png`, records `layerID`/`layerName`/`layerIndex` per `FrameRecord`, and sets `scale`/`separateLayers`/`layerCount` (manifest version 6). The Export panel exposes `studio.export.scale` and `studio.export.separate-layers`. Test: `Tests/StudioExport` "scale draws at the output size and separate layers write one decodable PNG per visible layer" (DEFERRED).

### Save to Files (#185)

`StudioFilesSavePresenter` wraps `UIDocumentPickerViewController(forExporting:asCopy: true)`. It takes the same share request the share sheet uses (`StudioExportFileRequest`: the MP4 and GIF `ShareRequest` classes, plus `StudioImageExportFileRequest` for the PNG session), so the files stay owned by the export session until the picker's delegate callback; dismissal alone never finishes the request. Buttons: `studio.export.save-files`, `studio.export.movie.save-files`, `studio.export.gif.save-files`. A completed save is a copy receipt; no destination is recorded and nothing is uploaded. Native journey coverage is required and DEFERRED.

### Library sound credits in MP4 manifests (#191, #198)

`StudioMovieExportSession` hashes the retained audio assets off the main actor, loads the bundled catalogue and resolves `StudioSoundCredit` records by shipped-file digest. `StudioMuxCapture.proofFor` refuses a credit that names an uncaptured asset or whose digest differs from the asset bytes, and includes the credits in the proof identity; `StudioAudioVideoMuxService.Receipt.soundCredits` and the session's `Manifest.soundCredits` carry them. An unavailable library yields no credits plus `soundCreditNotice`; every library sound is CC0, so the export is not blocked. PNG and GIF carry no audio and therefore no sound credits. `scripts/verify_sound_catalogue_provenance.py` (run here: 2,127 sounds, 2,127 distinct shipped and original digests, 2 publisher hosts) checks the catalogue offline.

### Reference layers never export (#200)

`StudioDocument.hidingReferenceLayers` (in `StudioExportService.swift`) hides every layer whose `isReference` flag is set before PNG, GIF, animation-only MP4 and mixed-MP4 rendering and before the mux proof is computed. The flag itself is a `Models.swift` change owned by the Studio model agent (see the wave 3 report's coordinator actions); until it lands these call sites do not compile.

### Benchmark harness (#202)

`Tests/StudioExportBenchmark/main.swift` drives the production exporters with a generated document and prints wall time, `ru_maxrss` before/after and output bytes; `scripts/media/run_export_benchmark.py <frames> <width> <height> <fps> [png]` compiles it with the exact production source list of the `Tests/StudioMovieExport` CI step. On Linux the script prints the command and exits 3.

| Case | Device | Seconds | Peak RSS | Output bytes | Status |
| --- | --- | --- | --- | --- | --- |
| MP4 1,440 × 1080 × 1920 @ 24 fps | — | — | — | — | DEFERRED (not run) |
| MP4 1,440 × 1920 × 1080 @ 12 fps | — | — | — | — | DEFERRED (not run) |
| PNG 1,440 × 1080 × 1920 | — | — | — | — | DEFERRED (not run) |
| MP4 240 × 1080 × 1920 @ 24 fps (former cap, regression) | — | — | — | — | DEFERRED (not run) |

Record development-Mac numbers as Mac numbers; iPhone thermal and memory behaviour needs an on-device run. The preflight (`StudioExportPreflight`) remains the only runtime guard: free space for twice the estimate and a non-critical thermal state.

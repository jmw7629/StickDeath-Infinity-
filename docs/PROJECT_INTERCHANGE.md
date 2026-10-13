# Editable project interchange

Implementation checkpoint: October 13, 2026. Source: `SwiftProjectImport.kt`,
`SwiftProjectExport.kt`, `SwiftRoundBrush.kt`, `ProjectStore.kt` and native
`DeviceStorageManager`. This is a bounded two-way contract for a subset of content,
not a cross-platform release claim.

## Envelope and storage

Swift portable input starts with ASCII `SDIPROJECT000001\n`, followed by an
8-byte big-endian payload length, 32-byte SHA-256 digest and UTF-8 Revision JSON.
The importer requires exact length and digest, version 1, and bounded JSON depth
and payload size. The project embeds its editable archive as base64 JSON.
Metadata dimensions, frame/layer counts, name, FPS and identity must agree with
that archive. Historical raster sidecars and additional image assets are rejected.

Android restore uses the existing save-copy transaction and allocates fresh
project, frame, layer and artwork identities. Source bytes remain untouched.
Successful imports persist in Android-local format v26 (v25 when no v26 content
is present), not in a Swift envelope. Android reads local versions 1–26; older
clients must not open newer backups.

## Current mapping (import, schema 1–35)

| Swift content | Android behavior |
| --- | --- |
| Historical descriptor-free pen/pencil/brush | Quadratic path; width multipliers 1/0.8/1.5; pencil butt cap, other caps round |
| Historical descriptor-free `line` (two points) | Android `Line` stroke (straight, round caps) |
| Round brush descriptor v1/v2 | Retained smoothing, pressure samples and settings; bounded native-style arc-length dabs |
| Nonuniform round resize, rotation and flip | Persisted nib transform; original sampling coordinates reconstructed for redraw |
| Frames and exposure | Frame order and hold ticks retained within Android limits |
| Layers | Order, visibility, opacity, `lockMode` free/full/position/alpha, the 18 PhotoCraft blend raw values (Linear Burn refused), `colorLabel` when it is one of the eleven swatches |
| Four-track mixer | `audioTrackVolumes`, `mutedAudioTracks`, `audioTrackPans`, `soloedAudioTracks` with the iOS validation rules |
| Configured guides, glow, unknown labels, other brush families | Reject entire import |
| Images, audio clips, text, fills, effects, erasers | Reject entire import |

## Current mapping (export, Android → iOS)

`SwiftProjectExport.encode` writes the same envelope for the supported subset and refuses
everything else with a listed reason; nothing is flattened. Exported: pencil strokes of the
Round family (native Android polylines become descriptor-free `pen` elements, which iOS smooths
with its quadratic path; imported legacy pencils keep `pencil` with the 0.8 multiplier undone;
retained round-brush descriptors travel back with their pressures), `line` strokes, layers with
`lockMode`, `blendMode`, `colorLabel`, opacity and visibility, `holdTicks`, and the four-track
mixer. The document declares schema 34 when PhotoCraft blends, pan or solo are used, otherwise
21. Refused: textured brushes (incl. marker/crayon), soft and hard erasers, closed shapes, text,
images (with crop/turns), fills, alpha-preserving paint, transformed brush marks and audio clips.
The Export panel lists the blockers for the open project.

Existing Android capacity limits remain authoritative. An unsupported or
oversized file fails before saving a partial project. Do not remove original
files or substitute a rendered picture for an editable document.

## Evidence and remaining gates

Shared fixtures live in `Tests/SDIFixtures` (generator, verifier, six schema-35 fixtures,
`expectations.json`); `python3 -I Tests/SDIFixtures/verify_fixtures.py` passed in the
implementation container. The Android instrumented tests import the golden fixture, reject the
five negatives, persist v26 and re-import the Android export of the golden fixture through the
production importer. JVM unit tests check the export JSON against the Codable contract. None of
the Kotlin has compiled or run here; CI compiles the app and instrumentation APK and runs the
JVM tests, and an emulator or device must run the instrumented suite.

Release still requires actual native-generated fixtures, an iOS check that opens these fixtures
and the Android export, Android device runs, same-size rendering comparisons, full
supported-content mapping (images, text, effects, audio), asset lifetime and audio/timing
verification. #286 remains open.

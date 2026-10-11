# Editable project interchange

Implementation checkpoint: October 11, 2026. Source: `SwiftProjectImport.kt`,
`SwiftRoundBrush.kt`, `ProjectStore.kt` and native `DeviceStorageManager`.
This is a partial one-way import contract, not a cross-platform release claim.

## Envelope and storage

Swift portable input starts with ASCII `SDIPROJECT000001\n`, followed by an
8-byte big-endian payload length, 32-byte SHA-256 digest and UTF-8 Revision JSON.
The importer requires exact length and digest, version 1, and bounded JSON depth
and payload size. The project embeds its editable archive as base64 JSON.
Metadata dimensions, frame/layer counts, name, FPS and identity must agree with
that archive. Historical raster sidecars and additional image assets are rejected.

Android restore uses the existing save-copy transaction and allocates fresh
project, frame, layer and artwork identities. Source bytes remain untouched.
Successful imports persist in Android-local format v24, not in a Swift envelope.
Android reads local versions 1–24; older clients must not open newer backups.

## Current mapping

| Swift content | Android behavior |
| --- | --- |
| Historical descriptor-free pen/pencil/brush | Quadratic path; width multipliers 1/0.8/1.5; pencil butt cap, other caps round |
| Round brush descriptor v1/v2 | Retained smoothing, pressure samples and settings; bounded native-style arc-length dabs |
| Nonuniform round resize, rotation and flip | Persisted nib transform; original sampling coordinates reconstructed for redraw |
| Frames and exposure | Frame order and hold ticks retained within Android limits |
| Normal layers | Order, visibility, opacity and free/full locking retained |
| Configured guides, nonnormal blends, glow/labels, other brush families | Reject entire import |
| Images, audio, text, fills and effects | Reject entire import |
| Android-to-Swift editable export | Not implemented |

Existing Android capacity limits remain authoritative. An unsupported or
oversized file fails before saving a partial project. Do not remove original
files or substitute a rendered picture for an editable document.

## Evidence and remaining gates

The committed legacy fixture is independently constructed from the Codable
contract; it is not an actual native export. Instrumentation covers integrity,
legacy geometry, new identities, actual AtomicFile reopen, round sampling and
transform persistence. CI compiles the app and instrumentation APK; compilation
does not establish device execution or pixel parity.

Release still requires actual native-generated fixtures, Android device runs,
same-size rendering comparisons, full supported-content mapping, reverse export,
asset lifetime and audio/timing verification. #286 remains open.

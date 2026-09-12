# Native MP4 preview

The existing MP4 export panel decodes the actual validated local output with AVPlayer. It exposes play/pause/replay, real playback time and seeking without changing the primary toolbar or adding a secondary dock. Video and mixed-audio files use the same preview. Playback never starts automatically.

A single export-consumer lease retains the files while the decoder uses them. Sharing, new export, panel/account/project changes and backgrounding stop the decoder before releasing its files. Generation and seek identities reject stale callbacks. Decoder failures release the preview while preserving a reusable completed output. Initial readiness has a 15-second bound and a retry message; that timeout-expiry branch has not been fault-injected.

Fourteen production groups exercise real AVPlayer picture pixels, H.264/AAC decoding with non-silent PCM, playback clock/pause/seek/end/replay, consumer exclusivity, account/background/cleanup, share handoff, reentrancy and release. Two groups inject the framework failure notification into a genuine player; these are controlled failure fixtures, not spontaneous device failures. Existing 18 session and 8 panel/consumer groups passed in their retained source scopes. The iPhone SDK source check passed.

The existing mixed-MP4 native journey now checks actual player-layer pixels, seeks to a later blank frame, plays to completion, and then uses the native share sheet. Its simulator run is pending. Physical speaker output, successful destination save/reopen, iPad/device playback, signing and TestFlight remain unverified. GIF and general video import are separate unfinished features. No public uploads run during testing.

## Preceding native result

Before this preview change, source `87c9c7c4d250d3731fa371b43fe645aebb821fd8` passed the native app build and every production stage, then 17 of 18 iPhone16Pro/iOS18.5 UI journeys (zero skipped). The complete source-tagged log, recording, result bundle and original captures were retained and the archive SHA/CRC verified. Photo seeding succeeded in12.247515seconds; no simulator-infrastructure repair is claimed. The new fill, full bundled-audio/mix/reopen and both MP4/share journeys passed.

The remaining failure happened during initial Brush selection, before eyedropper sampling: the accessibility capture placed the Brush right edge at392points and its viewport at390. Twelve large flicks oscillated past the partly clipped button. The corrected helper uses edge-based short drags and holds before release. Full containment, actual hittability, all18journeys and existing execution limits are retained. Its exact-source simulator result is pending.

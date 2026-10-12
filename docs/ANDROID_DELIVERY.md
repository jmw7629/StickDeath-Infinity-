# Android delivery contract

## Decision and authority

The owner's October 9 execution direction explicitly includes iOS, Android and the website. Android is an additive Kotlin/Jetpack Compose client under `android/`. SwiftUI remains the iOS product and first product priority. Android does not wrap the website or replace the SwiftUI app.

Native Kotlin was selected for direct touch/stylus, Canvas, MediaCodec, AudioTrack, content-provider and lifecycle integration. Kotlin Multiplatform could share selected pure models later, but it does not automatically make the existing Swift renderer or media pipeline portable. A cross-platform rewrite would discard working native behavior and conflict with the owner's preservation requirement. No second repository, paid service or separate animation project is required.

## Delivery order and actual boundaries

| Area | Current implementation | Remaining acceptance or implementation |
| --- | --- | --- |
| Local Studio | Canonical Kotlin frames/layers/artwork, history, atomic local projects, selection transforms, brush families, shapes/text/fill, audio clips and exports | Physical-device acceptance, unsupported advanced effects/rigging/tween/crop parity and full native visual comparison |
| Studio assets | Reuses licensed native sound and image bundles; local favorites/recent imports; source credits in imported artwork/clips | Optional native image-pack parity, complete device decoding and rights/update acceptance |
| Audio/media | Bounded WAV/compressed audio import and mixing; one video still at the animation playhead | Full video tracks, trim/orientation/timing, audio extraction and device media acceptance |
| Sharing | Existing Files exports; rendered-file Sharesheet implementation follows the same renderer | Receiving-app and URI lifetime acceptance; direct destination services and official-channel publication remain separate |
| Identity and Spatter | No Android cloud transport or identity success is claimed | Secure native sign-in/session restoration, typed Studio command bridge, grounded assistance and authenticated provider transport |
| Social and collaboration | No invented feed/rooms/users | Authorized video feed, opt-in shared-project rooms, War Room and optional profile statistics using the same server contracts as iOS |
| Billing, notifications, admin | No live charges, push delivery or Android admin role is claimed | Store purchase/restore and signed entitlement reconciliation, notifications, server-authorized admin access and distribution |

No user-to-user text chat, phone or video calling is included. Spatter assistance and project collaboration remain in scope. Private drafts never imply publication permission; generated public releases require owner approval of the exact render.

## Studio parity matrix (iOS schema 34 vs Android-local v25)

Status is implementation status only. Every Android row is unverified in this batch: the implementation container has no Android SDK, emulator or device, so compilation and behaviour are deferred to the CI compile/unit-test job (`.github/workflows/android-build.yml`) and a later emulator or device run of `app/src/androidTest`. "Done" means the code exists and is covered by tests that have not yet run; it is not a pass.

| Area | Feature | Android status | Notes |
| --- | --- | --- | --- |
| Tools | Pencil, eraser, line, rectangle, ellipse, triangle, diamond, star, arrow, text, image, fill, eyedropper, lasso, move, hand | Done | Shared `FrameRenderer` path for viewport, eyedropper and export |
| Tools | Marker, crayon, wand, ruler, gradient, blur, smudge, sharpen, dodge, burn, soft eraser | Missing | No Android tool; Swift import rejects elements using them |
| Tools | Zoom tool | Missing | Android uses pinch gestures only; no dedicated tool |
| Tools | Tilt/pressure input | Partial | Pressure retained for imported Swift round-brush dabs; no live stylus tilt |
| Brush families | Round, stipple, grain, rough pen, calligraphy, dip pen, halftone, hatch | Done | Hatch is a single family |
| Brush families | Gradient, airbrush, watercolor, neon; hatch left/right variants | Missing | Imports using them reject with the original preserved |
| Layers | Order, visibility, full lock, opacity, rename, duplicate, delete | Done | |
| Layers | Blend modes: normal, darken, multiply, color burn, lighten, screen, color dodge, linear dodge, overlay, soft light, hard light, difference, exclusion, hue, saturation, color, luminosity | Done (API 29+) | iOS raw values round-trip (`LayerBlend.swiftName`/`fromSwift`); 12 modes need Android 10 and are disabled below it. Soft Light uses Skia's curve where iOS measured Pegtop; pixel comparison deferred |
| Layers | Linear Burn | Missing (explicit) | No exact Android compositing mode; renderer and import refuse it, never draw Normal |
| Layers | Lock position / lock alpha, glow, colour labels | Missing | Import rejects glow and partial lock modes; labels are not carried |
| Images | Import stills from Files/Photos, move/scale/rotate as artwork, source credit | Done | 4 MiB / 4 megapixel project cap |
| Images | Crop, image rotation metadata, region masks, background cut | Missing | |
| Audio | Clip import (WAV/compressed), trim, split, duplicate, placement, clip gain/mute, linear fades | Done | 60 s clip cap vs 300 s on iOS; default clip volume 1.0 vs 0.8 on iOS |
| Audio | Track volume, mute | Done | |
| Audio | Track pan (balance law), solo (SoundCraft rule) | Done | Mixer, scene playback, MP4 and clip preview; pan slider and solo chip in the track mixer |
| Audio | Curved fades (equal power, S-curve, exponential, logarithmic) | Done | Same `gain(t)` formulas; fade times stay seconds on Android, 48 kHz frames on iOS |
| Audio | Voice recording, audio from video | Missing | |
| Export | PNG frame, ZIP frame set with timing manifest, MP4 with mixed audio, looping GIF, Sharesheet | Done | Manifest layout differs from iOS `StudioExportService`; MP4/GIF manifests missing |
| Export | Transparent background PNG | Missing | |
| Export | Android → iOS `.sdi` | Missing | One-way Swift import only; see interchange section |
| Export | GIF palette | Partial | RGB332 palette vs the iOS encoder; visual comparison deferred |
| Interchange | Swift `.sdi` import of pen/pencil/brush paths, round-brush descriptors, holds, layers/blends, mixer state (schema 1–34) | Partial | Clips, images, other tools/brushes, glow, partial locks and unknown fields reject |
| Assistant | Spatter command bridge | Missing | |

## Interchange remains an explicit delivery requirement

The current `sdi-android-local` envelope is an Android backup format. It is not the Swift `.sdi` codec. Android now has a separate, bounded Swift import path described in [PROJECT_INTERCHANGE.md](PROJECT_INTERCHANGE.md); general native-project compatibility must not be advertised. PNG/MP4/GIF exchange is rendered media, not editable project interchange.

A shared codec must preserve stable identities, layer order/locks/blends, frame exposure/FPS, canvas/background, vector and raster content, asset ownership/provenance, audio source-time trims/fades/mix, schema migration and reversible command semantics. Unsupported data must be retained or rejected with the original preserved; no silent flattening or dropped effects. Cross-platform golden fixtures must be opened and re-exported by both production clients, with timing/pixel/audio comparisons and corrupted/unknown-version preservation. Those fixtures and the production interchange codec remain unfinished under #286; implementation of local Android documents does not complete that checkbox.

## Owner and release prerequisites

- Verify an existing Google Play developer account and package ownership before any store submission.
- Establish signing-key custody and Play App Signing enrollment. Keep private keys/passwords out of the repository, issues and public artifacts. Debug APKs are not signed production releases.
- Verify the existing authorized push project and credentials before notification integration; do not create a paid Firebase/hosting subscription or claim delivery without credentials and device evidence.
- Configure approved products, annual prices, store policies and server-side entitlements. No real purchase is a test.
- Retain the current SwiftUI build/signing/TestFlight gates independently. An Android compiler pass cannot close iOS acceptance.

Build and runtime evidence belongs to the exact commit and CI run. Pending physical-device, lifecycle, accessibility, sharing and cross-platform acceptance is not a pass. #287 owns Studio delivery; #288 owns connected-client parity; #289 owns Android billing/push/store release. #286 remains open until its interchange and cross-platform evidence requirements are satisfied.

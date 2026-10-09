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

## Interchange remains an explicit delivery requirement

The current `sdi-android-local` envelope is an Android backup format. It is not the Swift `.sdi` codec and must not be advertised as opening native projects. PNG/MP4/GIF exchange is rendered media, not editable project interchange.

A shared codec must preserve stable identities, layer order/locks/blends, frame exposure/FPS, canvas/background, vector and raster content, asset ownership/provenance, audio source-time trims/fades/mix, schema migration and reversible command semantics. Unsupported data must be retained or rejected with the original preserved; no silent flattening or dropped effects. Cross-platform golden fixtures must be opened and re-exported by both production clients, with timing/pixel/audio comparisons and corrupted/unknown-version preservation. Those fixtures and the production interchange codec remain unfinished under #286; implementation of local Android documents does not complete that checkbox.

## Owner and release prerequisites

- Verify an existing Google Play developer account and package ownership before any store submission.
- Establish signing-key custody and Play App Signing enrollment. Keep private keys/passwords out of the repository, issues and public artifacts. Debug APKs are not signed production releases.
- Verify the existing authorized push project and credentials before notification integration; do not create a paid Firebase/hosting subscription or claim delivery without credentials and device evidence.
- Configure approved products, annual prices, store policies and server-side entitlements. No real purchase is a test.
- Retain the current SwiftUI build/signing/TestFlight gates independently. An Android compiler pass cannot close iOS acceptance.

Build and runtime evidence belongs to the exact commit and CI run. Pending physical-device, lifecycle, accessibility, sharing and cross-platform acceptance is not a pass. #287 owns Studio delivery; #288 owns connected-client parity; #289 owns Android billing/push/store release. #286 remains open until its interchange and cross-platform evidence requirements are satisfied.

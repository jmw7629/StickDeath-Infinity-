# Studio control implementation index

## October 9 implementation batch

This index maps the current selection, audio and asset-library controls to production code. It supplements the existing tool/export acceptance documents; it is not a complete inventory of every app screen. Source baseline: `2100cfb` and its ancestors. Build, simulator, device, accessibility, persistence and export verification for this batch are **deferred / not run** under the owner's implementation-first direction. Earlier successful tests do not cover these changes.

Issue #125 remains open. A source mapping or checked implementation item is not release acceptance. No unsupported control, failed required check or missing runtime evidence is waived by this document.

| Control | Production operation | State, history and scope | Issue |
| --- | --- | --- | --- |
| Lasso Freehand / Rectangle / Polygon | `StudioViewModel.finishAreaSelection`, `StudioSelectionRegion` | Transient canonical object IDs; source-transformed enclosure; selects movable visible drawings and/or whole active-layer image | #152 |
| Lasso New / Add / Subtract | Same selection entry point | Replaces/unions/subtracts identities; no document Undo entry for selection alone | #152 |
| Automatic Lasso → Move | `activateMoveAfterAreaSelection` | Nonempty selection becomes Move, New mode; selected identities retained | #152, #154 |
| Move box drag / resize / rotate | `beginMove`, `beginSelectionHandle`, canonical transform commands | One edit per completed gesture; stale context/cancel rejected; document Undo and save | #154 |
| Move Duplicate drawings | `duplicateSelected`, typed `duplicateElements`, `StudioDocumentEditor.duplicateElements` | Fresh drawing IDs on original layers, original clipboard retained, copies selected for Move; one Undo; strict command decoding, cumulative generation budget and stale-context rejection; native checks deferred | #156 |
| Move Keep proportions / Width / Height | `selectionPreservesAspect`, selection transform pipeline | Independent axes for drawings; images/mixed groups preserve aspect; preference saved per tool | #140, #154 |
| Wand tolerance / connected matching | `StudioImageRegionService.select` | Real bounded color-region membership in the active source image | #153 |
| Wand Active image / Visible canvas | Canonical `StudioFillService.capture` plus source-to-canvas mapping | Composite colors can determine membership; only active-image originals are edited, never sampled background layers | #153 |
| Wand New / Add / Subtract | Region membership operation | Transient selection mask; original project unchanged until an edit action | #153 |
| Wand Select all / Invert / Grow / Shrink | `changeImageRegionMembership` | Actual source-pixel masks, limited by crop/coverage; Grow/Shrink use one source pixel including diagonals | #153 |
| Wand Copy / Cut / Delete | `applyImageRegion` | Explicit selection required; preserved source bytes; Cut/Delete are atomic document edits | #153, #155, #156 |
| Wand Move on canvas | `applyImageRegion(.lift)`, `editImageRegion(.lift)` | New image layer with selected mask, complementary original mask; one Undo for lift, subsequent transforms have their own Undo entries | #153, #154 |
| Wand numeric Move | `applyImageRegion(.move)` | Nonzero canvas offset; same source-preserving transaction | #153 |
| Wand Reset this tool | `resetCurrentDrawingToolPreferences` | Resets only this tool's saved preferences; no project/history edit | #140 |
| Audio Play / Stop / Loop | `StudioAudioTimelineSession`, `StudioTimeline` | Real mixed audio clock where present; animation-only monotonic clock otherwise; no fabricated audio | #180 |
| Audio clip drag / track placement | `editSelectedAudioClip(.place)` | Snapped transient preview; one canonical transaction on release; captures project/revision/FPS/zoom/snap | #177 |
| Audio Earlier / Later one frame / Track menu | Same placement operation | Selected-clip exact edits without dragging; original audio immutable | #177 |
| Audio leading-edge trim | `editSelectedAudioClip(.trimLeading)` | Timeline start and source offset move together, end stays fixed; one update/Undo | #178 |
| Audio trailing-edge / numeric trim | `editSelectedAudioClip(.trim)` | Source-range validation; timeline boundary snapping for edge gesture; numeric source trim remains distinct | #178 |
| Audio trim preview | `StudioAudioTimelineClip.trimPreview` | Transient width/start/duration and waveform; no edit until release; cancelled/stale gesture cannot recapture a newer revision | #178 |
| Audio Split / Duplicate / Repeat / Delete | Existing prepared captures and canonical audio mutations | Explicit selection; retained original source, bounded copy count, transactional history | #178 |
| Audio clip/track volume and mute | Existing captured volume/track operations and mixer | Rendering/export use canonical settings; slider release produces edit | #179 |
| Audio waveform / Load measured waveform | `StudioAudioPreviewSession.analyze`, `MeasuredAudioWaveform` | Decoder-derived peak bins cropped to source offset/duration; bounded derived cache; source overview before gain/fades | #192 |
| Audio VoiceOver placement/trim | Same selected-clip placement/trim entry point | One-frame actions; displayed clip equality and revision admission; no alternate document model | #177, #178 |
| Image Library search/category/advisory filter | `StudioImageCatalogue.search` | Once-per-body result list carries original catalogue; no project edits | #195 |
| Image favorites / recent / clear recent | `StudioImageLibraryPreferences` | Bounded local preferences; does not delete original pictures or inserted project assets | #195 |
| Optional image pack Download / Cancel / Remove | Existing `StudioImagePackCache` paths | Pinned/checksummed on-demand packs; imported project copies retained on removal | #195 |
| Image thumbnail / Preview | `StudioImageLibraryThumbnails`, existing `onSelect` import handoff | Serial verified 128px thumbnails, 48-entry cache; off-screen/dismissal/memory-pressure cleanup affects only decoded previews | #171, #195 |
| Spatter selection help | `SpatterAIViewModel.localGuidance` | Advice only, versioned; no automatic edit or success receipt | #207 |
| Spatter current Wand context | `CommandScreenContext.Wand` → `SpatterContext.StudioSnapshot` | Bounded settings/count/editability, no mask bytes or inferred object identity; absent context reported unknown | #203, #207 |

## Final integration evidence still required

- Actual same-source app build and relevant production/native regression gates.
- Lasso object/whole-image/mixed selection under zoom, rotation and lock changes; Move handles and Undo/save/reopen/export preserve selected content.
- Wand active/composited sampling under crop, quarter turns, reflection and rotation; add/subtract/grow/shrink and lift/transform/undo/reopen preserve unselected content.
- Audio drag/trim on short and long clips across four tracks; cancellation, stale revision, minimum duration, source boundaries, snapped/non-snapped timing and one-gesture Undo.
- Actual decoded audio/video output, synchronized playback, measured waveform/source agreement and supported device limits. A peak-bin overview does not establish sample-accurate visual resolution.
- Compact portrait/landscape, keyboard and VoiceOver interactions. Large-library scroll/reappearance and memory-pressure behavior need actual measurements.
- Spatter snapshot freshness, route isolation, truthful unknown states and zero provider requests in local mode.

## Explicit limits retained

Wand still requires a normal, opaque, unlocked active image layer without drawings/effects; arbitrary vector-layer pixel extraction is not implemented. Lasso selects whole drawing objects and whole images, not arbitrary image pixel cutouts. Group transforms are bounded and include at most one active-layer image. Asset counts describe catalogue availability, not installed optional packs. Connected publishing, signing and release acceptance remain separate gates. This index makes no new deployment or installation claim.

### Local Spatter drawing duplication

The explicit “Duplicate selected drawings.” example captures a Move selection, rejects images/mixed artwork and stale context, and submits the same typed `duplicateElements` transaction as the manual button. Receipt-created drawing IDs become the Move selection; the receipt reports their actual count. Whole-instruction parsing rejects suffixes and malformed input. No provider request is needed. Native compilation, parser/runtime acceptance and save/reopen journeys remain deferred.

### Shared audio track controls

Manual track mute/volume and local Spatter track instructions use typed `updateAudioTrack` transactions. Track IDs are 1–4, gain is finite 0–1, and empty settings reject. Historical clips without source IDs reject; the host preflights managed audio before publishing. Combined gain/mute is one document history edit; no-op settings retain history, clip identities and original assets. Spatter examples use complete-instruction parsing and captured account/project/revision checks. Native compilation, audible playback/export and failure/cancellation acceptance remain deferred.

### Audio help context

Spatter's bounded snapshot now includes four track gain/mute/clip-count records and optional selected-clip timing/gain/mute details, with no source audio bytes or file paths. Local audio guidance reports these facts and combined gain before fades/overlap; it explicitly does not infer audible output. Missing context is reported as unknown. Export/voice/project-copy guidance retains its separate route. Source implementation only; conversation and native acceptance remain deferred.

### Cancellable catalogue audio loading

Library Preview and Add now share a panel-owned asynchronous operation: resource membership and no-symlink regular-file checks, bounded 64 KiB reads with incremental SHA-256 and cancellation, then real decoding of the same pinned bytes. Decoded duration/rate/channels must match the catalogue before playback or attachment. Project/revision leases are rechecked after asynchronous work; preview never attaches and Add creates a clip only after successful preparation. Native responsiveness, cancellation and catalogue-format acceptance remain deferred.

### Lasso-to-Move handoff follow-up

A nonempty lasso uses the existing canonical Move selection, closes the tool-settings popup, resets transform values and enables independent width/height handles for drawings. Image-backed selections retain proportional resizing. The handoff clears obsolete banners only when a transform capture exists; unavailable transforms show an explanation, including the 1,024-object bound. Hand remains viewport panning. Whole-object selection remains the contract; arbitrary raster cutouts are not claimed.

Deferred native acceptance: freehand/rectangle/polygon lasso; immediate box and automatic Move; drag from empty interior; corner/side resize and rotation; one Undo per transform; image/mixed selection; locked/empty/oversized selection; save/reopen. No build, simulator run or device installation performed for this follow-up.

### Native selected frame-range deletion

Frame range & timing now offers explicit, confirmed range deletion using captured frame IDs and one typed command transaction. The UI rejects removing every frame and rechecks project/revision before confirmation applies. Existing canonical deletion, active-frame reconciliation, Undo/history and save behavior apply; audio clip start times stay unchanged. The confirmation never substitutes the currently active frame for stale IDs. Native build, confirmation/cancel, last-frame safety, rollback, Undo/reopen and export verification remain deferred.

### Native frame-range movement

Frame range & timing can now move the explicit selected sequence earlier/later across one neighboring frame. Ordered typed move commands retain internal order, stable identities, exposure and active-frame identity in one transaction. Boundaries disable unavailable directions; captured revision checks reject stale edits. Audio positions are unchanged. Native compilation, boundary/stale cases, Undo/reopen and timeline/export verification remain deferred.

### Paste after a timeline thumbnail

Each native frame context menu now exposes Paste frame after this. The editor inserts the immutable copied frame after the explicit destination ID within its existing copy/history transaction, without preselecting the destination. Missing targets reject instead of pasting after an unrelated active frame. New identities, source assets/effects/exposure and schema handling reuse the canonical copy implementation. The menu requires a frame clipboard, edit readiness and remaining frame capacity; a drawing clipboard is not silently treated as a frame. Native build, non-active/stale destination, Undo/reopen and rendered-output checks remain deferred.

### Native frame cut

Timeline Cut frame removes only the explicit thumbnail ID and replaces the frame clipboard after successful canonical deletion. The view model stages the complete editor before asset preflight, so failure publishes neither deletion nor clipboard change. Last-frame and draft/playback/save guards apply. Undo restores the deleted frame; the clipboard remains available for Paste after this, retaining editable artwork, exposure and managed source references. Native build, clipboard/failure/asset retention, Undo/reopen and rendered-output acceptance remain deferred.

### Typed frame cutting

Manual Cut frame now submits the validated `cutFrame` command instead of a separate editor route. The strict wire decoder accepts only a frame reference; executor resolution, last-frame protection, clipboard staging, revision checks and the shared cut-context guards apply. Mixed batches publish clipboard and document together only after validation. This exposes the operation to authorized command clients; natural-language intent routing and native command/runtime verification are not claimed and remain deferred.

### Local Spatter frame cut

Spatter's explicit “Cut current frame.” example now prepares the same typed command against the captured active frame and revision. The bounded complete-instruction parser rejects extra clauses/control characters and the final-frame case. Existing account/context/cancellation checks guard execution; the receipt summary is enabled by actual removed-frame count, not the prompt. The operation makes no cloud request. Native parser/session, cancellation, clipboard and Undo acceptance remain deferred.

### Relative native frame timing

Frame range & timing now provides Twice as fast and Half speed using captured per-frame exposures. It shows original and resulting duration, scales individual holds rather than assigning one shared exposure, and rounds valid results to whole ticks. Actions that would produce any hold outside 1–600 ticks disable rather than dropping poses or clamping. Typed setFrameHold commands commit one Undo transaction with revision guards; FPS and audio times are unchanged. Native build, mixed/odd holds, stale input, Undo/reopen and audiovisual/export acceptance remain deferred.

### Native GIF output resolution

GIF export now offers Original or a 320/640/960-pixel longest edge, without upscaling or changing project geometry. The canonical compositor renders at the chosen bounded output dimensions; every frame and exposure remains included. The existing total encoded-frame pixel limit uses output dimensions, while source document/raster and byte limits remain. Post-encode frame decoding checks the actual chosen dimensions; the receipt reports them. A 1080×1920 project at 320-pixel output can fit 145 frames under the pixel limit versus four at original resolution. Output remains white-backed, continuously looping and silent. Native compilation, reduced-size pixel/effect parity, cancellation and real file/share acceptance remain deferred.

### GIF capacity guidance

GIF controls now display capacity calculated from the encoder's pixel/frame limits, disable known frame/FPS over-limit starts, and offer an explicit largest-fitting output preset when possible. They disclose remaining source/encoded-byte checks rather than promising success from capacity alone. The session rejects these known limits before cleaning up a previous completed output; the encoder enforces the same calculation. No automatic resize, dropped frames or reduced FPS. Native build, boundary/retained-output and rendering acceptance remain deferred.

### Actual GIF preview playback

The native export result now offers Play/Pause for the completed GIF. Playback decodes thumbnails one frame at a time from integrity-checked output, uses file delays checked against the receipt and a monotonic deadline, and retains only the displayed thumbnail. Output/scope changes cancel its SwiftUI task; backgrounding/account changes pause it. The frame counter describes decoded output, not original project playback. Preview remains silent and does not publish anything. Native compilation, timing responsiveness, lifecycle cancellation, memory and actual-file playback acceptance remain deferred.

### Local sound favorites

The native sound library now offers per-sound stars and a Favorites-only filter combined with category/search/duration/sort. Preferences store only validated catalogue IDs on this device, bounded to 256 entries/64 KiB; unknown IDs are ignored and overflow reports a removable-favorite limit. Filtering resets scroll position; Clear filters returns to all sounds. No audio copies, document mutation or cloud requests. Native UI/persistence/large-library verification remains deferred.

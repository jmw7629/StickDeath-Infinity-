# Android native foundation

This is an additive Kotlin/Jetpack Compose application. It does not replace the iOS SwiftUI app or embed the website. Implementation is staged first at the owner's request; compilation, emulator/device checks and cross-platform integration are deliberately deferred. No build, test, SDK/dependency download or provider request was performed for this batch.

## Implemented local flow

- Create a named project with canvas presets and FPS, browse the scrollable local project library, reopen saved projects.
- Draw colored round pencil strokes and erase only the active layer. Canvas coordinates retain the project's aspect ratio. Hidden/locked layers reject drawing. Interrupted or stale gestures do not commit.
- Add/select/reorder layers, change visibility, opacity and lock state. Layers are shared across timeline frames and rendered front to back consistently.
- Add, duplicate and delete frames, retain at least one frame, change exposure ticks and preview playback at project FPS. Duplicate frames receive fresh frame/stroke identities.
- Bounded snapshot Undo/Redo and a single serialized atomic writer. Edits arriving during a write trigger another write of the latest revision. Back waits for successful saving; a write failure retains the open document/history.
- Private device storage with version checking, bounded file/point/frame/layer sizes and preserved unreadable originals. No network permission or cloud success placeholders.
- Export the current frame as PNG or all frames as a ZIP through Android's system document picker. ZIP includes a versioned timing manifest with FPS, per-frame start/hold ticks, dimensions, source project ID and captured revision. Each frame is encoded once; exposure does not inflate the image count.
- Canvas and export share `FrameRenderer`, including layer order/visibility/opacity, isolated erasers and white background. Export uses one bitmap at a time, a 4-megapixel canvas limit and a 256-MiB output limit. It stages privately before asking for the destination, checks cancellation between rendering/writing operations, and removes owned staging files after normal completion, cancellation or failure.

## Layer and timeline implementation continuation

Layer rename, duplicate and explicitly confirmed delete operate on the whole document. Duplicate creates a fresh layer and fresh stroke identities across all frames; delete removes only the selected unlocked layer and its artwork, keeps at least one layer and restores via the existing Undo history. Timeline Earlier/Later actions retain the frame ID and move its exposure with it, rejecting drawing layers locked against timing changes.

Timeline thumbnails now render actual frame content through the export renderer. Optional onion skin shows one previous frame in red and one next frame in blue at 25% opacity, without wrapping endpoints. Each ghost composites independently, preserving eraser isolation. Playback and export exclude ghosts. These are source implementations, not emulator/device-verified claims.

## Object selection implementation

Lasso selects whole visible unlocked pencil objects, including their stroke-width bounds, and switches a nonempty selection to Move. It does not cut pixels or select eraser operations. The group box supports drag translation, uniform corner scaling and a rotation handle. Selection is transient; transforms and explicit confirmed deletion use document Undo and atomic persistence. Second touches, coroutine cancellation, source revision changes and changed selections cancel the gesture; no last-object fallback exists. Transform commits must keep stroke points inside this Android document's current canvas bounds. Empty selection and excessive outline complexity are reported. No native runtime or cross-platform parity verification has run for this source batch.

## Editable selection clipboard

The single tool-options dialog includes Copy, Cut, Paste, Duplicate and horizontal/vertical Flip for explicitly selected pencil drawings. Copy is transient, Cut stages its clipboard only after the atomic document deletion succeeds, and Paste/Duplicate create fresh identities on the active visible unlocked layer at the original coordinates. Pasted artwork is selected in Move. Clipboard data stays in memory and clears when the project closes; neither the system clipboard nor a server receives it. Flip retains IDs and uses the selection center. Existing capacity/canvas validation rejects impossible edits before history publication. Build and native runtime evidence remain deferred.

## Integration boundaries

The explicitly named `sdi-android-local` JSON envelope is **not** the Swift `.sdi` interchange format. Shared codec/migrations, asset attribution, transparent export, advanced effects, crop/tween, account/community and website synchronization remain future implementation. H.264/AAC MP4 and looping GIF source implementations are described below; native acceptance remains deferred. Project data is private to this application ID; uninstall removes it. PNG exports preserve rendered pictures, not editable project backups. Undo history is session-local. Reference-screen parity and accessibility/device behavior require later integration; no visual parity claim is made.

Document providers control their own writes: cancellation cannot interrupt a provider that blocks within a write. The worker retains ownership until that call returns. If destination writing fails or is cancelled, the UI reports that the selected destination may contain a partial file. It never deletes that arbitrary URI because the picker may have replaced an existing user document. Private staging is removed; a process kill can leave a private cache file for Android cache eviction. A successful export message requires the destination stream to finish and close.

## Deferred build setup and verification

Pinned build inputs are AGP 8.7.3, Kotlin 2.0.21, Compose BOM 2024.12.01, Java 17, Android API 35 (minimum 26). A compatible Gradle 8.9 installation/wrapper and installed SDK are required; no wrapper binary or dependencies have been downloaded. Later integration should supply the team's approved wrapper/signing/distribution configuration. Do not commit local SDK paths or signing credentials.

After the implementation backlog phase, compile first, then exercise creation/drawing/erase, layer isolation and locks, frame timing, Undo/Redo, background/save/close, process restart, corrupted-record preservation and storage failures on emulator and physical Android. Cross-platform interchange requires its own explicit codec acceptance before advertising shared projects.

## Editable shape tools

Line, Rectangle and Ellipse now use canonical editable paths in the existing Android document. Drag previews use the same geometry as the final stroke; rectangle/ellipse options expose fill and equal sides (square/circle) in the single settings panel. Ellipses use a bounded 128-segment closed path, which preserves geometry during rotation and clipboard transforms. Filled paths render through the same frame renderer as thumbnails, onion skin and PNG/sequence export. Lasso, Move, copy/cut/paste, duplicate, flip and delete include these shapes; layer locks, history and atomic saving remain in effect. Shape gestures retain only endpoint-derived geometry and cancel on additional touch/context changes.

The Android-local envelope reads absent `filled` values as false for existing projects; new shape tool names remain explicitly validated. This does not implement the separate iOS interchange contract. Degenerate shape drags do not create artwork. No Gradle/emulator/device run has verified this batch; final rendering, save/reopen and gesture acceptance remain deferred.

## Spritesheet export

The export menu now offers a ZIP containing `spritesheet.png` and `manifest.json`. A bounded row-major layout balances atlas dimensions while preserving every frame at its original canvas size, capped at 8,388,608 atlas pixels and 8192 pixels per edge (the existing 4-megapixel per-frame admission remains). Larger projects fail explicitly with PNG sequence as the alternative; no frame dropping or implicit resizing. The manifest records source revision/project, frame IDs, top-left pixel rectangles, original FPS and per-frame start/hold ticks; unused cells are white. A single atlas bitmap is recycled in a finally block, rendering/encoding uses cancellation checks and the existing 256-MiB staged-file bound, and normal completion/cancellation uses the existing Android document-picker destination and partial-output cleanup. No runtime decode, Gradle or device verification has run for this batch.

## Shared creation and project settings

Creation and the editor's Project settings share eight named canvas presets (including exclusive Portrait/TikTok and Landscape/YouTube aliases) and 6/8/10/12/15/24/30 FPS. The creation draft survives recreation through saveable primitive fields. Existing custom dimensions/FPS remain represented until explicitly changed. Settings capture the current document and reject stale application, rename/reframe/retime in one Undo transaction and use the existing serialized save writer. Fit centers and proportionally scales all frame coordinates while preserving stroke widths; it requires unlocked artwork. Without Fit, coordinates remain unchanged and any point outside the proposed canvas rejects the operation. FPS changes playback duration with exposure ticks unchanged. No destructive cropping, frame deletion or history clearing is performed. Native Android runtime/save-reopen/layout checks remain deferred.

## Frame clipboard

The timeline now exposes Copy frame, Cut frame and Paste frame. The in-memory clipboard is separate from artwork copy/paste, scoped to the open project and cleared on close/open/create. Paste inserts after the selected frame with fresh frame/stroke identities, the copied exposure and editable shapes/erasers, using current project-layer appearance. Changed canvas dimensions, missing/locked layers and frame/document capacity reject a paste. Cut first completes the reversible document mutation, then replaces the clipboard; a rejected cut preserves the existing clipboard and the final frame cannot be cut. The existing full-document history and serial save path retain these changes. Runtime, persistence, cancellation and device acceptance remain deferred.

## Hand viewport controls

Hand now pans with drag and zooms with pinch around the gesture centroid, bounded from 25% to 800%. The tool options include zoom and Fit; zoom slider recenters intentionally. Viewport size or project-dimension changes refit the canvas. A fixed outer gesture surface measures movement independently of the transformed canvas, avoiding pan feedback; drawing hit coordinates remain local to the transformed child. Pan is bounded to retain visible canvas, and selection handle/dash sizing compensates for zoom. This transient viewport state never changes document coordinates, undo history, thumbnails or export. Rotation gestures do not rotate artwork. Uses Compose's native transform detector/graphics layer (official guidance: https://developer.android.com/develop/ui/compose/touch-input/pointer-input/multi-touch). No gesture/device or Gradle verification performed in this implementation batch.

## Rendered-color eyedropper

Eyedropper taps sample a one-pixel render of the canonical current frame, including visible layer compositing/opacity and eraser results against the white canvas. It excludes onion skin and selection UI and does not allocate a full-canvas sampling bitmap. Rendering runs off the UI thread with per-layer/stroke cancellation; stale document/tool/closing results are discarded. A successful sample changes only the drawing color and returns to the preceding color drawing tool. Dragged or multi-touch gestures do not sample. No history entry or project mutation is generated. Device/rendered-pixel acceptance remains deferred.

### Procedural brush implementation (verification deferred)

Android now stores Round, Stipple, Grain, Rough Pen, Calligraphy, Dip Pen, Halftone and Hatch identity plus a repeatable seed in its local v8 format (reads v1–v6 as Round and v7 brush strokes with identity transforms). The canvas and all exports use the same original procedural renderer; gesture preview/commit share a seed. Brush size, opacity and existing input smoothing remain effective. Dip Pen uses direction-dependent width, not claimed stylus pressure. Pattern rendering is not pixel-equivalent to SwiftUI; saved affine nib transforms now preserve procedural patterns during selection resize/rotation/flip, mirroring and project fitting; exact native pixel parity remains unverified. Texture work is bounded per stroke/frame and checks cancellation. Android build, emulator/device, cold-reopen and decoded-output verification are deferred.

Textured transforms retain an invertible bounded linear map and original procedural sampling coordinates. Selection bounds include transformed nib extent. Texture widths outside 1–128px or singular/excessive transforms reject without replacing the document; older Round strokes retain existing behavior. Canvas/export use the same transform. This is implementation evidence, not an emulator/device or export-pixel pass.

### Per-family nib angle (verification deferred)

Calligraphy, Dip Pen and Hatch expose a -180°…180° nib-angle control. Each family remembers its own angle on this device; the angle is captured on each stroke and rendered by the same canvas/export path. Dip Pen uses direction relative to the nib angle. Local format v9 stores this value and reads v1–v8 with the previous 45° Calligraphy/Dip Pen and -45° Hatch defaults. Affine transforms retain the original nib coordinates. Nonfinite/out-of-range document values reject. Native build, on-device interaction, migration/reopen and export pixel checks remain deferred.

### Independent brush preferences (verification deferred)

Each Android brush family now keeps its own width, opacity, smoothing and nib angle. First-use defaults distinguish fine pens, broad nibs and textured brushes. Switching families saves the outgoing settings before loading the incoming family; switching to Eraser or shapes preserves the Pencil family. The prior shared Pencil settings migrate into the previously selected family. Reset this brush restores only that family's four settings, preserving color, mirror, other tools and existing artwork. Invalid stored preferences fall back to defaults. Build and native preference/gesture journeys remain deferred.

### Expanded layer blending (verification deferred)

Layers now expose Color Dodge, Color Burn, Hard Light, Soft Light, Difference, Exclusion, Hue, Saturation, Color and Luminosity alongside the six existing modes. Their stored enum identities feed Android's native BlendMode in the same compositing path used by viewport, eyedropper and exports; existing opacity, lock and document-history rules still apply. The local v10 envelope reads versions 1–9. Android versions before 10 disable unsupported choices and reject projects requiring those modes without replacing their originals. No silent Normal substitution is used. API reference: https://developer.android.com/reference/android/graphics/BlendMode . Build, device rendering, opacity/eraser combinations, undo/reopen and exported-pixel comparison remain deferred.

### Custom project dimensions and timing (verification deferred)

The shared create/settings form now exposes custom width/height (16–4096 pixels), dimension swap and exact integer FPS (1–60), alongside the existing presets and real background picker. Cleared numeric drafts stay invalid and disable Create/Apply rather than falling back to previous values. Existing project-settings transactions retain stale-document guards, optional artwork fitting, full-document Undo and persistence. These controls do not raise export memory/duration limits. Android build, keyboard/layout and create/change/reopen journeys remain deferred.

### Precise selection positioning (verification deferred)

The selection popup now offers remembered 1/5/10 canvas-pixel nudges and six canvas alignment actions. Alignment moves the selected group using its stroke-inclusive bounds; spacing, layer membership, identities and procedural brush transforms remain intact. Both controls invoke the same validated transform transaction as gestures, with existing lock/stale/canvas guards, Undo and persistence. An already aligned group adds no history. Selection bounds are geometric, not an alpha-pixel silhouette. Device gestures/accessibility, bounds/rendering and save/export verification remain deferred.

Frame range editing also supports moving a contiguous range one slot earlier/later,
duplicating it with fresh frame/stroke identities, and explicitly confirmed deletion.
Each operation uses the document's existing single history/save transaction and
rejects stale project snapshots. Deletion preserves at least one frame and refuses
locked-layer artwork. Android build/device acceptance for these additions is deferred.

The frame clipboard accepts a selected range (up to 96 frames), preserving order
and exposure. Copy is non-destructive; Cut changes history once and updates the
clipboard only after successful removal. Paste inserts the entire range with fresh
identities in one transaction. Clipboard content stays project-local and is cleared
on project changes. Build and device acceptance remain pending.

Shape tools include editable Triangle, Diamond, five-point Star and Arrow paths,
in addition to Line, Rectangle and Ellipse. Closed shapes support fill/outline,
size, opacity, color and equal width/height through the existing tool options.
They use the same canonical paths for preview, history, lasso transforms, saving
and PNG/MP4 export. Local document format 11 reads versions 1–10; older builds
reject the newer format rather than silently dropping its new tools. Native
Android rendering and device acceptance for the new shapes remain pending.

## Isolated compiler job

`.github/workflows/android-build.yml` compiles the real debug APK on a standard
Ubuntu runner for Android pull-request changes or manual dispatch. It uses JDK17,
Gradle8.9 and API35 with two workers, a20-minute bound, read-only repository
permissions and no signing/provider credentials. It preserves the source commit,
compiler log and APK checksum for7days. This is a compile/artifact job, not an
emulator/device or cross-platform acceptance gate. The workflow has not run yet.

## Editable text implementation (October 9)

Text is an editable canonical object, not a raster snapshot. The existing tool options accept up to 512 characters across eight lines, an 8–128 pixel font size and an opaque color. Add text with a canvas tap or the top-left action; select it through Lasso/Move and use Edit text to change its source. Four affine corners preserve movement, free resize, rotation and flips without rewriting the words. The shared renderer draws the same source for canvas, thumbnails and exports; layer appearance, explicit deletion, clipboard, full-document history and atomic saves remain in use.

The Android-local envelope is now v12 and reads v1–v11. Text characters count toward the document/history budget. The font is Android system sans serif; wrapping, rich text and embedded-font interchange are not implemented, and glyph metrics can vary across devices. This batch has source review only: compilation and emulator/device journeys remain pending. It does not establish iOS interchange or feature parity.

## Animated GIF export

The existing export popup now has one looping GIF option using the system `image/gif` document destination picker. `GifExporter` renders every stored frame once through `FrameRenderer`, including the chosen canvas/background, visible layers, opacity/blends, isolated erasers, procedural brushes and text; guides, onion skin and selections stay out. GIF has no audio. Full-canvas frames use disposal method 1 and an infinite-loop extension. Odd canvas dimensions are supported without resizing.

The dependency-free `GifEncoder` streams GIF89a with a fixed 256-color RGB332 palette (8 red × 8 green × 4 blue levels), nearest component quantization and no dithering. Black and white are exact; other colors, gradients, neutral grays and antialiased edges can shift or band. There is no transparency; the validated opaque document background is composited first. This is a lossy color export; PNG retains the original composite colors. The deliberately simple LZW encoder writes literal codes and clears every 250 pixels, keeping codes at 9 bits and space constant. It produces larger files than dictionary-compressing encoders, approximately 1.13 bytes per pixel per stored frame plus headers, so large multi-frame projects can reach the output cap well before the duration cap.

Timing comes from frame holds and integer project FPS. Each cumulative frame boundary is rounded to the nearest centisecond, ties upward; a frame delay is the difference of successive rounded boundaries. This avoids accumulated per-frame rounding drift: each boundary and the final cycle duration differ from source time by at most 5 ms. For example three one-tick frames at 24 FPS produce delays of 4, 4 and 5 centiseconds. All frames have a positive delay at the supported 1–60 FPS. Some GIF viewers clamp short delays (especially 1-centisecond frames); playback speed in those viewers is not guaranteed.

Admission limits are 4,194,304 canvas pixels, document dimensions 16–4096 per edge, at most 500 stored frames, and 120 seconds of source duration including holds. The staged output is capped at 256 MiB and encoding at ten minutes. Encoding retains one ARGB bitmap (at most 16 MiB), one pixel row (at most 16 KiB), a 255-byte GIF block and a 64-KiB file buffer, in addition to the existing document and shared renderer's temporary layer/compositing memory. It does not retain multiple bitmaps or indexed animation frames. Cancellation/time checks run at frame/layer/render checkpoints, every pixel row and GIF sub-block/write; a native render or blocking provider write cannot be interrupted until it returns.

Failures/cancellation recycle the bitmap and remove the exporter-owned private staging file. The shared destination flow removes staging after successful save, cancellation or failure; it reports a possible partial destination rather than deleting a provider URI that could have replaced an existing user file. Process death can leave private cache files for Android eviction. No build, runtime decode, device/picker/cancellation or image-comparison acceptance was run for this implementation batch; those checks remain deferred.


### Bucket fill implementation (acceptance pending)

Fill samples the merged visible frame and commits stable pixel runs to the active unlocked layer. The single tool popup supplies a color, RGB tolerance and contiguous/global mode. Computation runs off the UI thread with cancellation and document/settings revision guards; a successful operation uses one ordinary history/autosave change and the shared canvas/export renderer. Android-local storage v14 reads v1–v13; v13 fills acquire an identity mapping and their original canvas extent.

The bounded implementation admits up to 4,194,304 canvas pixels (16–4096 per edge), including the default 1080×1920 portrait, 1920×1080 landscape, 1080×1350 and 2048×2048 canvases. The limits remain 20,000 runs and five seconds per fill; runs count against existing document/history budgets, so canvas admission does not guarantee a complex fill will complete. Fills now participate in whole-object lasso/rectangle selection, move, resize, rotate, flip, copy/cut/paste, duplicate, ordering, layer transfer and delete. Lasso conservatively requires enclosure of the complete transformed bounding box, including disconnected-region gaps. Each fill retains immutable source spans and source extent plus a durable affine mapping; gestures and canvas Fit artwork compose that mapping without allocating a resampled mask. Bounds use all transformed span edges rather than the old seed point. Shared rendering applies the same mapping for the editor, thumbnails, onion skin, color sampling and exports, retaining hard pixel edges. Canvas resize without fitting rejects any fill edge that would be clipped; fitting follows existing layer locks and history. Transforms outside the canvas, nonfinite or effectively singular mappings are rejected atomically. Repeated extreme reductions may reach the minimum supported determinant and are rejected rather than destroying source pixels. Runtime acceptance of these additions remains deferred.

At the pixel limit, Fill owns a 16 MiB ARGB bitmap while rendering. It allocates its 16 MiB readback array after rendering releases saved layers, reads in 32-row strips with cancellation checkpoints, and recycles the bitmap before classification. Contiguous classification uses a 16 MiB pixel array, 4 MiB state array and fixed 16 MiB integer queue (36 MiB total); global mode omits the queue (20 MiB). Each pixel enters the queue at most once. These figures exclude array/object overhead, at most 20,000 result objects, the existing document/history, and Android renderer/native layer and compositing buffers; they are not a process-memory guarantee. Low-memory devices can still fail allocation; Fill catches allocation exhaustion after bitmap cleanup and reports that no fill was added. Cancellation and the five-second deadline are checked between render operations, readback strips, every 4096 classified pixels and every output row; native allocations/draws/copies cannot be interrupted before returning. Compilation, device journeys, cancellation, memory profiling and decoded export verification remain pending; this is not Android parity acceptance.

### Project-owned image import (implementation; acceptance deferred)

Studio's **Import image** opens Android Files for still PNG/JPEG. Android 9/API28 or newer is required for import: the built-in ImageDecoder applies EXIF orientation, converts to sRGB and normalizes to PNG with alpha retained. Android 8 can reopen the normalized PNGs but reports import unavailable. Animated PNG and other formats are explicitly rejected. The working copy may be downsampled; the external original is untouched. No provider URI or durable external-file permission is stored. Android-local v15 embeds normalized PNG bytes and still reads v1–v14. This is not native iOS `.sdi` interchange.

The image enters the captured frame/layer as one selected affine object, centered and fitted inside 80% of the canvas. Existing selection operations supply move, resize, rotate, flip, clipboard, ordering and deletion; the same bitmap renderer serves canvas, onion skins, sampling, fill inputs and PNG/GIF/MP4 exports. Four corners preserve the original normalized pixels through transforms. A successful insertion is one undo/autosave transaction. Project edits, close, playback and explicit cancellation invalidate pending import; a changed document or hidden/locked layer rejects insertion. Files cancellation, corrupt input, unsupported format, timeout, storage admission or allocation failure adds no artwork. Disk-write failures retain the edited document and the prior atomic save.

Bounds: source at most 8 MiB, 32,000,000 pixels and 16,384 pixels per edge; normalized image at most 1,048,576 pixels, 2,048 pixels per edge and 1 MiB PNG. Large input is proportionally downsampled, but an encoded PNG over the limit is rejected rather than repeatedly recompressed. Each document admits at most 4 MiB encoded image bytes and 4,194,304 image pixels summed across all image occurrences (duplicates/frames count again). The current 24 MiB serialized JSON, 10,000 objects and 100,000 drawing-point limits also apply. Each undo/redo stack is capped at 8 MiB image bytes and 8,388,608 image pixels in addition to its existing 32-document/200,000-point budget. History, clipboard, duplicate frames and export snapshots share immutable image objects/bitmaps; loading repeated identical PNG strings deduplicates within that document. Rendering never re-decodes images or uses an unbounded global cache. Retained resources are released through ordinary Android garbage collection when the last document/history/clipboard/export reference disappears.

One mutex serializes decoders, including cancelled work still unwinding in native code. Cancellation and a 30-second deadline are checked around provider reads, decode and PNG writes. Blocking provider reads and native decode/compression cannot be forcibly interrupted before returning. Normalization temporarily retains encoded source copies plus decoded and normalized bitmaps; JSON/Base64 buffers, renderer layers, native decoder memory and other app state are additional overhead. These limits are admission bounds, not a process-RAM guarantee. No new dependency downloads or build changes were needed. Compilation, device Files/lifecycle/cancellation journeys, EXIF fixtures, malformed PNG fixtures, memory profiling, atomic save/reopen and decoded export comparisons are deferred; this implementation is not verified Android parity.


### Selected artwork opacity

Move's existing options now apply a chosen opacity to all selected drawings, text, imported images and fills in one history transaction. The draft resets when the document revision or selection changes; commit rechecks the captured document, selection and layer locks. A no-op creates no history. Canvas, thumbnails and exports use the same stored opacity multiplied by layer opacity. Zero makes artwork invisible and clears its visible selection; Undo restores it. Android-local v16 reads v1–v15. Build and rendered save/reopen/export acceptance remain pending.

### Local audio clips (Android format v17)

Audio in the existing options popup imports actual Files WAV data into immutable project-owned storage. It accepts ordinary RIFF PCM WAV only: 16/24-bit little-endian, mono/stereo, 8–48 kHz, one sample–60 seconds, 4 MiB per source. Projects allow 16 clips and 8 MiB audio total, subject to the 24 MiB serialized project limit. Versions 1–16 open with no audio. Embedded sources survive provider access loss, backups, duplicates, deletion/undo and restarts; no external URI or file reference is retained. Atomic project saving retains the prior file on failure.

Select a clip explicitly to edit its name, timeline start (0–3600 seconds), source trim, duration, track (1–4), volume and mute. Apply creates one captured-revision history transaction; stale imports and edits are rejected. History is additionally bounded to 16 MiB of referenced audio across retained snapshots. Trimmed single-clip preview streams real PCM through AudioTrack in bounded buffers, applies saved volume/mute, and is cancellable on Stop, panel dismissal, editing, scene playback, activity stop, project close and ViewModel teardown. Source imports check cancellation between bounded reads.

Scene playback and MP4 use the shared saved-clip mixer, as described below. Audio-free projects continue to export a single video track. Measured source waveforms are implemented below; the bundled sound library is implemented below. Device codec/output behavior, focus/interruption behavior, import/history/backup round trips and Android compilation remain deferred acceptance checks under the current owner instruction; implementation is not device verification.


### Bounded MP4 soundtrack implementation

For projects containing clips, `AudioMixer` produces deterministic 48 kHz stereo PCM16 in small blocks at absolute output sample positions. It applies timeline placement, source trim, volume and mute; maps source rates by linear interpolation; duplicates mono into stereo; sums overlapping clips on all four tracks; and saturates the final sum to the signed PCM16 range. Tracks are grouping labels, not solo buses. Gaps and muted clips yield silence. Audio is cut to the animation duration, with at most one PCM sample of rounding; clips beyond the animation do not extend the video. This is basic linear resampling, without mastering effects or a bandlimited resampler.

The exporter first produces and inspects the existing canonical H.264 video, then encodes the mix as AAC-LC at 128 kb/s and remuxes both tracks without re-encoding video. AAC encoding is bounded to three minutes for the audio/remux stage, a 15-second no-progress timeout, an 8 MiB audio intermediate, small PCM blocks, and an 8 MiB remux sample buffer. The final container remains capped at 256 MiB (250 MiB payload). Intermediate files are deleted after success, failure or cancellation; failing or unavailable AAC never returns the silent video as fallback.

The completed container is inspected for exactly H.264 + AAC, original dimensions, every video tick and timestamp (1 ms MP4 timescale tolerance), stereo 48 kHz audio, monotonically spaced AAC packets, and audio coverage. AAC packet timing is normalized from its first encoded timestamp; encoders with more than four 1024-sample AAC packets (4096 samples, about 85.3 ms at 48 kHz) of initial offset or tail padding are rejected. Codec-reported encoder delay/padding metadata, when supplied within the same bound, is forwarded to the final muxer; Android muxers and players may ignore those hints. Normalizing the first packet timestamp can retain encoder priming as an audible delay. Codec priming and padding can still add up to four AAC packets and vary by device/player; this is not a sample-exact audio master or a decoded-audio acceptance result. Video duration remains independently exact within the existing tolerance. The single-clip preview uses source PCM; scene playback uses the shared mixer described below.

Compilation, real-device codec runs, decoder-based alignment/amplitude checks, trim/overlap/resampling cases, playback and cancellation/storage failure journeys remain deferred acceptance. No new dependency, downloaded codec, external service, build or device verification was used for this implementation batch.


Scene playback now uses the same PCM mixer when clips exist. AudioTrack's consumed-sample counter drives animation frames from the selected frame to the project end, with a 120-second project limit and no silent fallback. Focus loss, backgrounding, navigation, edits and cancellation stop playback. The stream holds one 1024-frame block plus AudioTrack's device buffer; it serializes against selected-clip preview. Silent projects retain their existing loop. Actual device A/V alignment, focus/lifecycle, cancellation and end-of-playback acceptance remain deferred.

### Four-track waveform timeline

The Audio panel now includes four scrollable lanes with real PCM peak envelopes, selected-clip highlighting, long-press move across time/tracks, right-edge trim and frame snapping. Gesture drafts commit once through the existing captured-document command; cancellation or stale revisions cannot write partial edits. Numerical timing, source trim, volume and mute fields remain available for accessibility, overlaps and fine edits. Peaks scan every source sample off the UI thread, cache at most 16 sources (up to 16 MiB of WAV bytes plus 64 KiB of envelope values), and reflect the selected source trim before volume/mute. No random waveform is used. Timeline width is capped at 24,000 dp; distant clips reduce the display scale. Tapping the ruler selects the animation frame containing that time (exposure holds respected); taps beyond the animation select its last frame. The red marker shows the selected frame start. This is frame navigation, not audio audition. During scene playback the red cursor instead follows the same transport clock as animation and scrolls into view. Dragging near either viewport edge scrolls at a bounded speed while keeping the draft under the pointer; continuous audio scrub audition remains outstanding.

Android CI passed on public cf1883c1845a6e30020577db652ef796a36ff1ea before this timeline addition (run 37989605008). This new timeline still needs compilation and on-device gesture/accessibility acceptance; the earlier build is not evidence for these new files.

### Selected audio split and duplicate

The selected-clip editor now exposes Split at a numeric timeline time and Duplicate after the saved clip's end. Split snaps to the source sample boundary, keeps a minimum one source sample per part, preserves source bytes/trim/track/gain/mute, and gives the second part a fresh identity. Duplicate retains settings with a fresh identity. Both expand the existing portable representation, so each clip counts toward the 16-clip/8-MiB budget. The full encoded backup is checked off-main before one guarded history transaction. Cancellation, document changes, invalid timing or capacity failures leave the original timeline untouched. UI, compilation and actual save/reopen/output acceptance for this addition are pending.

### Source-time audio fades

The saved clip inspector exposes fade-in/out lengths and an explicit reanchor-to-trim option. Linear fades multiply the real PCM in selected-clip preview and the shared scene/MP4 mixer. The fade anchor uses original source time, so trimming or splitting does not restart its phase; duplicate retains that curve. Changing lengths or reanchoring builds a new envelope across the current trim. Zero/zero removes it. Nonfinite, negative, overlapping or out-of-source spans reject without a history change. Waveforms remain raw measured peaks before gain/fades. Local format v18 reads v1–v17 with no fade, while older versions reject v18 instead of losing audio behavior.

Source inspection and whitespace checks completed. Compilation, device playback, split continuity, backup migration and decoded exported-audio acceptance remain pending; the Mac has no local Java runtime/Kotlin compiler and no Android toolchain was downloaded. Existing GitHub Android CI will cover compilation when the queued batch is published after the live native run.

### Independent audio track mixer

Four persisted track gains/mutes now multiply saved clip gains in selected-clip preview, scene playback and MP4 mixing. Changing a drawing layer does not change audio. Each track slider commits on release, and mute changes use the same revision-guarded undo transaction. Muted tracks dim their measured waveform. Local format v19 migrates v1–v18 to four unmuted unity-gain tracks; malformed/missing v19 track settings reject while retaining the original file. Compilation, device interruption behavior, mixer/export sample checks and migration/reopen acceptance remain pending for this queued batch.

### Audio-panel transport cursor

The audio panel now has its own scene Play/Stop control. During mixed playback its red cursor uses the consumed-sample transport time already driving animation, and scrolls into view. Silent scenes use the existing display-frame clock. Stopping restores the selected-frame marker; playback does not save transient cursor positions or add history. This is not a new device synchronization pass: compilation, long-timeline scrolling, audio interruptions and physical-device alignment remain pending for the queued batch.

### Shared offline sound catalogue

Android now packages the existing native StudioSounds directory directly through Gradle assets: 2,127 CC0 effects, 98,538,127 source bytes, plus catalogue and credits. No duplicate source-asset checkout or network download is introduced. Search matches titles/tags/creators; categories and 12-item pages bound the displayed UI. Creator, source URL and CC0 link remain visible. Preview verifies the selected asset hash and plays decoded PCM without inserting a clip; Add uses the existing asynchronous full-backup preflight and one captured-revision history transaction.

Catalogue parsing is bounded to 8 MiB and validates schema, unique hash-derived paths and metadata; all 2,127 checked-in files were independently size/SHA-256 checked with zero mismatches. WAV follows the existing PCM16 parser; AAC/M4A uses MediaExtractor/MediaCodec with cancellation, a 30-second deadline, 5-second stall limit and cleanup. Output must fit existing 1-MiB source / 2-MiB project limits. Some catalogue entries are too short, oversized, or use unsupported WAV encoding: they remain discoverable but fail explicitly instead of being truncated or replaced. This is not a claim that every catalogue sound is already insertable on Android. Decoded-duration metadata, codec delay and device behavior remain acceptance work.

The new library and preceding timeline/mixer batch await GitHub compilation and device acceptance. The catalogue adds roughly 98.5 MB to uncompressed application assets; release packaging/size acceptance is still outstanding.

### Catalogue format compatibility and bounded capacity (v20)

Inspection of the actual 2,127-entry catalogue found 79 PCM24 WAVs and five effects shorter than 20 ms; all remaining WAVs are PCM16. The largest metadata-derived PCM16 size is 3,200,484 bytes. The importer now normalizes PCM24 to signed PCM16 at the same sample rate/channel layout, retains short effects down to one source sample, and allows 4 MiB per source. Clip trims/splits share the one-sample minimum. Existing PCM16 input bytes remain unchanged. Library masters stay untouched.

Project audio is capped at 8 MiB/16 clips, portable JSON at 24 MiB, audio-history accounting at 16 MiB (retaining at least the latest undo snapshot), and waveform source-cache retention at 16 MiB/16 entries. v20 reads v1–v19; earlier app versions reject v20. These bounds cover every catalogue entry's recorded PCM size without silently truncating effects. Actual device decoding and complete catalogue insertion remain unverified; metadata size coverage is not a playback/compatibility pass.

### Backup and one-sample boundary follow-up

Project duplicate/restore now creates fresh audio clip identities while preserving their source, fade and track metadata. Restore deduplicates identical embedded WAV strings into shared immutable source objects within that document; each clip still counts toward the serialized audio budget. Split boundaries now align in absolute source time even after a fractional trim, with only a 1e-12-second numerical allowance at the one-sample minimum. Runtime backup/undo/export acceptance is still pending.

### Timeline edge scrolling

Clip move/trim gestures now scroll within the existing timeline bounds when held near either viewport edge. Speed scales with edge proximity and is capped at 240 dp/sec; elapsed-frame clamping prevents jumps after stalls. The local draft tracks viewport coordinates plus current scroll position, then performs the existing single revision-guarded command on release. Pointer cancellation, revision changes or disabled editing discard it. This remains pending Kotlin compilation and real touch/cancellation/scroll interaction acceptance.

### Short streaming preview startup

Read-only independent review identified that very short effects or scenes might never fill AudioTrack's initial streaming threshold. Both preview paths now append bounded zero PCM only when required to reach the actual buffer size, retaining the original logical end for completion and leaving project/export audio unchanged. Writes remain nonblocking, cancellable and within the caller's existing timeout. Android's documented initial threshold is buffer capacity: https://developer.android.com/reference/android/media/AudioTrack#getStartThresholdInFrames() . Device startup/routing behavior remains unverified.

### Bundled image library implementation

The Studio image library shares the native catalogue of 207 Kenney CC0 images, packaged under StudioImages/ to avoid the sound catalogue filename. Search, categories, twelve-image pages, source credits and bounded previews lead into the same cancellable, revision-guarded image import transaction as Files. Imported artwork is selected in Move and participates in project persistence, undo and exports. Catalogue and license files are pinned and selected image bytes are hash-checked. Android compilation, packaged asset inspection and device acceptance are deferred; this is implementation scope, not a verified release.

### Durable asset credits (format v21)

New bundled image and sound imports retain asset ID, original source digest, title, creator, source URL and CC0 license in their canonical artwork/clip. Ordinary copy, split, duplicate, undo and project backup retain those fields; deleting an asset removes its occurrence from the derived report. v21 reads previous project versions without inventing missing attribution.

The export menu writes a separate project asset-credits JSON file; PNG sequence and spritesheet ZIP exports also include it. The report includes hidden/muted assets, identifies images/audio lacking recorded provenance, and explicitly describes original hashes as pre-normalization hashes. Metadata from imported backups is not a rights certification. Standalone MP4/GIF/PNG bytes are unchanged: use the separate credits file alongside them. Compile, migration and runtime export acceptance remain deferred.

### Two-sided audio trim

A selected clip exposes both trim edges. The nearer edge wins on short clips. Left trim adjusts timeline start and source offset together while preserving the right edge, source-time fade curve and credits; left extension is bounded by existing source samples and time zero. Right trim keeps the source start fixed. Frame snapping, minimum one-sample duration, cancellation, edge autoscroll and one-command undo apply to both. Precise numeric controls remain available. Touch and device audio acceptance are deferred.

### Rotoscope still at the animation playhead

Video frame opens Android Files and copies the selected content URI into importer-owned staging (32 MiB input, two-minute duration, 8192-pixel edge / 32 megapixel source). The active animation frame's exposure-aware start selects source time. `MediaMetadataRetriever.OPTION_CLOSEST` retrieves a nearby actual decoded frame, bounded to 1024×1024, normalized into the existing 1 MiB image model. It is not an exact decoded presentation-timestamp guarantee.

The canonical image import worker provides revision/layer checks, bounded backup preflight, cooperative 30-second deadline, cancellation and one undo command; device codecs/provider reads can remain inside a platform call until they return. The result is a project-owned still independent of the video URI, automatically selected for Move. Private staging is removed after extraction; the serialized importer clears its abandoned staging before its next import. Original videos are never deleted. Full video tracks, trim ranges, audio extraction and rotation/device acceptance remain outstanding; this operation is explicitly labeled as one still-frame import.

API behavior: https://developer.android.com/reference/android/media/MediaMetadataRetriever#getScaledFrameAtTime(long,int,int,int)

### Compressed Files audio import

The audio picker now accepts audio files and routes compressed sources through the same bounded MediaExtractor/MediaCodec PCM decoder as bundled M4A. AAC, MP3, FLAC, Vorbis and Opus are admitted when the device supplies a compatible decoder; RIFF PCM16/24 WAV keeps its original parser. Imports require exactly one audio track, mono/stereo 8–48 kHz PCM16 output and nonempty duration up to 60 seconds. Encoded files and decoded WAV each must fit 4 MiB. Encrypted packets, unsupported codecs, stalls and changing output formats fail without adding a clip.

Only importer-owned staging is created, serialized and cleaned after completion or before the next compressed import following a crash. Provider originals remain untouched, and normalized audio is embedded in the canonical project/undo/backup path. Provider reads use cooperative cancellation and a 30-second deadline; codec decoding has its own 30-second total/5-second stall bounds. Platform calls can return after cancellation. Codec, timing/priming and device acceptance are deferred.

Audio import reports concrete read/decode/project-preparation stages with an indeterminate progress bar. During compressed decoding, the displayed seconds come from the PCM byte count, sample rate and channel count, throttled to twice per second; no estimated completion percentage is fabricated. Cancelling or completing clears the operation status, and callbacks respect cancellation and the captured document. Runtime acceptance remains deferred.

### Device-local library collections

Sound and image browsers offer All, Favorites and Recent imports alongside category/search filters. Each library stores at most 256 favorite catalogue IDs and 50 distinct recent successful imports, newest first; previews and cancelled imports do not count. Clear recent imports preserves favorites and all project media. Unknown catalogue IDs are retained in preference storage but omitted from current results, so a temporary pack change does not erase choices. Corrupt or unsupported preference records are preserved with an error instead of overwritten. These settings stay in app-private preferences and do not contact a server. Restart/filter/limit and concurrent import UI acceptance remain deferred.

### Single movable Studio toolbar

The existing Android tool/action strip now lives in one white rounded floating rail over the canvas. Its dedicated handle drags without turning tool-button taps into canvas strokes. Releasing near either side docks it vertically; moving it inward restores horizontal layout. Only the rail scrolls its tools. A handle menu and accessibility actions provide left/right docking, horizontal float, collapse/expand and reset without dragging. Normalized position/dock/collapse state survives activity recreation and clamps within changed viewport bounds. Drawing tools still open the existing Settings popup; frame/timeline controls retain their separate lower location.

This replaces the old fixed top tool row; it does not add a second tool rail or redesign SwiftUI. Adaptive layout, gestures, TalkBack and device visual acceptance are deferred.

### Compact-height editor

On windows below 480 dp tall, frame thumbnails default off while selectable frame/exposure chips remain visible. The lower controls let creators restore or hide thumbnails without changing frames or history. Project titles and the status line have bounded wrapping so long names/errors cannot consume the canvas; tapping status opens the complete current notice and project details in the existing dismissible sheet. Manual thumbnail choice survives activity recreation. Landscape, multi-window and large-text acceptance are deferred.

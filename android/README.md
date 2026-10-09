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

The explicitly named `sdi-android-local` JSON envelope is **not** the Swift `.sdi` interchange format. Shared codec/migrations, image/audio assets and attribution, transparent export, advanced effects, crop/tween, account/community and website synchronization remain future implementation. Silent MP4 and looping GIF source implementations are described below; native acceptance remains deferred. Project data is private to this application ID; uninstall removes it. PNG exports preserve rendered pictures, not editable project backups. Undo history is session-local. Reference-screen parity and accessibility/device behavior require later integration; no visual parity claim is made.

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

Fill samples the merged visible frame and commits stable pixel runs to the active unlocked layer. The single tool popup supplies a color, RGB tolerance and contiguous/global mode. Computation runs off the UI thread with cancellation and document/settings revision guards; a successful operation uses one ordinary history/autosave change and the shared canvas/export renderer. Android-local storage v13 reads v1–v12.

The bounded implementation admits up to 4,194,304 canvas pixels (16–4096 per edge), including the default 1080×1920 portrait, 1920×1080 landscape, 1080×1350 and 2048×2048 canvases. The limits remain 20,000 runs and five seconds per fill; runs count against existing document/history budgets, so canvas admission does not guarantee a complex fill will complete. Fill selection/transforms and changing canvas size with fills are explicitly unavailable in this slice.

At the pixel limit, Fill owns a 16 MiB ARGB bitmap while rendering. It allocates its 16 MiB readback array after rendering releases saved layers, reads in 32-row strips with cancellation checkpoints, and recycles the bitmap before classification. Contiguous classification uses a 16 MiB pixel array, 4 MiB state array and fixed 16 MiB integer queue (36 MiB total); global mode omits the queue (20 MiB). Each pixel enters the queue at most once. These figures exclude array/object overhead, at most 20,000 result objects, the existing document/history, and Android renderer/native layer and compositing buffers; they are not a process-memory guarantee. Low-memory devices can still fail allocation; Fill catches allocation exhaustion after bitmap cleanup and reports that no fill was added. Cancellation and the five-second deadline are checked between render operations, readback strips, every 4096 classified pixels and every output row; native allocations/draws/copies cannot be interrupted before returning. Compilation, device journeys, cancellation, memory profiling and decoded export verification remain pending; this is not Android parity acceptance.

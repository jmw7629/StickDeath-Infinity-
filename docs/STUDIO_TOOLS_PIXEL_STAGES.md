# Studio tools: brush behaviours, gradient, selection masks and wand (wave 4)

Scope: issues #142 (brush families), #149 (gradient and selection-limited
effects) and #153 (wand). This records what the production sources now do,
what is wired into the app and what is still open. Nothing here is verified on
macOS or a device yet; every Swift check below is **deferred to macOS CI**.

## #142 — Airbrush Build-up, Watercolor Bleed, Neon Additive glow

`StickDeathInfinity/Models/StudioBrush.swift`, `Services/StudioBrushRenderer.swift`

| Setting | Family | Behaviour | Default |
|---|---|---|---|
| `buildup` 0…1 | Airbrush | Elapsed time between timestamped samples owes dabs at `buildup × 60` per second. Dabs already placed by spacing pay that debt, so quick strokes are unchanged; dwelling or slow motion adds real overlapping dabs. At most 64 extra dabs per position (the rings saturate), so a long hold never fails. Untimed samples add nothing. | 0 (historical geometry) |
| `bleed` 0…1 | Watercolor | Four faint seeded blooms per dab with centres at 0.4–1.0 × size from the dab, so pigment spreads past the brush edge. Drawn after the historical marks, so Bleed 0 keeps the previous random sequence and pixels. | 0 |
| `additiveGlow` | Neon | The finished stroke composites plus-lighter in both CoreGraphics and SwiftUI. Marks inside the stroke still draw normally; geometry is unchanged. | false |

The new keys are written to JSON only when changed, so existing settings encode
byte-identically. Values outside 0…1 reject. Families other than the owner
family ignore the setting (same rule as Grain).

Live preview: UIKit sends no touch events while a finger is perfectly still, so
dwell shows up when the next sample or the lift arrives (the lift carries the
elapsed time). The help text in the wiring patch says so.

Tests added to `Tests/StudioBrushes/main.swift` (4 groups): exact dab counts for
a held stylus at 0/25/100 % build-up, saturation cap, quick/untimed strokes
unchanged; bleed ink beyond radius 20 px; additive halo over a 50 % gray
backdrop never lowers green/blue and raises red, in both renderers; Codable
persistence/rejection.

### Not wired yet (owner of these files must apply)

Persisting the settings in documents and exposing controls needs
`StudioBrushDescriptor` (Models.swift), `StudioViewModel` and its
`StudioDrawingToolPreferences.Entry`, plus the popup controls. A ready patch
that applies cleanly to the wave-4 base is attached to the wave-4 report
(`brush-wiring.patch`): descriptor version 3 (older builds reject rather than
silently drop the effect), per-tool preferences, Build-up/Bleed sliders and an
Additive glow toggle in the existing sole options popup. After applying, rerun
`scripts/verify_control_index.py` and add rows for `studio.brush.buildup-help`
and `studio.brush.additive-glow`.

## #149 — Gradient tool pixel stage and selection-limited effects

`Services/StudioGradientFill.swift`

- Linear or radial, 2–16 sorted stops, opacity, sRGB or linear-light
  interpolation, deterministic 4×4 ordered dither (never moves a value more than
  one level), and alpha lock (source-atop: transparent pixels stay transparent
  and every pixel keeps its alpha).
- Paints premultiplied RGBA8 within an optional coverage mask (fill region,
  wand selection or feathered selection). Unselected pixels stay byte-identical.
- Bounded to 4096 × 4096 and 4 194 304 pixels; checks cancellation per row;
  on any error or cancellation the bitmap is unchanged. Returns the changed
  pixel count and bounds for undo/dirty-rect use.

`Services/StudioSelectionMask.swift`

- `clip(original:effected:coverage:)` — the missing step for selection-limited
  Blur/Sharpen/Smudge/Dodge/Burn: unselected pixels are byte-identical to the
  original, fully selected pixels equal the effect, feathered edges interpolate
  premultiplied values (always valid premultiplied RGBA).
- `combine` (replace/add/subtract/intersect, fractional), `feather` (three box
  passes, O(pixels) for any radius ≤ 64), dense↔sparse span conversion and
  bounds.

Still open for #149: the effect sessions in `StudioDocument.swift` still reject
an active element selection (around lines 896–906). Replacing that rejection
with "capture → effect → `StudioSelectionMask.clip` with the rasterised
selection" and adding a Gradient entry to the toolbar/popup are edits in
`StudioDocument`/`StudioViewModel`/`StudioCanvasView`, outside this wave's
ownership.

## #153 — Wand on drawing layers and the composite; drawn-element selection

`Services/StudioSelectionMask.swift`

- `StudioWandRegion.select` runs tolerance plus contiguous/global sampling
  (reusing `StudioFillRegion`) on any captured straight RGBA surface — the
  active drawing layer or the composited visible canvas — not only managed
  image layers. It rejects a transparent seed on the active layer (an empty
  pixel must not select the whole background), allows it for composite
  sampling, feathers, and combines with the previous selection
  (new/add/subtract/intersect). Cancellation propagates without a result.
- `StudioSelectionElementHitTest.elements` maps a canvas selection to the
  editable `DrawnElement`s it touches, using transformed centreline samples and
  half stroke width, a coverage threshold (so faint feathered pixels do not
  select) and an optional minimum overlap, within an 8 000 000-probe budget.
  Selected elements stay editable vectors; nothing is flattened.

Still open for #153: calling these from the Wand gesture for drawing layers,
converting each `DrawnElement` to candidate samples, and native verification
of zoomed input and downstream move/delete/copy.

## Standalone test and CI step

`Tests/StudioPixelTools/main.swift` (gradient ramp/radial/coverage/
alpha lock/controls/failures/fill region; masks; feather; clip; wand; element
hit test; 14 groups). It needs a new step in `.github/workflows/spatter-client-verify.yml`
(`ci-pixel-tools.patch` in the wave-4 report). The expected values were
cross-checked with a Python port of the same arithmetic on Linux; that is not a
substitute for running the Swift test.

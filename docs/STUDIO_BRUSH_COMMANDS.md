# Styled brush commands

The existing local `draw` command accepts an optional `brush` on each stroke. It uses the same `StudioBrushDescriptor`, immutable sample capture, geometry limits, document rendering and history as manual Studio drawing. Omitting `brush` preserves historical unstyled drawing. `StudioCommandContext.supportedBrushFamilies` lists the available families.

A complete example descriptor is:

```json
{"version":1,"family":"neon","seed":42,"smoothing":2,"pressureEnabled":false,"tipAngleDegrees":45,"texture":0.6,"grain":0.3}
```

The family must be one of the native library entries. `texture` means Flow for Airbrush, Pigment for Watercolor, Glow for Neon, or the existing texture setting for textured families. Watercolor also uses `grain`. Size and opacity come from the containing stroke's `width` and `opacity`; they are never duplicated in the descriptor. Gradient requires a validated opaque `gradientEndColor` with `red`, `green`, `blue`, `alpha`. Calligraphy tilt requires descriptor version2 and `tiltEnabled:true`; optional sample `tilt` has finite `altitude` in 0…π/2 and `azimuth` in 0…2π (exclusive upper bound). Typed samples express requested artwork, not proof of physical Pencil measurement.

Styled commands are limited to Pencil, Pen, Brush, Marker and Crayon. Mixing brush with shape, eraser or text descriptors fails atomically. Unknown descriptor/color/tilt keys fail strict wire validation. Stable UInt64 seeds reproduce texture. The normal request size, point, generated-element, geometry, document and cancellation limits still apply. A later invalid stroke rolls back the entire request and preserves selection/history.

`updateLayer.settings.lock` accepts `alpha`. Supported brush painting on that layer records the canonical alpha-preserving operation; hidden/full/zero-opacity layers and unsupported alpha-locked operations remain rejected. New brush families require document schema25; alpha-preserving paint requires schema24 and measured/requested tilt requires schema23. The editor upgrades versions after validation, with full-document undo/redo.

A caller must already have edit authority and current project/revision context. This transport adds no network request, shell/admin capability, provider access, automatic publication or permission to access a different project. It does not by itself implement natural-language planning. Import, render/export and owner-approved release remain separate interfaces. Tests exercise the production strict decoder, transaction editor, VM persistence and an offline network trap; native UI/device validation is a separate gate.

## Line arrowheads

The existing Line tool's sole options popup offers None, Start, End and Both arrowheads with a 1–100 document-pixel head length. No extra toolbar is introduced. Line angle snap, fixed rulers and mirror apply before capture; the descriptor is immutable for an in-flight stroke. Heads are capped to the shaft length (half per head for Both); zero-length lines have no head triangles.

Typed `draw` can use `tool:"line"` and `shape:{"version":2,"cornerRadius":0,"arrowEnds":"end","arrowLength":24}` with two endpoints. Fill and brush descriptors cannot be mixed into an arrow. This records schema26 artwork, shares transformed selection bounds and composites shaft/heads once at the stroke opacity. Historical rectangle/circle version1 and plain lines are unchanged. Persistence, export and Undo/Redo use the same geometry; this API does not authorize publication.

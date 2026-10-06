# Nondestructive imported-image crop

Crop image lives in the existing Move tool popup. Left, Top, Width and Height use percentages of the upright original, before reflection or quarter-turn rotation. Apply commits one reversible edit; Cancel leaves the project untouched. Full image restores the original source region.

The crop is normalized schema-22 document metadata. Each dimension is at least 1%, and the region must stay inside the original. Missing metadata preserves all historical pixels. Cropping preserves the placed center and image proportions; restoring or enlarging a crop fits it within the canvas if necessary. Fit canvas uses the cropped source aspect ratio. Original encoded bytes and attribution are retained.

The canvas, thumbnails, PNG/spritesheet exporter, GIF/H.264 compositor and pixel-effect replay share the same clipped raster rendering. Crop precedes flips and quarter-turn rotation. A bounded source-resolution adjustment preserves detail when a small crop is enlarged.

Native controls and Spatter use the existing project/revision-aware transaction path through the typed `cropImage` command. Stale, cancelled, hidden or locked image edits reject without changing artwork. Copy/paste preserves crop metadata, including recovery from an older schema after Undo. Explicit image/layer deletion clears only that image's metadata; Undo retains the original.

```json
{"cropImage":{"frame":{"id":"existing-frame-id"},"assetID":"managed-image-id","crop":{"x":0.25,"y":0,"width":0.5,"height":1}}}
```

Focused production checks cover actual PNG quadrant pixels before transforms, persistent source-independent crops, Undo/Redo, original bytes/rights, typed commands and invalid/stale/cancelled/locked edits. Native crop-form interaction remains a separate runtime gate. This does not claim arbitrary-angle rotation or multiple imported images per frame.

# Frame exposures

The timeline's existing frame context menu has a Frame exposure submenu. A cel can remain visible for several project-FPS ticks without creating duplicate editable drawings. Repeat frame remains a separate operation that creates independent editable copies.

Optional `AnimationFrame.holdTicks` is canonical schema-21 document data. Missing values retain historical one-tick timing. Explicit values are bounded to 2–600; selecting one tick removes the field. Projects are limited to one hour. Invalid edits fail transactionally without replacing the saved original.

`StudioDocument` owns cumulative start ticks, total duration and time-to-cel lookup. Studio playback, audio seeking and insertion, video-reference extraction, GIF delays, H.264 sample timestamps/durations, mixed-audio length and PNG/spritesheet timing manifests use this same timeline. PNG manifest version 2 records each cel's start and duration; earlier manifests remain version 1 when the project has no new schema features.

The native menu and Spatter's validated command interface both use `setFrameHold`, with the existing request project/revision, cancellation, resource limits and one-step Undo/Redo behavior. Its wire payload is:

```json
{"setFrameHold":{"frame":{"id":"existing-frame-id"},"ticks":6}}
```

Commands may also reference a frame created earlier in the same transaction. This is a typed Studio edit; it grants no publishing, administrative or shell capability. The current context exposes each frame's duration in ticks. Changing frame duration does not silently move existing audio clips; their absolute timing remains editable in the Audio timeline.

The focused production checks exercise persisted edits, history, clipboard schema recovery, playback boundaries, audio seeking and actual exported media. Native menu interaction and full simulator regression remain separate verification gates; implementation or browser previews alone do not prove those journeys.

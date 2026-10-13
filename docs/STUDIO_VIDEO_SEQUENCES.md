# Rotoscope reference sequences

The existing Rotoscope / Video panel can extract 1–24 oriented SDR frames from a Photos or Files movie. One frame keeps the existing single-reference behavior. Multiple frames preview the first decoded image and require an explicit Insert action; they become consecutive one-tick Studio frames immediately after the selected frame. The first source sample maps to the first inserted timeline tick, including the selected frame's exposure hold. Trim and playback speed use the same mapping as single-frame references.

Extraction owns one materialized movie and one generator, runs sequentially with a 30-second deadline, and returns no partial result. Limits are 16 MB source, 4 megapixels per frame, 32 million pixels and 32 MB PNG data per sequence, plus existing project/history/storage limits. A source/trim endpoint, decode failure, cancel, budget failure or stale project rejects the whole operation.

Insertion preserves existing frames and originals. It creates unique managed image assets on one shared reference layer behind drawings, keeps the active drawing layer, and selects the first inserted frame. The new frames and asset references publish together in one Undo/Redo transaction after actual storage preflight. Original videos remain in Photos/Files and are not required to reopen the imported PNG sequence.

This is a bounded editable reference sequence, not a linked movie track. Re-extract another interval to extend it. Soundtrack import remains an explicit separate Audio operation; no microphone, upload, remote API or automatic publication occurs. Native interaction and final mixed-export journeys remain separate acceptance gates.

## Reference layers and exports (wave 3, #199–#201)

- Exports never render reference layers: `StudioDocument.hidingReferenceLayers` hides layers flagged `isReference` before PNG, GIF and MP4 rendering and before the mixed-MP4 capture proof. The flag is a `Models.swift`/`StudioViewModel.swift` change (the "Video reference" layer created by `attachImportedImageSequence` must set it) that belongs to the model owner; the export side is in place.
- Still open, truthfully: the imported movie is not copied into project media (#199) and the trim/speed mapping used for a reference sequence or an extracted soundtrack is not persisted in the project (#200, #201); the extraction itself, orientation handling, bounded decode and the Files/Photos permission and cancel paths exist. The rotoscope panel copy continues to say the movie is not copied.

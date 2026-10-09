# Offline licensed image library

This slice connects a curated 207-picture library to the existing native Add Picture surface. It is part of #173, #195 and #196; it does not complete the thousands-of-assets, download/favorites or multiple editable-image-object requirements.

## Actual flow

Studio menu → Add Picture → Image Library shows actual local thumbnails, a factual installed count, category and multi-term search, and an optional cartoon-weapon filter. Selecting a picture returns to the existing decoded preview. Only **Add to current frame** attaches it on a new image layer in one reversible transaction. Existing artwork remains above it. An existing imported picture is never replaced: this version supports one picture per frame and reports that limit in the library and on rejected Add.

The existing import session captures account, project, revision, frame and active layer before opening the library. It rejects cancelled, replayed or stale selection tokens. Background/account/editor changes retain the existing cancellation boundary. The image importer validates the actual selected file and normalizes pixels with the same bounded ImageIO pipeline as Files/Photos. Copied original bytes must equal the catalogue's verified bytes before a preview becomes available. A source replacement between verification and decode cannot silently substitute another image.

Library browsing never edits, saves, uploads or contacts a provider. A serial actor loads only actual verified thumbnails; the cache retains at most 48 images with maximum 128-pixel edges. Offscreen tasks check cancellation. Search and filters run on the installed bounded manifest. Unavailable/corrupt resources report errors rather than displaying invented artwork or claiming an import succeeded.

## Rights and device ownership

The selected originals are from three Kenney packs, distributed under [CC0](https://creativecommons.org/publicdomain/zero/1.0/):

| Source | Actual included PNGs | Original source archive SHA-256 |
| --- | ---: | --- |
| [Scribble Platformer](https://kenney.nl/assets/scribble-platformer) | 72 | `ca8d9ba8c8a646e3d83b8fa595630f48022e98a328e22d1762a36ffd142df35d` |
| [Scribble Platformer Expansion](https://kenney.nl/assets/scribble-platformer-expansion) | 59 | `13e195ceae12d6ed0af610f00bca5792df6cb185f9671057b67f0eb79be097ee` |
| [Scribble Dungeons](https://kenney.nl/assets/scribble-dungeons) | 76 | `d762ce74516d7384051739277a30f63bce26ec2c8aa98106bba6c9aa87258889` |

The manifest retains stable IDs, author/source/license/attribution, safety metadata, encoded/pixel hashes, dimensions and byte counts. The three original embedded license texts are included by digest. Only reviewed PNGs are bundled; no private historical corpus, scripts, SWFs, logos, preview sheets or duplicate resolutions are distributed.

There are 139 scenery pieces, 62 props and six effects. The 207 original PNGs total 192,884 encoded bytes; the full decoded set is 3,525,376 RGBA bytes. Thumbnails remain capped at 48 cache entries. Twenty-nine cartoon weapons/hazards have an explicit advisory and obey the library filter. Dungeon assets carry top-down tags; castle assets carry side-view tags. Source-specific titles and multi-term searches distinguish the packs.

The expansion excludes one visually identical existing tile, colored round/rectangle characters, diagram arrows, and precomposed floor/object variants. Original encoded and Apple-decoded pixel digests are unique across all 207 entries. No alternate resolutions inflate the installed count. This remains short of the requested thousands; download packs, favorites and multiple editable image objects are separate unfinished work.

The three digest-named publisher licenses remain byte-for-byte, including original line endings and tabs. Exact `.gitattributes` entries exempt only those immutable third-party texts from newline conversion/whitespace style. Each license's actual byte count and SHA-256 are mandatory. New packs still require publisher/license/visual review before trusted import; a metadata validator cannot establish ownership by itself.

After Add, the project owns original image bytes, normalized pixels, fresh instance identity and optional catalogue attribution. Save/reopen no longer depends on the installed library. The stored optional attribution preserves asset ID, author, source/license URLs, attribution text, original-image digest and source-archive digest. Storage rejects malformed or mismatched records. Historical Files/Photos records without attribution still decode as nil. Ordinary project Undo/Redo and asset-retention rules remain authoritative.

## Checks

- `Tests/StudioImageCatalogue`: actual 207 PNGs, licenses, unique IDs/encoded/pixel hashes, category/search/advisories, corrupt resources, symlinks/FIFOs/path bounds and cancellation.
- `Tests/StudioImageLibrary`: actual previews/Add, one-step Undo/Redo, original/attribution retention, real PNG alpha and decoded-pixel equality, save/cold reopen after library removal, fresh instance identity, rejection of existing-picture replacement, stale/cancelled work, corrupt files, historical decoding and invalid provenance. Both new source packs additionally exercise their own real Add/Undo/Redo/save/cold-reopen pixels and rights. The network trap must remain at zero.
- Existing complete import-session, image integration, storage and model checks remain unchanged and mandatory.
- Explicit Xcode source membership covers the catalogue, thumbnail actor and library view; the folder resource contains the exact original PNGs, manifest and licenses.
- `testLicensedImageLibraryUndoAndColdReopen` exercises the real native menu/library/search/preview/Add/Undo/Redo/save/relaunch flow and captures original screenshots. Defining or compiling this test is not proof it ran.

Source-specific passed/failed/pending results belong in the current PR and delivery tracker. Local production checks, SDK typechecking, linked app compilation, actual Simulator journeys and independent review are separate gates. No merge or release completion is implied by this document.

## Native execution follow-up

Source `214e06d` built the linked iOS app and passed every production stage. Its completed original Simulator result is **32 passed, one failed, zero skipped**. Photos import/Undo/save/reopen/PNG, picker cancellation, Eraser modes/history/reopen, Text editing and selection transforms passed. The single read-only Simulator readiness acknowledgement took 14.115 seconds and the single Photos fixture import 7.330 seconds; neither was retried. Both readiness and Eraser navigation corrections are now verified in that run.

The one failing journey stopped at the library preview: the earlier assertion measured red pixels in monochrome Pencil artwork. The original screenshot/recording shows the real decoded white/black preview. This change measures light artwork and dark contrast, retaining the actual subsequent Add/canvas/Undo/Redo/save/cold-reopen assertions. The new catalogue journey selects the actual 64-pixel Dungeon Dragon. Its runtime result is pending, not passed.

Layer deletion adds a 34th native journey. The suite remains bounded at 55 minutes, each journey at 180 seconds and the outer native job at 95 minutes, including production compilation and original evidence preservation. No retries, skips or deadline increases are introduced. Full native runtime and independent review remain mandatory gates.

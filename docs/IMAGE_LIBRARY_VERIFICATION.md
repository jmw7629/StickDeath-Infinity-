# Offline licensed image library

This slice connects a curated 72-picture pilot to the existing native Add Picture surface. It is part of #173, #195 and #196; it does not complete the thousands-of-assets, download/favorites or multiple editable-image-object requirements.

## Actual flow

Studio menu → Add Picture → Image Library shows actual local thumbnails, a factual installed count, category and multi-term search, and an optional cartoon-weapon filter. Selecting a picture returns to the existing decoded preview. Only **Add to current frame** attaches it on a new image layer in one reversible transaction. Existing artwork remains above it. An existing imported picture is never replaced: this version supports one picture per frame and reports that limit in the library and on rejected Add.

The existing import session captures account, project, revision, frame and active layer before opening the library. It rejects cancelled, replayed or stale selection tokens. Background/account/editor changes retain the existing cancellation boundary. The image importer validates the actual selected file and normalizes pixels with the same bounded ImageIO pipeline as Files/Photos. Copied original bytes must equal the catalogue's verified bytes before a preview becomes available. A source replacement between verification and decode cannot silently substitute another image.

Library browsing never edits, saves, uploads or contacts a provider. A serial actor loads only actual verified thumbnails; the cache retains at most 48 images with maximum 128-pixel edges. Offscreen tasks check cancellation. Search and filters run on the installed bounded manifest. Unavailable/corrupt resources report errors rather than displaying invented artwork or claiming an import succeeded.

## Rights and device ownership

The selected originals are from Kenney's [Scribble Platformer](https://kenney.nl/assets/scribble-platformer), distributed under [CC0](https://creativecommons.org/publicdomain/zero/1.0/). Original source-archive SHA-256 is `ca8d9ba8c8a646e3d83b8fa595630f48022e98a328e22d1762a36ffd142df35d`. The manifest retains stable IDs, author/source/license/attribution, safety metadata, encoded/pixel hashes, dimensions and byte counts. The original embedded license text is included by digest. Only reviewed PNGs are bundled; no private historical corpus, scripts, SWFs, logos, preview sheets or duplicate resolutions are distributed.

Four scenery backgrounds, five effects, fourteen props and forty-nine scenery tiles are included. The 72 PNGs total 64,347 encoded bytes; the full decoded set is 1,313,536 RGBA bytes. This pilot does not imply that thousands of assets are installed. New packs require a real publisher/license/visual review before they enter trusted application input; a metadata validator cannot establish ownership by itself.

The single digest-named publisher license is retained byte-for-byte, including its CRLF and trailing tabs. Its exact `.gitattributes` entry prevents newline conversion and excludes only that immutable third-party text from repository whitespace style. The catalogue still verifies all 571 bytes by SHA-256; application source and other files retain normal diff checks.

After Add, the project owns original image bytes, normalized pixels, fresh instance identity and optional catalogue attribution. Save/reopen no longer depends on the installed library. The stored optional attribution preserves asset ID, author, source/license URLs, attribution text, original-image digest and source-archive digest. Storage rejects malformed or mismatched records. Historical Files/Photos records without attribution still decode as nil. Ordinary project Undo/Redo and asset-retention rules remain authoritative.

## Checks

- `Tests/StudioImageCatalogue`: actual 72 PNGs, licenses, unique IDs/encoded/pixel hashes, category/search/advisories, corrupt resources, symlinks/FIFOs/path bounds and cancellation.
- `Tests/StudioImageLibrary`: actual previews/Add, one-step Undo/Redo, original/attribution retention, real PNG alpha and decoded-pixel equality, save/cold reopen after library removal, fresh instance identity, rejection of existing-picture replacement, stale/cancelled work, corrupt files, historical decoding and invalid provenance. The network trap must remain at zero.
- Existing complete import-session, image integration, storage and model checks remain unchanged and mandatory.
- Explicit Xcode source membership covers the catalogue, thumbnail actor and library view; the folder resource contains the exact original PNGs, manifest and license.
- `testLicensedImageLibraryUndoAndColdReopen` exercises the real native menu/library/search/preview/Add/Undo/Redo/save/relaunch flow and captures original screenshots. Defining or compiling this test is not proof it ran.

Source-specific passed/failed/pending results belong in the current PR and delivery tracker. Local production checks, SDK typechecking, linked app compilation, actual Simulator journeys and independent review are separate gates. No merge or release completion is implied by this document.

## Native execution follow-up

The preceding `c08033a` run built the app and passed every production stage, but its native job was cancelled at the 75-minute outer deadline. The preserved unfinished UI log reports 25 unambiguous passes, a Photos failure after its fixture command timed out, an Eraser timeout with a conflicting final pass line, one interrupted journey and four unstarted journeys. This is not a green native run.

The next run keeps all functional assertions and the 180-second individual journey limit. Pencil cleanup in the Eraser test moves to when Pencil is already visible, avoiding the observed four rail drags after cold reopen. A single read-only command-readiness acknowledgement precedes the one unchanged 60-second Photos import. An unresponsive command channel remains a failed fixture gate; no import or test is retried or skipped. This readiness change is a mitigation awaiting actual native verification.

The complete 33-journey suite has a finite 55-minute limit and the outer job 95 minutes, including roughly 30 minutes of observed production/build work, setup and evidence collection. The earlier 75-minute job interrupted the suite before it could reach its own bound. The larger outer budget preserves required failure evidence; it does not turn any assertion failure into a pass.

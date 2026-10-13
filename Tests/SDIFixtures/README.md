# Shared `.sdi` golden fixtures

Contract fixtures for the editable project interchange between the native iOS app and the
Android client (#286). They are generated deterministically by `make_fixtures.py` from the
iOS Codable contract (`StickDeathInfinity/Models/StudioDocument.swift`, `Models.swift`,
`Storage/DeviceStorageManager.swift`, schema 35) and are **not** captured device exports.

| Fixture | Android | What it exercises |
| --- | --- | --- |
| `swift-schema35-studio.sdi` | accept | Position and alpha lock modes, a PhotoCraft colour label, multiply and linear-dodge blends, a 3-tick hold, a pressure-sampled round brush, a legacy line, four-track volume/mute/pan/solo |
| `swift-schema35-text.sdi` | reject | A text element; Android text is not interchangeable yet, so the whole import is refused with the original preserved |
| `swift-schema36-future.sdi` | reject | A schema above the supported range |
| `swift-schema35-glow.sdi` | reject | Layer glow, which Android cannot render |
| `swift-schema35-unknown-label.sdi` | reject | A `colorLabel` outside the eleven PhotoCraft swatches |
| `swift-schema35-audio-clip.sdi` | reject | Managed audio clips/assets, not yet importable on Android |

`expectations.json` is the machine-readable form of this table (with SHA-256 and byte counts).

- Verify: `python3 -I Tests/SDIFixtures/verify_fixtures.py` or
  `python3 -m unittest discover -s Tests/SDIFixtures -p 'test_*.py'`.
- Regenerate after a deliberate contract change: `python3 -I Tests/SDIFixtures/make_fixtures.py`
  (the verifier fails if committed bytes drift from the generator).
- Android consumes `assets/` as instrumented-test assets (`app/build.gradle.kts`
  `androidTest` source set); `SwiftProjectImportTest` asserts the accept/reject outcomes and
  round-trips the golden fixture through `SwiftProjectExport`. The iOS side can open the same
  bytes with `DeviceStorageManager.projectFromPortableBundle`; an iOS Foundation-runnable check
  against these files is still a follow-up and is not claimed here.

Nothing in these fixtures is a recovered-corpus asset: every coordinate, colour and name is
synthetic.

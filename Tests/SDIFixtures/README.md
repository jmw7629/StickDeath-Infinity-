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
  round-trips the golden fixture through `SwiftProjectExport`.

## Both-client re-export comparison

`reexport.json` is the interchange projection of the golden fixture (`make_fixtures.interchange_projection`:
identities, names, canvas, layers with lock mode/blend/label, frame holds, element tool/colour/width/
opacity/points/pressure, brush family and seed, and the four-track mixer; schema numbers, dates,
revision and identifier case are excluded, numbers compared to four decimals).

- Android (`SdiReexportComparisonTest`, JVM, runs in `:app:testDebugUnitTest`): opens the golden
  fixture with `SwiftProjectImport`, re-exports with `SwiftProjectExport`, and the projection of the
  exported bytes must equal `reexport.json`. The exported bytes must also equal the committed
  `android-reexport/swift-schema35-studio.android.sdi`, so the iOS side reads what Android writes today.
- iOS (`Tests/SDIInterchange/main.swift`, native-production-tests): opens every fixture with
  `DeviceStorageManager.projectFromPortableBundle` + `StudioDocumentArchive.decode`, re-exports with
  `StudioDocumentArchive.encoded` + `portableBundle(for:)`, and compares the projection with
  `reexport.json`; it also opens Android's committed re-export and writes it back out. Fixtures with an
  `ios` expectation are asserted; the others have their iOS outcome printed, and every opened fixture
  must re-export and reopen to an equal `StudioDocument`.
- `verify_fixtures.py` checks that `reexport.json` and the Android re-export match the generator.

Nothing in these fixtures is a recovered-corpus asset: every coordinate, colour and name is
synthetic.

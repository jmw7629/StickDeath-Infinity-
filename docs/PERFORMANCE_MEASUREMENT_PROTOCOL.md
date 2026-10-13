# Performance measurement protocol (#266, owner-gated)

Status: **owner-gated**. The tests in `Tests/NativePerformance/StudioPerformanceUITests.swift`
exist in source and parse (`swiftc -parse`). They have never been compiled by
Xcode or executed; no number below is a measurement. Physical-device numbers
require the owner's Mac, signing identity and an enrolled iPhone
(`docs/TESTFLIGHT_DISTRIBUTION.md`).

## 1. What is measured

| Test | Metrics | Iterations | What it exercises |
| --- | --- | ---: | --- |
| `testColdLaunchToWelcome` | `XCTApplicationLaunchMetric(waitUntilResponsive: true)` | 5 | cold launch to the Welcome screen (`welcome.guest` present) |
| `testCanvasStrokeAndUndo` | `XCTClockMetric`, `XCTCPUMetric(application:)`, `XCTMemoryMetric(application:)` | 5 | one real drag on `studio.canvas` until `studio.undo` enables, then Undo back to the blank raster |
| `testPNGExportToPreview` | `XCTClockMetric`, `XCTMemoryMetric(application:)` | 3 | `studio.export.open` → PNG format → `studio.export.start` until `studio.export.preview` shows and the status reads "Export ready", then close |

The journeys reuse the production guest route (Welcome → Skip Tutorial →
Studio → New Project) with no fixtures, no backend and no injected state; the
helpers are a minimal copy of the smoke suite's route because test targets do
not share private helpers.

Not covered here, still required by #266: playback frame pacing (needs a
multi-frame fixture project), export memory on long projects (#202), battery and
thermal behaviour (device-only, `MetricKit`/Instruments), crash recovery
timing (#168). Record them as **not run** until a device protocol exists.

## 2. Target (candidate) — not applied

Add to `project.yml` (coordinator; the checked-in `StickDeathInfinity.xcodeproj`
must be regenerated or edited to match, and a native build must prove the
target compiles):

```yaml
  StickDeathInfinityPerformanceTests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - path: Tests/NativePerformance
    dependencies:
      - target: StickDeathInfinity
    settings:
      base:
        INFOPLIST_FILE: ""
        GENERATE_INFOPLIST_FILE: true
        PRODUCT_BUNDLE_IDENTIFIER: com.willisnmb.stickdeathinfinity.perftests
        TEST_TARGET_NAME: StickDeathInfinity
```

and a scheme `StickDeathInfinityPerformanceTests` whose test action lists only
that target. The target is deliberately outside `StickDeathInfinityUITests`:
the smoke inventory (`scripts/native-smoke/test_budget.py`) pins one class in
one file, forbids retries and budgets 180/240 s per case, none of which fits
repeated `measure` iterations.

## 3. How to run (owner's Mac)

1. Simulator baseline (informational only, label every number "simulator"):
   ```sh
   xcodebuild test -project StickDeathInfinity.xcodeproj -scheme StickDeathInfinityPerformanceTests \
     -configuration Release -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
     -resultBundlePath "$HOME/sdi-perf/$(git rev-parse --short HEAD)-simulator.xcresult" CODE_SIGNING_ALLOWED=NO
   ```
2. Device run (the only numbers that count): same command with
   `-destination 'platform=iOS,id=<device udid>'` and the owner's signing
   settings; Release configuration; device on charger, screen brightness fixed,
   Low Power Mode off, no other foreground app; repeat the whole command three
   times and keep all three result bundles.
3. Read the metrics from the result bundle (`xcrun xcresulttool get test-results
   tests --path <bundle>` lists each `measure` block's average and standard
   deviation; Xcode's Report navigator shows the same values).
4. Record per metric: device model, iOS version, commit, average, standard
   deviation, iteration count, and whether a baseline was set. Set the Xcode
   baseline only after three consistent device runs; a baseline is a regression
   tripwire for later runs, not evidence that the value is "good".

## 4. Acceptance framing

- Launch, stroke and export numbers are reported next to the commit and device.
  There is no pass/fail threshold yet; the first device run establishes the
  baseline the owner accepts, and later runs must not regress beyond the
  XCTest default tolerance (10 %).
- A simulator run never closes #266, and a Safari screenshot never counts as a
  native executable (issue text).
- Results go into #266 with the result-bundle hashes; the bundles stay private.

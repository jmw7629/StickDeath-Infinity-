# Native simulator review archive

The existing generic simulator build produces Intel and Apple-silicon app slices. Preserve that actual app before destination-specific UI-test preparation changes build products. This makes the native app available for a later isolated local simulator review without downloading another SDK/runtime or changing signing.

The archive step validates the expected app identity, simulator-only platform, empty public backend settings, both architectures and simulator build metadata in every Mach-O binary, including Debug dylibs. It rejects links, device provisioning profiles, excessive file counts/bytes, changed input, existing outputs and expired packaging budgets. It streams data, retains executable modes, checks CRCs and compares every archived file hash with the built input. The manifest binds the archive to the CI source commit and explicitly says local Mac runtime verification is pending. The two-minute packaging budget leaves all existing UI-test deadlines unchanged.

Packaging tests use synthetic bundle metadata, test data and actual cross-compiled Mach-O fixtures. They do not prove that the product launches or behaves correctly. CI's actual app archive and subsequent local installation/launch/screenshots must be checked separately. This is a simulator artifact, not a signed iPhone/TestFlight/release build. Do not upload it to an app store or claim device verification.

Before local use, validate the downloaded archive and source manifest, inspect compatible OS/architectures, retain original evidence, create one isolated simulator on an installed runtime, and use explicit simulator IDs. Never reset an existing user's device or copy production auth/session data. Native review data stays isolated and backend configuration remains empty.

Packaging rules, archive creation and upload have explicit outcomes. Their required final check runs after the existing native UI and evidence steps. Intermediate continuation permits unrelated UI evidence to complete; the final check still fails the native job unless all three packaging outcomes are success. Packaging failure is never converted to a successful mandatory job or an app verification claim. A cancelled job stays cancelled.

## Owner install route (#126)

These are the exact steps for an isolated local review of the CI-built simulator app. They prove only what you observe on your Mac; they are not device, TestFlight or release evidence, and nothing here touches an existing simulator's data.

1. **Pick the run and download the artifact** (the artifact exists only when shard 0 preserved it, retention is 3 days):
   ```sh
   RUN_ID=<run id from the Actions page>; SHA=<40-hex head the run built>; ATTEMPT=<run attempt, usually 1>
   mkdir -p ~/sdi-review/"$SHA" && cd ~/sdi-review/"$SHA"
   gh run download "$RUN_ID" -R jmw7629/StickDeath-Infinity- -n "native-simulator-app-$SHA-$ATTEMPT" -D artifact
   ls artifact   # expect StickDeathInfinity-simulator.zip and manifest.json
   ```
2. **Verify the archive against the receipt before unpacking**:
   ```sh
   python3 -c 'import json;m=json.load(open("artifact/manifest.json"));print(m["sourceCommit"], m["archiveSHA256"], m["archiveBytes"], m["buildVersions"])'
   shasum -a 256 artifact/StickDeathInfinity-simulator.zip
   stat -f %z artifact/StickDeathInfinity-simulator.zip
   ```
   The printed `sourceCommit` must equal `$SHA`, the SHA-256 must equal `archiveSHA256`, and the byte count must equal `archiveBytes`. Stop on any mismatch and keep the files for the record. `buildVersions` names the minimum iOS and SDK of each slice; choose a runtime at or above the minimum.
3. **Unpack and check the app identity**:
   ```sh
   unzip -q artifact/StickDeathInfinity-simulator.zip -d app
   /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' app/StickDeathInfinity.app/Info.plist   # com.willisnmb.stickdeathinfinity
   /usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms' app/StickDeathInfinity.app/Info.plist   # iPhoneSimulator only
   ```
4. **Create one isolated simulator on an installed runtime** (never reuse a personal device):
   ```sh
   xcrun simctl list runtimes            # pick an installed iOS runtime identifier
   RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-<major>-<minor>
   UDID=$(xcrun simctl create "SDI Review ${SHA:0:12}" com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro "$RUNTIME")
   echo "$UDID" > simulator-udid.txt
   xcrun simctl boot "$UDID"
   open -a Simulator --args -CurrentDeviceUDID "$UDID"
   ```
5. **Install and launch**:
   ```sh
   xcrun simctl install "$UDID" app/StickDeathInfinity.app
   xcrun simctl launch "$UDID" com.willisnmb.stickdeathinfinity
   ```
   The app has empty public backend settings by construction (`emptyPublicSettings` in the manifest), so sign-in and connected features show their honest unavailable states; the local Studio is usable. Capture what you observe with `xcrun simctl io "$UDID" screenshot <name>.png` and label each capture with `$SHA`.
6. **Uninstall / rollback**:
   ```sh
   xcrun simctl terminate "$UDID" com.willisnmb.stickdeathinfinity
   xcrun simctl uninstall "$UDID" com.willisnmb.stickdeathinfinity
   ```
   To review the previous known-good build instead, repeat steps 1–3 and 5 with that run's artifact in its own directory (its own `manifest.json` is the receipt). To remove the review device entirely: `xcrun simctl shutdown "$UDID" && xcrun simctl delete "$UDID"` — this deletes only the simulator you created in step 4; never run `simctl erase` or `delete` on another device, and keep the downloaded `artifact/` directory as evidence.
7. **Record** in #126: run id, attempt, `sourceCommit`, archive SHA-256, runtime used, what launched, what was captured, and what was not checked. Observed behaviour on this simulator is not a claim about a physical device or a signed build.

## Sourcing gallery captures from the run artifact (#126)

The owner-private gallery (coordinator-managed; see #126 for the current
version and its rollback) shows **original XCTest attachments**, never web
renders. Every capture it publishes is taken from the native smoke artifact of
one exact run, and its label carries that run's `sourceCommit`.

Where the files are (`scripts/native-smoke/run_smoke_ci.sh`, artifact
`native-studio-<sha>-<attempt>-<shard>`):

| Path in the artifact | Produced by | Use |
| --- | --- | --- |
| `attachments/` | `xcrun xcresulttool export attachments --path StudioSmoke.xcresult --output-path attachments` | the PNG screenshots, normalized export previews, hierarchy dumps and audit text attachments |
| `attachment-export.log` | stdout/stderr of that export | confirms the export ran to completion; a non-empty error here means `attachments/` is partial and the run stays red (`sdi_evidence_status=3`) |
| `test-summary.json`, `test-tree.json` | `xcresulttool get test-results summary|tests` | which test produced which result; the tree holds the test identifiers the receipt binds |
| `ui-test-budget.json`, `source-and-config.json`, `recording-status.json` | `run_recorded_test.py` | `sourceCommit`, shard assignment, fixture plan, exit codes |
| `simulator.mp4`, `recording-validation.json` | `simctl io recordVideo` + `VerifyRecording.swift` | the continuous recording of the shard |

Naming: each PNG's human-readable name is the `capture(app, name:)` string in
`Tests/NativeUI/StudioSmokeUITests.swift` (for example `studio-portrait`,
`gradient-family-sole-popup`, `layer-row-drag-real-order`,
`audio-numeric-trim-applied`, `png-export-drawn-preview`,
`owner-project-library-scroll`; the new accessibility and journey captures are
`library-accessibility-xl`, `studio-portrait-accessibility-xl`,
`studio-landscape-accessibility-xl`, `journey-*`). The exported file names are
assigned by `xcresulttool`; on the Xcode 16 toolchain the export writes an
`attachments/manifest.json` that lists, per test identifier, each exported
file name next to its `suggestedHumanReadableName` (the capture string). Use
that manifest to pick files; do not guess from file names. If a toolchain
writes no manifest, pair the files through `test-tree.json` and the capture
order in `ui-tests.log`, and say so in the gallery provenance.

Publishing rules for a capture (unchanged from #126): copy the PNG
byte-identical and record its SHA-256; label it with `sourceCommit`, run id,
attempt, shard, test function and capture name; state the run's result
(passed / failed / interrupted) next to it; never crop, retouch or upscale;
never present a capture from one commit as evidence for another. A capture
from a failed or partial run may be published only as failure evidence.

Routes to a real device remain owner-gated: `docs/TESTFLIGHT_DISTRIBUTION.md`.

#!/bin/bash
# Runs the checked-in UI test target using existing runner tools,
# app package checkouts and an explicitly selected available iOS simulator.
set -euo pipefail
: "${RUNNER_TEMP:?Run on the approved ephemeral macOS CI runner}"
: "${SDI_SMOKE_SIMULATOR_UDID:?Select an available simulator from simctl list}"
[[ "${GITHUB_ACTIONS:-}" == "true" ]] || { echo 'CI runner required'; exit 2; }
git diff --quiet HEAD -- || { echo 'Commit tracked changes before recording evidence'; exit 2; }
sdi_commit="$(git rev-parse HEAD)"
sdi_script_dir="$(cd "$(dirname "$0")" && pwd)"
sdi_run="$(mktemp -d "$RUNNER_TEMP/sdi-native-smoke.XXXXXX")"
sdi_derived="$RUNNER_TEMP/sdi-native-build"
sdi_package_cache="$sdi_derived/SourcePackages"
sdi_results="$sdi_run/StudioSmoke.xcresult"
printf '%s\n' "$sdi_run" > "$RUNNER_TEMP/sdi-native-smoke-artifact-path.txt"
trap 'echo "Native smoke evidence: $sdi_run"' EXIT
[[ -d "$sdi_package_cache/checkouts" ]] || { echo 'Reuse the successful native build package cache; no dependency bootstrap'; exit 2; }

# The runner must already have a compatible installed runtime. No runtime/device
# creation, package download command, endpoint, user keychain or signing setup.
xcrun simctl list devices available --json > "$sdi_run/simulator-inventory.json"
python3 - "$sdi_run/simulator-inventory.json" "$SDI_SMOKE_SIMULATOR_UDID" <<'PY'
import json,sys
inventory=json.load(open(sys.argv[1]))
matches=[d for runtime,devices in inventory['devices'].items() if '.iOS-' in runtime
         for d in devices if d['udid']==sys.argv[2] and d.get('isAvailable')]
assert len(matches)==1, 'Select one existing available iOS simulator'
print('Verified simulator:',matches[0]['name'])
PY
xcodebuild build-for-testing \
  -project StickDeathInfinity.xcodeproj -scheme StickDeathInfinity \
  -configuration Debug -destination "platform=iOS Simulator,id=$SDI_SMOKE_SIMULATOR_UDID" \
  -derivedDataPath "$sdi_derived" -clonedSourcePackagesDirPath "$sdi_package_cache" \
  -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 \
  -only-testing:StickDeathInfinityUITests \
  CODE_SIGNING_ALLOWED=NO SPATTER_BACKEND_URL= SUPABASE_URL= \
  SUPABASE_PUBLISHABLE_KEY= SUPABASE_ANON_KEY= LIVEKIT_WS_URL= \
  > "$sdi_run/build-for-testing.log" 2>&1

sdi_profile="$(python3 - "$sdi_derived/Build/Products" <<'PY'
import pathlib,sys
profiles=[p for p in pathlib.Path(sys.argv[1]).glob('*.xctestrun') if not p.name.startswith('SDI-OfflineSmoke')]
assert len(profiles)==1,'Expected one generated xctestrun profile'
print(profiles[0])
PY
)"
sdi_prepared="$(dirname "$sdi_profile")/SDI-OfflineSmoke-$(basename "$sdi_run").xctestrun"
python3 "$sdi_script_dir/prepare_offline_run.py" "$sdi_profile" "$sdi_prepared" "$sdi_commit" \
  --metadata "$sdi_run/source-and-config.json"

set +e
python3 "$sdi_script_dir/run_recorded_test.py" \
  --udid "$SDI_SMOKE_SIMULATOR_UDID" --output "$sdi_run" -- \
  xcodebuild test-without-building -xctestrun "$sdi_prepared" \
  -destination "platform=iOS Simulator,id=$SDI_SMOKE_SIMULATOR_UDID" \
  -resultBundlePath "$sdi_results" -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 180
sdi_test_status=$?
set -e
sdi_evidence_status=0
if [[ -d "$sdi_results" ]]; then
  if ! xcrun xcresulttool export attachments --path "$sdi_results" --output-path "$sdi_run/attachments" \
      > "$sdi_run/attachment-export.log" 2>&1; then
    sdi_evidence_status=3
  fi
  if ! xcrun xcresulttool get test-results summary --path "$sdi_results" \
      > "$sdi_run/test-summary.json" 2> "$sdi_run/summary-export.log"; then
    sdi_evidence_status=3
  fi
else
  sdi_evidence_status=3
fi
# Preserve the real test failure code even when its incomplete result cannot be
# exported. A successful test with missing required evidence also remains red.
if [[ "$sdi_test_status" != 0 ]]; then exit "$sdi_test_status"; fi
exit "$sdi_evidence_status"

# Native QA plan: journeys and adaptive layouts (#264, #265, #273)

Status: implemented on Linux, **native execution deferred** (no Xcode on the
authoring host). Nothing below has run on a simulator yet; no result is claimed.

## What runs where

| Job | Suite | Devices | Data | Gate |
| --- | --- | --- | --- | --- |
| `native-ios-shards` (unchanged) | `StudioSmokeUITests` (110 cases, two shards) | fresh iPhone 16 Pro | offline build | `shard_receipt.py` |
| `native-ios-journeys` (new) | `JourneyUITests` (5 cases) | fresh iPhone 16 Pro, then fresh iPad Pro 11-inch (M4) | offline build, same `prepare_offline_run.py` preflight | `journey_receipt.py` |
| `native-ios-journeys` (new, phone only) | `ServiceJourneyTests` (6 hosted cases) | the same phone | pinned Supabase SDK over a local `URLProtocol` fixture (`*.invalid` host) | `journey_receipt.py` |
| `native-ios-build` (required check) | aggregates both | — | — | requires all shard and journey receipts for the exact head, run and attempt |

`native-ios-journeys` needs `native-ios-shards`, so at most one Mac job runs at a
time. It still runs when a shard fails (not when cancelled), so its evidence is
kept, but `native-ios-build` stays red until every gate passes.

## Why the pinned files did not need to change

- The shards pass explicit `-only-testing:StickDeathInfinityUITests/StudioSmokeUITests/<case>()`
  selectors (`test_budget.build_shard_budget`), so a second class in the same UI
  test bundle is never executed by a shard, and `shard_receipt.actual_tests`
  still sees only `StudioSmokeUITests` cases.
- `test_budget.build_test_budget` and `run_recorded_test.FIXTURE_SOURCE_SHA256`
  read only `Tests/NativeUI/StudioSmokeUITests.swift`, which is unchanged.
- `run_auth_ci.py` now selects `-only-testing:StickDeathInfinityAuthTests/AuthStateTests`,
  so its exact 20-case gate is unaffected by the new hosted file in that bundle.

**Owner pin action required: none.** `Tests/NativeUI/StudioSmokeUITests.swift`
and `scripts/native-smoke/run_recorded_test.py` are untouched; the current
`FIXTURE_SOURCE_SHA256` stays valid.

Not pinned but changed (reviewable): `shard_receipt.py` (the aggregate's
dependency set now includes `native-ios-journeys`), `select_simulator.py`
(`--device ipad`, exact type `iPad-Pro-11-inch-M4-8GB`, no fallback),
`run_auth_ci.py` (selector above).

## Journey coverage

`JourneyUITests` (phone and iPad, portrait and landscape where marked):

1. Studio canvas, primary toolbar and frame timeline; canvas must keep at least
   150 pt (phone) / 300 pt (iPad) on its short side and the timeline must not
   cover it. Portrait and landscape.
2. Audio workspace: library, close, snap and play controls reachable and inside
   the window; canvas not collapsed. Close is asserted at 44 pt; the other
   controls' measured sizes are attached as evidence (the "+ Add" capsule is
   likely under 44 pt — an actionable #264 finding to confirm on device).
3. Tool options popup stays inside the window, dismisses, and leaves the canvas
   geometry unchanged. Portrait and landscape.
4. Guest Home feed, Rooms and War Room show the not-configured and sign-in
   states and no invented cards, rooms, matchups or results.
5. The guide's final page shows the #273 policy step's truthful
   not-configured state with Terms and Privacy links, no Accept control, and
   Open Studio still reaches the Studio library.

`ServiceJourneyTests` (signed-in SDK session, local fixture): feed page + like
with the session bearer token; room invitation preview, consent-gated
admission and room list; War Room list, one vote and a server refusal;
owner-approval decision history filtered to the exact render; onboarding policy
acceptance of exactly the shown versions from `ios`; signed-out refusal with no
request and a 503 outage that is not shown as data.

## Known gaps (not covered here)

- The owner's approve/request-changes/reject call is view-private in
  `AdminDashboardView` (`sdi_review_action decide`); only its history read is a
  client. Covering the decision itself needs that call moved into
  `AdminOperationsClient` first.
- No deployed-backend acceptance: the fixture proves the client, transport and
  session path, not server SQL or RLS.
- VoiceOver focus order, Dynamic Type beyond the existing accessibility audit,
  Reduce Motion and physical devices remain manual/device work for #264.
- `docs/control-evidence-map.csv` derives its `uiTest` column from
  `StudioSmokeUITests.swift` only, so identifiers exercised solely by
  `JourneyUITests` still read `deferred` there.

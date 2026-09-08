# Native iOS recovery: Spatter client verification

This is work on the existing StickDeath Infinity iOS app, not STICKDEATH_BYTE.
No Studio, media, community, messaging, calls, publishing, or business data was removed.
Base for this repair: `a14ea263df85591f9e5a98e5285215a3152e36c3` on PR #111.

## Codex ownership checkpoint — 2026-09-08

The owner transferred this project to Codex in issue #110. This continues PR #111 from `fe191ee79d93f625ec3c36540d72f87f69f7de92`; it is not a new recovery branch.

- Read the actual failed native job. Removed stale ExportView/FloatingToolbar build inputs and included the current Studio panels, header, tool strip, brain loader and retained app screens.
- All 80 target Swift source paths exist and are unique. The historical alternate LiveKit service is explicitly excluded from XcodeGen to avoid defining a second service; the nested canonical service remains included.
- Corrected historical raster storage references to its existing StoredAnimationFrame type; no migration, file deletion or asset rewrite runs in this change.
- Restored public Supabase and LiveKit configuration with validation and explicit unavailable errors. No SDK client is initialized without valid public configuration. Existing subscription families use rank without introducing prices or quotas.
- Focused production tests: 29/29 PASS on the local Mac (the original 22 Spatter tests plus seven configuration/rank cases). Source-security and integration-reference checks, plist syntax and diff checks PASS.
- Native application build has NOT passed. Local Xcode 26.3 completed dependency compilation but asset compilation failed because its iOS 26.2 SDK has no matching simulator runtime. Separate source compiler and exact-head macOS CI evidence remain required. No simulator app interaction, signing or TestFlight pass is claimed.
- Offline persistence, canonical layers/history, real media/audio/export, Spatter editor commands and authenticated backend journeys remain incomplete and separately tracked. A private web companion is a review surface only.

## Historical executed evidence

- Swift 6.2.1, target `x86_64-unknown-linux-gnu`, in Swift 5 language mode.
- Command: `swiftc -swift-version 5 -parse-as-library StickDeathInfinity/App/AppConfig.swift StickDeathInfinity/App/SpatterBackendClient.swift Tests/SpatterClient/main.swift -o /tmp/sdi-spatter-client-tests`.
- Ran the resulting executable under a 30-second outer timeout: **22/22 tests PASS**.
- Tests compile the actual app configuration/backend source; no mirror client implementation is used.
- Network responses use test-only URLProtocol fixtures or injected transports, never real accounts/providers.
- Source, test and verifier files transferred to JoeVPS with SHA-256 equality checks against the tested bytes.
- Ran `BASE_SHA=c8b7cab481328bdc10654906d17093e00eccf1dc python3 scripts/verify_spatter_client.py` on JoeVPS: source-security, integration-reference and diff checks PASS.
- `git diff --check` against the base passed.

## What the executable tests cover

Configuration loading; HTTPS/provider/credential/query validation; zero transport calls for missing configuration/session; malformed session headers; current endpoint/token lookup; request shape and size; response size; HTTP, malformed JSON and empty-response distinctions; actual delegate chunk/burst limits; denied redirects; cancellation of a stalled fixture followed by a successful second request.

The request delegate uses an NSLock around all shared completion/response state. Its explicit Sendable declaration bridges URLSession delegate requirements; mutable state is not exposed.

## App wiring

Both chat paths route through SpatterService and the same authenticated backend client. Embedded personality/knowledge and optional runtime knowledge remain. Cloud configuration/session checks precede optional runtime knowledge transport. A changed session during knowledge loading aborts rather than forwarding a stale account token.

Provider-key controls/state and email-list privilege assignment are removed. Admin UI reflects authenticated server `appMetadata` only; this is not a substitute for backend authorization or an RLS audit. Profile creation no longer sends a role assignment.

`SPATTER_BACKEND_URL` is a public build setting expanded into Info.plist. Missing/invalid/unexpanded values cannot create a request. No endpoint or credential default is supplied. Configure the real application backend, not an AI-provider endpoint. The current JSON response contract is `choices[0].message.content`; the backend must validate the session and keep provider credentials server-side.

The checked-in Xcode target includes the exact new backend source. Swift language settings use `5.0`, not the compiler release number `5.9`.

## Still blocking full app readiness

- A new exact-head workflow runs the focused tests/security gate and a separate unsigned native simulator-target build. Its actual result must be inspected; workflow existence is not PASS.
- `XCODE_IOS_BUILD=NOT RUN` at the local verification stage. Linux source tests are not an iOS build or simulator run.
- Other pre-existing AppConfig contracts (Supabase, LiveKit and subscription configuration) and incomplete Xcode source membership remain to be resolved against native compiler evidence.
- Live backend/auth/provider end-to-end behavior is NOT RUN.
- Device/visual interaction verification is NOT RUN.
- No production deployment, public upload, merge or release has occurred.

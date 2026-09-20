# Native entry flow — issues #136 and #137

The welcome, splash and five-page guide retain the supplied skull, dark shell,
white wordmark, feature hierarchy and page-specific red/blue/orange gradients.
The guide states the actual local capabilities and identifies unfinished Rooms,
War Room and cloud assistance. Historical user counts, cloud-sync promises,
guessed asset counts and provider claims are not shipped as facts.

## Behavior

- Splash follows the existing authentication restoration state. It has no fixed
  loading timer, and Open Studio Offline remains available during restoration.
  A late result cannot navigate away from an explicit offline choice.
- Guest access opens the existing Studio tab directly without requesting an anonymous
  cloud account or swallowing a failed sign-in. Projects use the existing local
  production storage; no data migration or deletion is introduced.
- Missing account configuration is disclosed on Welcome. Existing sign-in and
  signup forms remain reachable, with accessible Back controls.
- Studio Guide can be opened again from Welcome. Back, Next, page dots, Skip and
  Open Studio use the actual app route. Completion is a local device preference,
  never a guessed skill/interests profile or server-side consent.
- Completing the guide opens Studio access without routing through the unfinished
  plan-selection transaction flow. Billing and provider authentication remain
  separate acceptance tasks; no entitlement or purchase is granted here.
- Welcome and guide content scroll on short displays. Navigation and decorative
  animations respect Reduce Motion; the previous unowned repeating welcome timer
  and delayed splash callbacks are removed.

## Verification boundaries

`testWelcomeGuideNavigationAndLocalCompletion` exercises the real native welcome,
login/signup Back routes, guide Next/Back/dots, landscape controls, completion,
cold-relaunch persistence, Skip and preservation of a newly created local project.
All existing Studio journeys continue to enter via the real guest action. The
suite also includes independent track-mute and track-volume regressions and contains 44 journeys with the same 180-second per-case and 3900-second
whole-suite limits; no retry, skip or assertion relaxation is introduced.

Local checks type-check the changed production views against the iOS SDK and
compile the XCTest definitions. These checks are not native runtime verification.
Runtime acceptance requires the app build and simulator journey from the same
source revision. Preserve the preceding exact-source CI outcome and originals
before advancing the workstream; do not infer a runtime pass from compilation.

Authenticated startup, revoked sessions, provider callbacks, account isolation,
physical-device/Reduce Motion verification, complete visual acceptance and
independent review remain open. This change does not complete #134, #136 or #137.

## Native Back-button failure and correction

Run 35511645436 at `e94698919ed3f17f5581cabe33663b4a6bc5e165` built the app and executed all 43 journeys: 42 passed, one failed, zero skipped. `testWelcomeGuideNavigationAndLocalCompletion` failed at the first `auth.back` tap on Login. Its enabled 44×44 accessibility frame existed, but XCTest reported no hittable point. Original recording shows the Login screen rendered after the transition; this was not a missing screen or a suite timeout. Original artifacts, full XCResult, diagnostics and raw logs were preserved.

Both Login and Sign Up now give the complete framed Back label an explicit rectangular hit area. Their decorative separator cannot intercept touches. Layout, account authorization and navigation actions are unchanged. The same journey now captures each account screen and asserts the Back control is hittable before the existing tap; no coordinates, skip, retry, or weakened navigation assertions substitute for the actual control.

Run 35516870053 at `3193d73c75ace4e5be9dc4f0cc36f1b371e7f1f0` showed that the hit-area correction alone was insufficient. The actual Login screenshot renders Back, but the unchanged hittability assertion still fails. That run executed all 44 journeys: 42 passed, two failed, zero skipped; the second failure concerns image-delete confirmation. Its full original evidence is preserved.

The next correction replaces routes without a transition transaction and removes the whole-form opacity/offset entrance animation from Login and Sign Up. Back retains the same position and 44-point content shape with an explicit plain button style. This removes layered animated hit-test state while preserving each screen's final appearance and navigation actions. The animation interaction is a diagnosis to verify, not a claimed proven runtime cause. Decorative animations within Welcome and the guide remain governed by their own Reduce Motion behavior.

The same native journey and hittability assertions must pass on the corrected source. No coordinate bypass, skipped navigation check or test retry is used. The preceding failures remain recorded and do not count as a passing entry-flow gate.

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
suite also includes the independent track-mute regression and contains 43 journeys with the same 180-second per-case and 3900-second
whole-suite limits; no retry, skip or assertion relaxation is introduced.

Local checks type-check the changed production views against the iOS SDK and
compile the XCTest definitions. These checks are not native runtime verification.
Runtime acceptance requires the app build and simulator journey from the same
source revision. Preserve the preceding exact-source CI outcome and originals
before advancing the workstream; do not infer a runtime pass from compilation.

Authenticated startup, revoked sessions, provider callbacks, account isolation,
physical-device/Reduce Motion verification, complete visual acceptance and
independent review remain open. This change does not complete #134, #136 or #137.

# Native entry flow — issues #136 and #137

The welcome, splash and five-page guide retain the supplied skull, dark shell,
white wordmark, feature hierarchy and page-specific red/blue/orange gradients.
The guide states the actual local capabilities and identifies unfinished Rooms,
War Room and cloud assistance. Historical user counts, cloud-sync promises,
guessed asset counts and provider claims are not shipped as facts.

## Behavior

- Splash shows the actual authentication restoration state (restoring, retryable
  failure, sign-in required, ready). It holds for a minimum of one second as
  intentional branding (`AppFlowView.minimumBrandingPresentation`, #136); this
  is a presentation floor, not a fake loading indicator: Open Studio Offline,
  Retry and Sign In are enabled throughout, an explicit action cancels the hold,
  and restoration itself is never delayed by it. A late result cannot navigate
  away from an explicit offline choice.
- Guest access opens the existing Studio tab directly without requesting an anonymous
  cloud account or swallowing a failed sign-in. Projects use the existing local
  production storage; no data migration or deletion is introduced. The guest
  choice is remembered (`sdi.guest.chosen.v1`): later launches skip Welcome and
  open the app, where Rooms, Calendar and Profile offer a Sign In button for
  guests. That button flushes the open Studio project, presents Login, and Back
  or success returns to the app with the same project (#137).
- Deep links are classified by `DeepLinkRouter` before any navigation (#138):
  `stickdeath://auth/callback` is rejected as unsolicited, `stickdeath://auth/reset`
  is completed only when this device holds the matching reset verifier, and every
  other URL shows an "Unsupported link" notice. No messaging, call or invite links exist.
- The first-run tutorial reads and writes the same `tutorial_completed` key, so
  completing or skipping it once persists. Tutorial and guide copy describe only
  shipped behavior: Rooms are invitation-based, both creators approve, sign-in is
  required, and there are no chat, call, comment or prize claims.
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

- Cold-launch routing is a pure function, `AppFlowView.startupDestination(
  isAuthenticated:guestChosen:guideCompleted:onboarded:)`: signed-in accounts go
  to the app (or to the guide when neither the local preference nor the server
  profile marks it complete), a remembered guest opens the app, everyone else
  sees Welcome. Every branch is pinned in `Tests/AuthState`
  (`testDeepLinkRouterClassifiesBeforeNavigation`, deferred native execution).
- The skull on Splash, Welcome, Login and the tutorial is `SDIBrandMark`: it
  renders the owner's artwork when an asset named `SDIBrandSkull` exists in the
  catalogue and otherwise shows the emoji as a clearly temporary placeholder.
  Supplying the approved artwork is an owner gate; the red glow, near-black
  background and white wordmark are in place and respect Reduce Motion.
- Leaving Studio is safe by construction: switching tabs or backgrounding runs
  the shared editor's flush (`BackgroundTaskScope.run` provides the
  background-task assertion; wiring it into `StudioView`'s scene-phase handler
  is a coordinator patch in this wave), sign-out flushes first and returns to
  the library only after the account is gone, and the in-app Sign In route
  flushes before presenting Login. The editor refuses to
  leave while a stroke or text draft is uncommitted and tells the person why.

## Epic #8 evidence (splash, welcome, truthful onboarding)

Splash shows the real restoration state with Retry, Sign In and Open Studio
Offline always enabled, holds one second as documented branding, and routes by
the pure function above (#136). Welcome, the five-page guide and the first-run
tutorial advertise only shipped behaviour: local Studio, invitation-based Rooms
with mutual approval and no chat or calls, War Room voting, licensed assets and
local Spatter help; completion is a device preference (`sdi.guide.completed.v1`,
`tutorial_completed`), the guest choice is remembered (`sdi.guest.chosen.v1`),
and guests can create, save and reopen offline projects and sign in later from
Rooms, Calendar or Profile (#137). Native journey evidence is recorded below;
the current revision has not been re-run natively.

## Epic #11 evidence (navigation, Rooms, protected routes)

`MainTabView` exposes Home, Challenges, Studio, Rooms and Profile only; the
Rooms tab hosts Calendar and the no-chat Watch Together route, and Profile hosts
the admin entry, which is server-authorised. There are no messaging or call
routes (`scripts/verify_retired_communications.py` passes). `DeepLinkRouter`
accepts only the auth callback (rejected as unsolicited) and the password-reset
link (completed only with this device's verifier); everything else is
"Unsupported link" (#138). Leave-Studio safety is described above. A native
UI journey through Rooms → Calendar → back and Rooms → Watch Together → back
that asserts the open project's revision is unchanged remains deferred.

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

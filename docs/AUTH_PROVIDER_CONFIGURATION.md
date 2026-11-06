# Identity-provider deployment contract

Google, GitHub and Microsoft buttons use the existing Supabase identity service through the system authentication session with PKCE. Existing sessions are restored by the SDK; a failed or cancelled new sign-in must not navigate using an older session. Apple retains its native identity-token flow.

Additional providers are disabled by default. Public build setting `SDI_OAUTH_PROVIDERS` accepts a comma-separated subset of `google,github,microsoft`; empty or unresolved values enable none. Microsoft also requires an explicit `SDI_MICROSOFT_TENANT`: `common`, `organizations`, `consumers`, or a tenant UUID. These are configuration values, not credentials. The client declaration does not enforce a server tenant policy.

Before enabling any provider, configure its callback and allowlist in the existing authenticated backend and provider console. Verify issuer, audience, tenant restrictions, account-linking behavior and stable user identity server-side. Do not link accounts merely because client-provided email strings match. Provider secrets stay server-side. GitHub sign-in requests identity/email scopes only, never repository access.

Exercise success, cancellation, denial, expired authorization, malformed callback, session restoration, account switching and sign-out against the configured provider before declaring it available. Microsoft tenant selection and owner consent are explicit deployment gates. No credentials or live cloud provider calls are needed for the injected native regression tests.

## Redirect allowlist

The client sends exactly two redirect targets and accepts nothing else: `stickdeath://auth/callback` for provider sign-in and `stickdeath://auth/reset` for password recovery. Both must be listed in the Supabase project's Redirect URLs allowlist; the Site URL may stay on the product website. A callback carrying `error=` is reported as a denial and never exchanged, even when a `code` is also present; a callback without exactly one `code`, with a fragment, or on another host/path is rejected. Recovery links complete only through the SDK's PKCE verifier stored by this device's own reset request, so a forwarded or replayed link cannot sign in elsewhere. All other `stickdeath://` URLs are shown as "Unsupported link".

## Manual linking only

Automatic identity linking must stay disabled in the Supabase Auth settings. Two providers that present the same email address are two accounts until the signed-in person links them deliberately through a future account-settings flow; the client never merges by email, username or any profile field, and `appleUsername(for:)` derives a `Creator_` handle for private-relay addresses instead of exposing or matching them.

## Apple credential revocation

After a session is restored, `AuthService.verifyAppleCredentialState()` asks `ASAuthorizationAppleIDProvider.getCredentialState(forUserID:)` for the Apple subject found in the server-side identity list (`appleUserIdentifier(for:)`, never email text). `ASAuthorizationAppleIDProvider.credentialRevokedNotification` re-runs the same check while the app is open. Only `.revoked` ends the session: the SDK session is cleared locally without waiting for remote revocation, the restoration state becomes "sign-in required" and a notice (not an error banner) says the Apple ID no longer authorizes the app and that local projects are unchanged. `.notFound` and `.transferred` leave the session alone. Closing the Apple sheet is a cancellation with no banner; the Apple buttons are disabled while any sign-in is loading; the first-authorization name is written to the user's own metadata and a private-relay address becomes a `Creator_` handle.

## Microsoft tenant

`SDI_MICROSOFT_TENANT` is displayed under the Microsoft button and must equal the tenant in the Azure provider's configured URL in Supabase (`https://login.microsoftonline.com/<tenant>/v2.0`). A mismatch produces an `AADSTS` denial, which the app shows as a Microsoft-declined sign-in rather than a generic callback error.

## Sign-up and recovery

Sign-up with email confirmation enabled returns no session; the app shows "Check your email to confirm your account" instead of an error. Forgot Password always shows the same neutral confirmation, applies a 60-second client cooldown, and relies on the server's rate limits for the actual send. Reinstalls start signed out: the first launch without the `sdi.installMarker` default clears any Keychain session locally before restoration.

The separate `StickDeathInfinityAuthTests` scheme contains the native regression cases (twenty functions: the original eleven plus denial, Apple handle and credential revocation, install marker, deep-link and cold-launch routing, recovery, sign-out Studio hand-off, DST calendar and account export cases; the additions were parse-checked only on the Linux implementation host and have not been executed there). CI clears backend/provider build settings and requires every test to pass with no failures or skips. Compilation alone does not satisfy execution. The main Studio UI suite remains a separate gate.

## Epic #9 evidence (sign-in with session restoration)

One `AuthService` owns every provider and the server UUID is the only account identity (`Services/Auth/AuthService.swift`); provider callbacks must match `stickdeath://auth/callback` with exactly one `code` and no `error=`, and unsolicited or replayed callbacks are refused (`handleOAuthCallback`, `DeepLinkRouter`). Apple uses a native nonce/state request with cancellation mapped to no banner, first-authorization name persistence, private-relay handles and the revocation check above; Google, GitHub (identity scopes only) and Microsoft (explicit tenant, `AADSTS` mapping) share the PKCE browser session with browser-cancel and `access_denied` mapped to calm messages. Restoration refreshes the Keychain session through the SDK, classifies revoked/expired/offline results separately, discards a session left by a previous install (`sdi.installMarker`) and keeps sign-in buttons disabled while loading. Forgot Password is neutral with a 60 s cooldown, sign-up awaiting confirmation shows "Check your email", a taken username is a notice, and account deletion is refused truthfully. All of this is covered by `Tests/AuthState` (deferred native execution); real provider sign-in on a configured device remains an owner-gated check.

## Current verified native deployment (6 November 2026)

Read-only discovery of the existing Release Supabase backend returned HTTP 200 at
12:26:30 UTC: Apple enabled; Google, GitHub and Azure/Microsoft disabled. The
native backend remains the Supabase project already declared by Release. The
separate Hostinger administrator identity service is not substituted for it.

Interactive Debug now uses the exact existing Release public endpoint and
publishable key. These are public client configuration, not provider credentials.
Both configurations explicitly leave SDI_OAUTH_PROVIDERS empty: a compiled button
must not advertise an unsupported Google, GitHub or Microsoft deployment. Apple
continues through the native identity-token flow; server enabled=true does not
prove a successful signed-device login, bundle audience, entitlement or account
restoration. Real Apple sign-in still requires that end-to-end verification.

Google, GitHub and Microsoft require genuine owner-controlled provider app
registration and server-side client credentials before enabling them. Keep secrets
off clients. Verify the intended project's exact native callback allowlist
(stickdeath://auth/callback, and stickdeath://auth/reset for recovery), issuer,
audience and account-linking policy. Microsoft additionally needs a matching
explicit tenant. Add a provider to the public list only after its server setup
and actual success/cancellation/denial flows are verified; no provider was enabled
or tested by this source change.

Existing offline Auth, Journey, Studio and unsigned Review CI empty overrides
remain unchanged. The Simulator compile/capture helper now also appends empty
values for its existing exact LIBRARY_OFFLINE_SETTINGS tuple before build. Its
offline refusal check and all command ownership, assertions and time budgets stay
intact. This prevents configured Debug defaults from connecting that CI helper to
the real backend; it does not establish new native runtime acceptance.

# Identity-provider deployment contract

Google, GitHub and Microsoft buttons use the existing Supabase identity service through the system authentication session with PKCE. Existing sessions are restored by the SDK; a failed or cancelled new sign-in must not navigate using an older session. Apple retains its native identity-token flow.

Additional providers are disabled by default. Public build setting `SDI_OAUTH_PROVIDERS` accepts a comma-separated subset of `google,github,microsoft`; empty or unresolved values enable none. Microsoft also requires an explicit `SDI_MICROSOFT_TENANT`: `common`, `organizations`, `consumers`, or a tenant UUID. These are configuration values, not credentials. The client declaration does not enforce a server tenant policy.

Before enabling any provider, configure its callback and allowlist in the existing authenticated backend and provider console. Verify issuer, audience, tenant restrictions, account-linking behavior and stable user identity server-side. Do not link accounts merely because client-provided email strings match. Provider secrets stay server-side. GitHub sign-in requests identity/email scopes only, never repository access.

Exercise success, cancellation, denial, expired authorization, malformed callback, session restoration, account switching and sign-out against the configured provider before declaring it available. Microsoft tenant selection and owner consent are explicit deployment gates. No credentials or live cloud provider calls are needed for the injected native regression tests.

## Redirect allowlist

The client sends exactly two redirect targets and accepts nothing else: `stickdeath://auth/callback` for provider sign-in and `stickdeath://auth/reset` for password recovery. Both must be listed in the Supabase project's Redirect URLs allowlist; the Site URL may stay on the product website. A callback carrying `error=` is reported as a denial and never exchanged, even when a `code` is also present; a callback without exactly one `code`, with a fragment, or on another host/path is rejected. Recovery links complete only through the SDK's PKCE verifier stored by this device's own reset request, so a forwarded or replayed link cannot sign in elsewhere. All other `stickdeath://` URLs are shown as "Unsupported link".

## Manual linking only

Automatic identity linking must stay disabled in the Supabase Auth settings. Two providers that present the same email address are two accounts until the signed-in person links them deliberately through a future account-settings flow; the client never merges by email, username or any profile field, and `appleUsername(for:)` derives a `Creator_` handle for private-relay addresses instead of exposing or matching them.

## Microsoft tenant

`SDI_MICROSOFT_TENANT` is displayed under the Microsoft button and must equal the tenant in the Azure provider's configured URL in Supabase (`https://login.microsoftonline.com/<tenant>/v2.0`). A mismatch produces an `AADSTS` denial, which the app shows as a Microsoft-declined sign-in rather than a generic callback error.

## Sign-up and recovery

Sign-up with email confirmation enabled returns no session; the app shows "Check your email to confirm your account" instead of an error. Forgot Password always shows the same neutral confirmation, applies a 60-second client cooldown, and relies on the server's rate limits for the actual send. Reinstalls start signed out: the first launch without the `sdi.installMarker` default clears any Keychain session locally before restoration.

The separate `StickDeathInfinityAuthTests` scheme contains the native regression cases (eleven at the previous revision plus the denial, Apple handle, install marker, deep-link, recovery and DST calendar cases added in this batch; none of the additions has been executed on the implementation host). CI clears backend/provider build settings and requires every test to pass with no failures or skips. Compilation alone does not satisfy execution. The main Studio UI suite remains a separate gate.

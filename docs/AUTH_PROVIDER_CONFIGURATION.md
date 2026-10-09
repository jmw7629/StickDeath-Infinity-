# Identity-provider deployment contract

Google, GitHub and Microsoft buttons use the existing Supabase identity service through the system authentication session with PKCE. Existing sessions are restored by the SDK; a failed or cancelled new sign-in must not navigate using an older session. Apple retains its native identity-token flow.

Additional providers are disabled by default. Public build setting `SDI_OAUTH_PROVIDERS` accepts a comma-separated subset of `google,github,microsoft`; empty or unresolved values enable none. Microsoft also requires an explicit `SDI_MICROSOFT_TENANT`: `common`, `organizations`, `consumers`, or a tenant UUID. These are configuration values, not credentials. The client declaration does not enforce a server tenant policy.

Before enabling any provider, configure its callback and allowlist in the existing authenticated backend and provider console. Verify issuer, audience, tenant restrictions, account-linking behavior and stable user identity server-side. Do not link accounts merely because client-provided email strings match. Provider secrets stay server-side. GitHub sign-in requests identity/email scopes only, never repository access.

Exercise success, cancellation, denial, expired authorization, malformed callback, session restoration, account switching and sign-out against the configured provider before declaring it available. Microsoft tenant selection and owner consent are explicit deployment gates. No credentials or live cloud provider calls are needed for the injected native regression tests.

The separate `StickDeathInfinityAuthTests` scheme contains five native regression cases. CI clears backend/provider build settings and requires all five tests to pass with no failures or skips. Compilation alone does not satisfy execution. The main 72-case Studio UI suite remains a separate gate.

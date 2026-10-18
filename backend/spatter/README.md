# Spatter cloud-advice handler (contract implementation)

`handler.py` is the server side of the versioned, provider-neutral Spatter
transport that `StickDeathInfinity/App/SpatterBackendClient.swift` speaks. It is
standard-library Python, framework-free, and makes no provider, network or
database call on its own. Deployment wires it to an HTTPS runtime and injects
the three collaborators below. **No provider is configured by this change**; the
default `NullProvider` answers `503 {"error":"not configured"}` and the iOS
client shows "Spatter cloud is not configured on the server" and keeps local
guidance. No paid external AI call is made anywhere in this repository.

## Contract (schemaVersion 1)

Request `POST <SPATTER_BACKEND_URL>` with `Authorization: Bearer <Supabase access token>`:

```json
{"schemaVersion": 1, "messages": [{"role": "system|user|assistant", "content": "…"}], "max_tokens": 500, "temperature": 0.8}
```

Bounds enforced server-side (mirroring the client): body ≤ 128 KiB, 1–41
messages, each non-blank and ≤ 32 KiB, last message from the user. A missing
`schemaVersion` is the legacy client; `≥ 2` is refused with 400.

Response:

```json
{"schemaVersion": 1, "reply": "…", "usage": {"units": 42}, "budget": {"remaining": 17, "resetsAt": "2026-10-13T00:00:00Z"}}
```

Errors use the same envelope with `error` instead of `reply`:
`400` malformed/unsupported, `401` missing/invalid/expired token, `403` non-user
role, `413` too large, `429` daily budget exhausted, `502` provider failure,
`503` not configured (or metering refusal; see Metering). The client maps 503 and 429 to honest unavailable states.
The legacy `{"choices":[{"message":{"content"}}]}` shape is still decoded by the
client but is not produced here.

## Supabase JWT verification contract

`verify_jwt(token) -> claims` must:

1. Verify the signature against the project's JWKS (`/auth/v1/.well-known/jwks.json`,
   RS256/ES256) or, for legacy projects, the JWT secret (HS256). Never accept `alg: none`.
2. Require `exp` in the future, `aud == "authenticated"`, and the project issuer.
3. Return the claims; the handler additionally refuses `role` values other than
   `authenticated` (service-role and anon keys never carry a user request).

The token is read from the `Authorization` header only, never from the body or
query, and is never logged. The handler re-checks `exp` against its own clock.


`jwt_hs256.make_hs256_verifier(secret, issuer)` implements this contract for
HS256 projects with the standard library (constant-time signature check, `alg`
must be `HS256`, `exp`/`nbf` with 30 s leeway, audience and issuer). The
deployment passes the secret from its own environment; the module never reads
or logs it. Asymmetric (JWKS) projects need a verifier built on a vetted crypto
library; `jwt_hs256` refuses those tokens instead of guessing.

## Metering (#209): plan allowances, safety limits and the emergency stop

Pass `meter=metering.SqlMeter(rpc)` to `handle` (the legacy `budget` argument is
kept for the original daily-budget tests). `SqlMeter` calls the service-only RPC
`public.sdi_spatter_usage_meter` defined at the end of
`backend/sql/spatter-draft-jobs.sql` (unapplied deployment candidate, tested by
`backend/sql/tests/070_spatter_draft_jobs.sql`). Order of checks, all server-side:

1. account exists and is not suspended/banned (`account_controls`);
   then **Free without Spatter credits is refused** (owner decisions
   2026-10-15): Free has no server-funded allowance, so a Free request with a
   zero credit balance gets 402 `upgrade_required` + `plan: free` + `upgrade:
   creator_or_pro` + `buyCredits: true` + `credits: 0` and the message
   "Spatter is part of Creator and Pro, or buy Spatter credits to pay as you
   go." before any counter, reservation or provider call;
2. agent emergency stop (`sdi_private.agent_global.emergency_stop`) → 503 `emergency_stop`;
3. global daily ceiling → 503 `global_limit` (**defaults to 0, i.e. closed, until the owner sets it**);
4. per-account per-minute rate (default 6) → 429 `rate_limited` + `retryAfterSeconds`;
5. per-account daily safety cap (default 100) → 429 `daily_safety_limit`;
6. funding, in order: the plan allowance from `sdi_private.entitlements`
   (Pro unlimited; Creator's period allowance), then **one Spatter credit**
   (1 credit = 1 prompt). Nothing left → Creator gets 429
   `plan_allowance_exhausted` + `upgrade: pro` + `buyCredits: true`; Free gets
   the 402 above. Free with credits pays as it goes (free text allowed). Pro
   never spends credits. Steps 2–5 apply before any credit is spent:
   * `creator` (USD 4.99/month): `floor(creator_period_budget_microusd /
     prompt_cost_estimate_microusd)` server-funded prompts per billing period
     (defaults 3 490 000 / 20 000 = 174: USD 4.99 net of a 30% store commission
     at a conservative USD 0.02 per prompt; the budget is capped at the gross
     price), keyed to `paid_through`, so a renewal opens a new period;
   * a paid request may carry `suggestedPromptId` from the fixed allowlist
     (`suggested_prompts.py`, mirrored by `sdi_private.spatter_suggested_prompt_ids()`
     and the iOS `SpatterSuggestedPrompt.all`; `test_suggested_prompts.py` keeps
     all three identical); an unknown id is 400 `unknown_suggested_prompt`;
   * `pro` (USD 9.99/month): unlimited by plan; steps 1–5 still apply.
   * The free trial applies to both paid plans: a `trialing` subscription is
     metered as its own tier (Creator or Pro), not as Free.
   * Creator and Pro members may add their own AI key in the app. Those requests
     go directly from the device to the member's provider and never reach this
     handler or the meter, so they do not count against the allowance.

A reservation is taken only after the provider is known to be configured, and
settled exactly once: `commit` with provider usage units after a reply,
`release` (refunds every counter, and a spent credit as a `release` ledger
row) after a provider failure. Stale reservations
are swept as committed, never silently refunded. Prompt text is never stored.

Successful metered replies carry `allowance` instead of the daily `budget`:

```json
{"schemaVersion": 1, "reply": "…", "usage": {"units": 9}, "allowance": {"plan": "creator", "period": "billing_period", "remaining": 173, "resetsAt": "2026-11-01T00:00:00Z", "credits": 0, "funding": "allowance"}}
```

`remaining` is `null` for `pro`; `resetsAt` is the renewal date for `creator`
(`null` and `period: "none"` for `free` and `pro`). `credits` is the Spatter
credit balance after this prompt; `funding` is `allowance`, `unlimited` or
`credit`. A Free pay-as-you-go reply looks like
`{"plan": "free", "period": "none", "remaining": 0, "resetsAt": null, "credits": 2, "funding": "credit"}`.
Provider usage units (tokens) are recorded on commit; actual provider cost is
not, because the provider contract does not return it. Error bodies add `code` (and `retryable` for 502). Signed-in users read
their own allowance and credit balance with `public.sdi_spatter_my_usage()`
(for Settings; shape in `docs/BILLING_CONTRACT.md`); the owner
reads/changes limits with `public.sdi_spatter_usage_admin('get'|'set', …)`,
revisioned, reason-required and audited in `sdi_private.agent_audit`.

## Provider routing

`providers.ProviderRouter` holds the active `RouteConfig(provider, model,
timeout_seconds ≤ 60, max_attempts 1–3)`. A model or provider switch replaces
the configuration atomically and is validated against the injected adapters.
Each attempt runs with a timeout; timeouts and adapter-declared transient
failures are retried with backoff, permanent failures are not. Adapter
exception text is never propagated (it can contain key material). An empty
router reports `configured == False` and the handler answers 503 without
touching any allowance.

## Daily-draft renderer (#212): headless macOS CLI

`draft_queue.run_once` renders through `draft_queue.configured_renderer()`,
which returns `renderer_cli.CLIRenderer` only when `SDI_DRAFT_RENDERER_CLI` is
the absolute path of the compiled `Tools/SpatterDraftRenderer` binary (macOS;
built from the production planner, command executor, movie exporter and quality
report). Unset, every job still fails with the OWNER-GATED capacity message.
Optional: `SDI_DRAFT_RENDER_DIR` (private output root), `SDI_DRAFT_RENDER_FPS`/
`_WIDTH`/`_HEIGHT` (default 24 FPS, 640×360) and
`SDI_DRAFT_RENDER_TIMEOUT_SECONDS` (default 600, at most 840 so a render ends
inside the 15-minute lease; the lease is renewed every 60 s while it runs).

The adapter re-hashes the movie, manifest and editable project named by the
receipt, requires `private_draft: true` / `published: false`, matches brief,
seed and size to the job, and fails a passing verdict whose decoded frame count
or duration disagrees with the plan. A `publish_preview(movie, sha256, plan)`
callable must return the private HTTPS preview URL for the owner's review row;
without one the render fails before running. Drafts stay in the output root for
review; failed runs are deleted. Nothing is uploaded, released or scheduled:
release still needs the owner's approval of the exact render digest.
Daily plans use `briefs.v3`: `plan_brief` shortens a plan (never below 2 s)
until it fits the app planner's element budget at 24 FPS (`fits_element_budget`
mirrors `SpatterMultiClauseBrief.prepare`), so the renderer FPS is capped at 24.

Private previews (`draft_preview.py`): with `SDI_DRAFT_PREVIEW_OWNER_ID`,
`SDI_INTAKE_ORIGIN`, `SDI_PREVIEW_SIGNING_KEY_FILE` and `SDI_INTAKE_DIRECTORY`
set, `renderer_from_env` uses `DraftPreviewStore`: it copies the verified MP4
into the intake directory, records owner, digest, size and retention (default
7 days, at most 14; `SDI_DRAFT_PREVIEW_RETENTION_SECONDS`) and signs a
`PreviewLinks` URL (at most 15 minutes). The intake host's `PreviewApplication`
serves it only to a link signed for that owner while the record is live (the
same owner variable enables `combined_authority` in `ingestion/application.py`).
`DraftPreviewStore.link()` re-signs a fresh link; `expire()` deletes expired
copies. Without the owner id the renderer fails with the OWNER-GATED preview
message.
`test_renderer_cli.py` and `test_draft_preview.py` drive fake executables; the macOS CI step
"Render one daily brief with the headless draft renderer" runs the real binary
through `scripts/backend/verify_draft_renderer_cli.py`.

## Tests

`python3 -I -m pytest backend/spatter -q` (or `python3 -m unittest
backend.spatter.test_handler backend.spatter.test_metering`) runs the contract
with fakes: JWT acceptance/rejection (including a real HS256 verifier with a
per-run random key), expiry, role refusal, bounds, 503 without a provider (no
allowance consumed), every metering refusal code, Free refusal (upgrade_required), creator cost-model and pro allowances,
renewal reset, refund-once settlement, meter outage, retries, timeouts, model
switches and credential non-disclosure. No sockets, provider or database.
`scripts/backend/run_sql_tests.sh` runs the SQL rules on a throwaway PostgreSQL.

## Remaining (owner-gated or deferred)

* Owner: choose and configure a provider adapter and model, deploy the
  function, apply the SQL, and set `global_daily_cap` above 0.
* Owner decisions (implemented in source; metering revised 2026-10-15): Free =
  Spatter visible, pay as you go with purchased credits, otherwise
  `upgrade_required`; credit packs need owner approval and store products; Creator $4.99 = own AI
  key + break-even server allowance (default 174 per period); Pro $9.99 =
  unlimited + own AI key; trial on both paid plans. See
  docs/SPATTER_BILLING_DECISIONS_2026_10_14.md for the earlier decisions.
* The iOS client now decodes `allowance` and reads the remaining count from
  `sdi_spatter_my_usage`; non-2xx JSON error bodies (`code`, `retryAfterSeconds`)
  are still not read by the bounded transport, so the client refreshes the
  server usage after a refusal instead.
* Live integration runs (real provider failures, rate limits, token expiry
  against a deployed project) are deferred. Nothing here claims a deployment.

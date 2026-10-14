# Spatter plans — owner decisions of 2026-10-14 (#209, #259)

Owner: Joseph Willis. These decisions supersede the 2026-10-07 interim rule
("5 free prompts, one-time") and the "bring-your-own key not built" notes.

| Plan | Price | Spatter | Own AI key | Trial |
| --- | --- | --- | --- | --- |
| Free | none | **5 suggested prompts per calendar month** (the app's suggested prompts only; no typed questions to cloud advice) | no | no |
| Creator | USD 4.99 / month | **15 prompts per month** (per billing period) | **yes** | yes, when the store offers one |
| Pro | USD 9.99 / month | **unlimited** (safety limits still apply) | **yes** | yes, when the store offers one |

Local guidance (cloud advice off) runs on the device, calls no provider and is
not a metered prompt, so it keeps free-text input on every plan.

## Free: suggested prompts only, 5 per month (server-enforced)

* Allowlist ids: `animation_tips`, `scene_ideas`, `fight_choreography`,
  `style_advice` — the four suggestion chips the iOS app already showed. One
  list in three places, checked identical by
  `backend/spatter/test_suggested_prompts.py`:
  `StickDeathInfinity/App/SpatterBackendClient.swift` (`SpatterSuggestedPrompt.all`),
  `backend/spatter/suggested_prompts.py`, and
  `sdi_private.spatter_suggested_prompt_ids()` in `backend/sql/spatter-draft-jobs.sql`.
* SQL (`sdi_private.spatter_usage_reserve`, via `public.sdi_spatter_usage_meter`
  with the new `p_suggested_prompt`): a Free account without an allowlisted id is
  refused with `suggested_prompt_required` (upgrade `creator_or_pro`) before
  anything is counted; an unknown id is `unknown_suggested_prompt`. The Free
  counter bucket is `month:<UTC yyyy-mm>`; `period` is `calendar_month` and
  `resets_at` is 00:00 UTC on the first of the next month.
* Handler: `suggestedPromptId` is validated against the allowlist; for Free it
  discards every client message (history and client system prompt) and sends the
  provider only a fixed server system line plus the canonical prompt text for the
  id. Refusal statuses: 403 `suggested_prompt_required`, 400
  `unknown_suggested_prompt`, 429 `plan_allowance_exhausted`.
* iOS (`SpatterAIViewModel`, `SpatterPlanControls.swift`, both Spatter
  surfaces): with cloud advice on and no server-reported paid plan, the text
  field is disabled with the reason and a "See Creator and Pro plans" link
  (SubscriptionView); the chips send their suggested prompt. The remaining count
  and lockout come only from the server (`sdi_spatter_my_usage`, or a metered
  reply's `allowance`); at zero the chips are disabled with the reset date and an
  upgrade link.

## Creator and Pro: own AI key

* Storage: `KeychainSpatterOwnKeyStore` — one generic-password item per signed-in
  account, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
  `kSecAttrSynchronizable = false`. Never sent to the StickDeath backend, never
  logged; `SpatterOwnKeyCredential` redacts the key from descriptions and mirrors.
* Controls: "Own AI key…" in both Spatter panels opens
  `SpatterOwnKeySettingsView` — add, replace, remove (with confirmation); saving
  is allowed only when the server last reported Creator or Pro.
* Providers: OpenAI (chat completions) and Anthropic (messages) — the two key-based
  providers the existing transport already names; the member types the model name.
  Endpoints are fixed constants; no member-supplied URL can receive the key.
* Routing (`SpatterService.chatReply`): when the server last reported a paid plan
  and a valid key is saved for the account, the request goes device → provider
  through `SpatterDirectProviderClient` (bounded: 128 KiB request/response caps,
  30 s / 45 s timeouts, ephemeral session, no redirects, key-free errors) and is
  not counted. Otherwise the normal metered backend path is used.
* The plan gate for the own key is a client-side check against the server's
  reported plan. Bypassing it on a modified device would only spend the member's
  own provider account; it never reaches StickDeath's provider or allowance.
* The source gate `scripts/verify_spatter_client.py` now allows the two provider
  endpoints in exactly one file (`Services/Spatter/SpatterOwnKey.swift`), forbids
  logging calls and backend-client use there, and requires the Keychain
  this-device-only, non-synchronizable attributes.

## Trial on both paid plans

`BillingPlanDefinition.offersTrial` is true for Creator and Pro. Trial copy is
still shown only when the App Store reports an eligible introductory free-trial
offer for that product (`BillingCopy.trial(for:days:eligible:)`). Server side, a
`trialing` subscription maps to its own tier (`backend/billing/contract.py`
`TRIAL_TIERS`; `sdi_private.entitlements`), so a Creator trial meters as Creator
and a Pro trial as Pro (SQL test 070).

## Evidence and what is not verified

* Run here: `scripts/backend/run_sql_tests.sh`, `python3 -m pytest backend/tests
  backend/spatter scripts/backlog -q`, `python3 scripts/verify_spatter_client.py`,
  `python3 scripts/verify_native_compile_sources.py`.
* Deferred to macOS / Linux-Swift CI (no Swift compiler on this host):
  `Tests/SpatterOwnKey` (new CI step "Verify Spatter plan access and own AI key
  client against fake transports"), `Tests/SpatterConversation` (new Free-plan
  test), `Tests/BillingPlans`, and the app build.
* Owner-gated: configure the introductory free-trial offer on both App Store
  subscriptions (and Stripe trial settings for both web prices if used), apply
  the SQL, deploy the handler with a provider, set `global_daily_cap` > 0. No
  real provider call, key or charge was used.

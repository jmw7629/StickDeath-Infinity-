# Billing Contract (native iOS)

Status: implementation batch, 2026-10-12; plans revised 2026-10-20 (three paid
tiers, 3-day trials). Verification deferred to the final integration phase;
nothing below is claimed as passed unless a command is named with its result. Source of authority:
`AGENTS.md` (owner scope 2026-09-19 and later) and
`docs/PRODUCT_SCOPE_2026_09_19.md` line 61.

## Approved plan contract (owner decision 2026-10-20)

Configured by the owner in App Store Connect. Supersedes the 2026-10-15 "no
trial" and "Pro unlimited / Creator break-even" decisions recorded below, which
are kept for history.

| Plan | Cadence | Requested price | Release product id | Placeholder (Debug/CI) | Tier mapping |
| --- | --- | --- | --- | --- | --- |
| Creator | Monthly, auto-renewable, 3-day free trial | USD 4.99 | `com.willisbmb.StickDeathInfinity.creator.monthly` | `com.stickdeath.infinity.creator.monthly` | `AppConfig.SubscriptionTier.creator` |
| Pro | Monthly, auto-renewable, 3-day free trial | USD 9.99 | `com.willisbmb.StickDeathInfinity.pro.monthly` | `com.stickdeath.infinity.pro.monthly` | `AppConfig.SubscriptionTier.pro` |
| Unlimited | Monthly, auto-renewable, 3-day free trial | USD 19.99 | `com.willisbmb.StickDeathInfinity.unlimited.monthly` | `com.stickdeath.infinity.unlimited.monthly` | `AppConfig.SubscriptionTier.unlimited` |

- Exactly three paid plans exist, ranked **Unlimited > Pro > Creator > Free**
  (`BillingPlanTier.rank` 3/2/1/0). The retired, never-sold `studio` enum case
  was replaced by `unlimited` in `AppConfig.SubscriptionTier`; a server tier of
  `studio` is still refused.
- Entitlements:
  - **Free**: unchanged. Studio limits (`StudioPlanLimits.free`); Spatter
    preview-only (suggested prompts plus the upgrade note); Spatter credits pay
    as you go.
  - **Creator**: full Studio, own AI key, **250** server-funded Spatter prompts
    per billing period (`SpatterPromptAllowance.perPeriod(250)`).
  - **Pro**: full Studio, own AI key, **500** prompts per billing period
    (`.perPeriod(500)`).
  - **Unlimited**: full Studio, own AI key, unlimited prompts (`.unlimited`).
  - Credit packs are unchanged and keep Spatter going after a Creator or Pro
    allowance.
- **Free trial**: every paid plan has a 3-day free trial (Apple introductory
  offer). During the trial the Studio is fully unlocked but Spatter is
  preview-only: it shows the suggested prompts and `BillingCopy.spatterTrialNote`
  (Spatter starts when the paid period begins; subscribe or upgrade in Profile,
  Plans to start sooner), sends nothing to the server and uses no credits
  (`StudioPlanLimits.trial`, `spatterActive == false`,
  `spatterTrialPreview == true`). The trial is detected from StoreKit
  (`Transaction.offerType == .introductory` →
  `BillingEntitlementSnapshot.isIntroductoryOffer` → `BillingState.inTrial`) and
  from the server: `sdi_my_entitlement` and `sdi_spatter_my_usage` may report an
  optional `in_trial` or `trial` boolean (missing means false); a `trialing`
  entitlement status also counts. Free never has a trial.
- Combining sources (`StudioPlanLimits.effective(storeTier:storeInTrial:serverTier:serverInTrial:enforcing:)`):
  the higher tier wins and carries its own source's trial flag; for an equal
  tier Apple's on-device signed transaction decides.
- The price the user is charged is the price Apple shows at checkout. The app
  never hard-codes a price string; it displays `Product.displayPrice` from the
  loaded StoreKit product or an honest "not configured" state.
- Annual plans: **not configured.** No annual product id, price or entitlement
  exists, and there is no annual Unlimited key. `BillingPlanCatalog` offers an annual plan only when the build sets
  `SDI_BILLING_ANNUAL_OWNER_CONFIGURED = YES` **and** an annual product id
  (`SDI_STOREKIT_PLAN_4_99_ANNUAL_PRODUCT_ID` / `SDI_STOREKIT_PLAN_9_99_ANNUAL_PRODUCT_ID`);
  the server additionally refuses to approve an annual product without
  `owner_configured_at`. Amounts stay in App Store Connect.

## Product identifier configuration

`StoreProductID` reads the identifiers from `Bundle.main.infoDictionary` using
the existing `$(VAR)` xcconfig pattern and falls back to the placeholders above:

| Info.plist key | Plan |
| --- | --- |
| `SDI_STOREKIT_PLAN_4_99_PRODUCT_ID` | Creator, USD 4.99 monthly |
| `SDI_STOREKIT_PLAN_9_99_PRODUCT_ID` | Pro, USD 9.99 monthly |
| `SDI_STOREKIT_PLAN_19_99_PRODUCT_ID` | Unlimited, USD 19.99 monthly |

Release builds fill all three keys with the `com.willisbmb.StickDeathInfinity.*`
ids above. Debug/CI builds leave them unexpanded, so the placeholders are used
and `StoreProductID.usesPlaceholderIdentifiers` is `true` (it is true while any
one of the three is missing), which also keeps Studio limits unenforced.

## One plan configuration (#259, 2026-10-14)

`StickDeathInfinity/Services/Stripe/BillingPlanCatalog.swift` (Foundation only) is
the single source for plans, periods, purchase state and plan copy. Both views and
`StoreProductID` read it; nothing else lists plans.

Historical table (2026-10-14/15). The current plans are in the 2026-10-20
contract at the top of this file.

| Plan | Product | Owner-stated entitlements (2026-10-07, #250/#259) | Enforced today |
| --- | --- | --- | --- |
| Free | none | Full Studio on device; no video upload/download; **Spatter visible with its suggested prompts; works only on purchased Spatter credits** (pay as you go; with no credits every request is refused with `upgrade_required`; the server funds nothing) | Studio only |
| Creator | USD 4.99 monthly (`com.willisbmb.StickDeathInfinity.creator.monthly`) | No watermark; upload/download; **own AI key** (prompts sent with it are not counted) plus **250 server-funded Spatter prompts per billing period** (reset at renewal) | server: Spatter meter (candidate) |
| Pro | USD 9.99 monthly (`com.willisbmb.StickDeathInfinity.pro.monthly`) | Everything in Creator; **500 server-funded Spatter prompts per billing period**; **own AI key** | server: Spatter meter (candidate) |
| Unlimited | USD 19.99 monthly (`com.willisbmb.StickDeathInfinity.unlimited.monthly`) | Everything in Pro; **unlimited Spatter prompts** (still under the per-user daily safety cap, per-minute rate, the owner's global daily ceiling and the emergency stop); **own AI key** | server: Spatter meter (candidate) |

**Owner decision 2026-10-20 (backend):** three monthly tiers, ranked unlimited >
pro > creator, each with a **3-day free trial** (App Store introductory offer,
configured in App Store Connect). During the trial the Studio is fully unlocked
but Spatter is preview-only: the server funds no prompt and spends no credit
while an account's only entitlements are in a free-trial period, and answers
with Free's refusal shape (`upgrade_required`, plan = the trial tier,
`trial: true`, `upgrade: after_trial`, `resets_at` = trial end). The first paid
period converts the trial to the tier's normal allowance. This supersedes the
break-even Creator allowance, "Pro unlimited" and "no free trial" below; the
native clients are not changed by this backend batch. Server objects:
`billing_products.tier` accepts `unlimited`; `subscriptions.in_trial` /
`entitlements.in_trial`; `spatter_usage_controls.creator_period_prompts` (250) /
`pro_period_prompts` (500); live projects apply
`backend/sql/upgrades/2026-10-20-three-tiers.sql`.

Owner decisions 2026-10-14 (#209/#259), Spatter metering revised 2026-10-15:
Free = Spatter visible but not active (no server-funded prompts; requests are
refused with `upgrade_required`, upgrade `creator_or_pro`, before anything is
counted; the former 5-per-month Free allowance is retired); Creator $4.99 = own
AI key + server-funded prompts per billing period of
`floor(creator_period_budget_microusd / prompt_cost_estimate_microusd)`, defaults
3 490 000 (USD 4.99 net of a 30% store commission, rounded down; the budget can
never exceed the 4 990 000 gross price) / 20 000 (USD 0.02, an owner-editable
conservative estimate per prompt) = 174; Pro $9.99 = unlimited (still under the
safety, rate and global caps and the emergency stop) + own AI key; **there is no
free trial on any plan** (owner decision 2026-10-15). Actual provider cost is not
recorded (the provider contract returns usage units only). Background:
`docs/SPATTER_BILLING_DECISIONS_2026_10_14.md`.

### Spatter credits (owner decision 2026-10-15, later)

"You can purchase more credits to keep going and in free you can pay as you go
if you want." Implemented server side (unapplied candidates, tested locally):

- **Packs** are consumable store products in
  `sdi_private.spatter_credit_packs(product_id, provider apple|stripe|google,
  credits 1..100000, approved)`. No price is stored; the stores own prices.
  Finance administrators list packs; only the owner with a recent MFA step-up
  approves them (`public.sdi_spatter_credit_admin('set_pack', …)`, audited in
  `finance_audit`). The owner may also make a signed goodwill/correction grant
  (`'grant'`, never below zero, audited) and read a member's history
  (`'balance'`).
- **Ledger**: append-only `sdi_private.spatter_credit_ledger` (`purchase`,
  `spend`, `release`, `refund`, `admin_grant`); balance = `sum(delta)`, never
  negative; purchases and refunds are unique per (provider, transaction), so
  every grant and claw-back happens once. Sandbox / Stripe test-mode grants are
  allowed and flagged `livemode = false`; credit grants never write
  `finance_ledger` rows (live Stripe pack charges are recorded by the webhook's
  normal ledger path; sandbox never).
- **Metering**: caps first (emergency stop, global, per-minute, daily safety),
  then the plan allowance (Unlimited never spends credits; Creator's and Pro's
  period allowance), then one credit per prompt. Free with credits pays as it
  goes; Free with none gets `upgrade_required` ("Spatter is part of Creator, Pro
  and Unlimited, or buy Spatter credits to pay as you go."); Creator or Pro with
  neither allowance nor credits gets `plan_allowance_exhausted` with
  `upgrade: pro` (Creator) or `upgrade: unlimited` (Pro) and `buyCredits`. A
  trial-only account is refused before credits are considered. A released
  (failed) prompt refunds its credit.
- **Purchases**: Apple consumables are not announced by App Store Server
  Notifications at purchase, so the app posts the StoreKit 2 signed transaction
  to `backend/billing/appstore_credits.py` (member JWT + the same pinned-root
  JWS verifier; `appAccountToken` must equal the member). Apple `REFUND`
  notifications for packs claw back; a `ONE_TIME_CHARGE` notification also
  grants (idempotent). Stripe: `stripe_checkout` `action: "credits"` builds a
  one-time `mode=payment` session for an approved pack; `stripe_webhook` grants
  on a paid `checkout.session.completed` (or `async_payment_succeeded`) keyed
  by the PaymentIntent, and a fully refunded `charge.refunded` claws back.
  Partial Stripe refunds do not claw back automatically (owner adjusts with
  `'grant'`). **Google Play: not implemented** — no Play purchase verification
  path exists in this repository; `google` packs can be configured but nothing
  grants them.
- **Refund clawback** takes back up to the remaining balance; credits already
  spent are recorded as the refund row's `shortfall`.
- **Usage JSON** (`public.sdi_spatter_my_usage()`; the reserve result and the
  handler's `allowance` carry the same `credits`):

  ```json
  {"plan": "free", "unlimited": false, "limit": 0, "used": 0, "remaining": 0, "period": "none",
   "resets_at": null, "credits": 12, "available": true, "upgrade": "creator_or_pro", "service": "metered"}
  {"plan": "creator", "trial": false, "unlimited": false, "limit": 250, "used": 250, "remaining": 0, "period": "billing_period",
   "resets_at": "2026-11-01T00:00:00+00:00", "credits": 5, "available": true, "service": "metered"}
  {"plan": "pro", "trial": false, "unlimited": false, "limit": 500, "used": 12, "remaining": 488, "period": "billing_period",
   "resets_at": "2026-11-01T00:00:00+00:00", "credits": 0, "available": true, "service": "metered"}
  {"plan": "unlimited", "trial": false, "unlimited": true, "limit": null, "used": null, "remaining": null, "period": "none",
   "resets_at": null, "credits": 0, "available": true, "service": "metered"}
  {"plan": "pro", "trial": true, "unlimited": false, "limit": 0, "used": 0, "remaining": 0, "period": "trial",
   "resets_at": "2026-10-23T12:00:00+00:00", "credits": 0, "available": false, "upgrade": "after_trial", "service": "metered"}
  ```

  `available` is true when the plan allowance or credits remain (always for
  Unlimited; never during a free trial); `service` is `paused` under the
  emergency stop.

- Every paid entitlement carries `isLive = false` and is shown with a pending marker
  and the note that it turns on when the server applies the plan from Apple's
  verified purchase. No server enforcement is claimed.
- Remaining prompts: `BillingCopy.prompts` shows a remaining count only when
  the server reports one (`sdi_spatter_my_usage` or a metered reply's
  `allowance`); otherwise the plan line states the plan's published allowance
  (250 or 500 per billing period) without a remaining count. A server-reported
  limit caps the count; otherwise the plan's allowance does. Free shows its
  credit balance and offers a paid plan or credits; Creator at zero offers Pro
  or Unlimited, own key or credits; Pro at zero offers Unlimited, own key or
  credits. The client decodes server plan `unlimited` (no counts) and treats
  `pro` as metered.
- Trial (owner decision 2026-10-20, replacing "none" of 2026-10-15):
  `BillingPlanDefinition.offersTrial` is true for every paid tier.
  `StripeService.trialCopy(for:)` shows `BillingCopy.trial` ("3-day free trial")
  only when the loaded product has an introductory offer with
  `paymentMode == .freeTrial` and `Product.SubscriptionInfo.isEligibleForIntroOffer`
  is true for the account; the length is Apple's, never assumed. Server side, a
  provider-reported trial maps to `trialing` with `in_trial`
  (`backend/billing/contract.py` `TRIAL_TIERS` = all three tiers); the
  entitlement grants the tier, but the Spatter meter refuses server-funded
  prompts (HTTP 402, `trial: true`) until the first paid period.
- Bring-your-own AI key (#209): listed as a pending entitlement on Creator, Pro
  and Unlimited. The key is stored only in the device Keychain
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable), is sent
  only from the device to the chosen provider's fixed endpoint, and never to the
  StickDeath backend.
- Prices: `BillingCopy.price(Product.displayPrice, period:)`, or "Price shown when
  configured". No amount, sale or "popular" claim exists in source.

### StoreKit state machine

`BillingState.reduce(_:_:)` takes StoreKit facts as events and yields one phase:
`loadingCatalog`, `catalogUnavailable(notConfigured | storeUnreachable)`, `free`,
`purchasing`, `pending` (Ask to Buy), `subscribed(snapshot)` or `lapsed(snapshot)`.
Snapshots carry Apple's renewal state (`subscribed`, `inGracePeriod`,
`inBillingRetry`, `expired`, `revoked`), `willAutoRenew` from verified renewal info
(unknown when unverified), the period end and whether an introductory offer applies.
Rules: a cancelled or failed purchase returns to the previous phase; an unverified
transaction grants nothing; a refresh during a purchase does not end it; pending
survives refreshes; the highest tier wins; grace keeps access, billing retry without
grace and revocation do not. Server verification is a separate field that starts as
`deferred` and is never reported as verified until the server answers.
`StripeService` feeds the machine from `Product.purchase`, `Transaction.latest(for:)`
and `transaction.subscriptionStatus` (iOS 17). Standalone suite:
`Tests/BillingPlans/main.swift` (Foundation only; compiles and runs with a Linux
Swift toolchain as well as in the macOS CI job).

Settings (`SubscriptionView`) shows the status title/detail (renews on / auto-renew
off, access ends on / grace / billing retry / revoked / ended), Apple's price, the
server-verification line, the plan's entitlements and prompt line, **Manage or
Cancel Subscription** (Apple's `manageSubscriptionsSheet`, then a refresh), Restore
Purchases, and a monthly/annual picker only when annual is configured.

## Implemented client-side (StoreKit 2)

File: `StickDeathInfinity/Services/Stripe/StripeService.swift`
(the historical type name is kept because the Xcode project references the
file; the client calls no Stripe API).

- `loadProducts()` fetches the three approved monthly ids; an empty result sets
  `productLoadState = .notConfigured`, an error sets `.failed(message)`. It also
  records each product's introductory-offer eligibility (refreshed after each
  entitlement refresh) for trial copy.
- `applyStudioLimits()` derives `StudioPlanLimits.current` from Apple's tier and
  trial flag plus the server entitlement's tier and trial flag, and re-runs
  whenever the tier, the store load state, the billing state or the server
  record changes.
- `purchase(_:)` / `subscribe(to:)` call `Product.purchase(options:)` with
  `appAccountToken` set to the signed-in Supabase user id (UUID). Purchase
  requires sign-in so the server can later link Apple's transaction to the
  account. Verified transactions are finished; `userCancelled` and `pending`
  are surfaced as errors, never as success.
- `refreshEntitlements()` reads `Transaction.currentEntitlements`, skips revoked
  transactions and exposes the highest approved tier as
  `SubscriptionStatus.active(ActiveEntitlement)` with the real transaction id,
  product id, purchase date and Apple-supplied expiration date (nil when Apple
  does not supply one). Otherwise `.none`.
- `restorePurchases()` runs `AppStore.sync()` and reports a failure in
  `lastError` instead of swallowing it.
- A background `Transaction.updates` listener refreshes entitlements.
- `hasAccess(to:)` answers only `.basicStudio` (always true). `maxProjects` and
  `maxAIQueries` throw `limitsUnavailable`. No feature-to-tier policy is
  invented; that is owner configuration.

### Removed from the client

- Client-side writes of `subscription_tier`, `subscription_status`,
  `apple_transaction_id` and `apple_product_id` to the Supabase `users` table.
  A client must not assert its own entitlement.
- `chargeForCall(...)` — call billing is retired scope
  (`docs/PRODUCT_SCOPE_2026_09_19.md` line 12).
- `sendTip(...)` — tips are not in the current contract. "No new paid service
  is authorized."

### Entitlement reconciliation (server read, 2026-10-18)

`StripeService.reconcileEntitlementsWithServer()` reads the signed-in member's
plan with the `sdi_my_entitlement` RPC (`ServerEntitlementClient`) and compares
it with Apple's entitlement. A match is reported as verified; no server record
yet, or a different tier, is reported as deferred with both tiers named; not
configured, signed out and offline each have their own notice. The client never
writes a tier. A paid plan the server applied (for example a website
subscription) counts toward Studio limits for that account. Granting the
entitlement itself stays on the server: verify Apple's signed transaction
(App Store Server API / Server Notifications keyed by `appAccountToken`) and
write it there.

## Views

`SubscriptionView` opens from Profile (Subscription row and card), the legacy
Settings "Current Plan" row, Spatter and Studio. `ChoosePlanView(onSelected:)`
is still not opened from any screen.

- `StickDeathInfinity/Views/Settings/SubscriptionView.swift`
  - Shows the actual entitlement from Apple (`Active`, purchase date, period end
    when Apple supplies it, transaction id), `Purchase pending`, or
    `No active subscription`. No invented renewal date or status.
  - Lists loaded StoreKit products with `displayPrice`; otherwise
    "Plans are not configured yet" or the App Store error.
  - Purchase goes through `StripeService.purchase(_:)`. The simulated
    two-second "Subscribed!" success was deleted.
- `StickDeathInfinity/Views/Onboarding/ChoosePlanView.swift`
  - Three monthly plan cards (Creator, Pro, Unlimited). Price comes from the
    loaded product, otherwise "Price shown when configured". The CTA is
    disabled while no product exists. Trial copy only from an eligible App
    Store free-trial offer.
  - Feature pills come from `BillingPlanCatalog` (owner-stated entitlements of
    2026-10-07); everything the server does not enforce yet is marked `*` with the
    pending note. No
    "Commercial license", project counts, coins or sale claims. (Updated #259,
    2026-10-14; earlier this list was "Extras pending owner configuration".)
  - A failed purchase shows the error and stays on the screen; it no longer
    advances as if it succeeded. "Start Free →" continues without a purchase.

## Server side (candidates, tested offline 2026-10-13)

The three edge-function handlers are pure Python modules in `backend/billing/`
(`stripe_checkout.py`, `stripe_webhook.py`, `appstore_notifications.py`, shared
`contract.py`). Each maps a verified provider payload onto exactly one call of
`public.sdi_billing_apply_event(...)` through an injected executor; the parameter names
are cross-checked against the SQL signature by `backend/tests/test_billing.py`
(40 tests, recording executor, fake chain verifier, HMAC-signed Stripe fixtures).

- Signature before body: Stripe `v1` HMAC with timestamp tolerance; App Store JWS
  structure, `x5c` chain to a pinned root and ES256 through an injected verifier
  (fails closed with 503 when none is configured).
- Idempotency: the provider event id is the unique key; replays answer `duplicate`
  with 200 so providers stop retrying; older events never move a subscription back.
- Lifecycle mapping (#258): `active`/`trialing`, `grace` (Apple billing grace with
  `gracePeriodExpiresDate`), `past_due`, `cancel_at_period_end` (auto-renew off, access
  kept until `paid_through`), `cancelled`, `expired`, `refunded`, `revoked`; downgrades
  change the product on the same provider subscription. `backend/sql/tests/070_billing_lifecycle_finance.sql`
  drives every transition through `sdi_billing_apply_event` and checks `sdi_my_entitlement`
  after each; `sdi_billing_reconcile()` expires rows only after 16 days past `paid_through`.
- Money: ledger rows carry provider-reported minor units only (Stripe `amount_paid`,
  refunds, payouts in live mode; Apple refund amounts from milliunits with the currency's
  exponent). Test-mode and sandbox events never create ledger rows. Card and contact
  fields are redacted before the payload is stored.
- Checkout (#252): the member's JWT is verified by an injected callback, the account must
  be active, the product must be an approved **monthly** Stripe price id, the return URL
  must be on the website origin, and the response is the Stripe request to perform
  server-side plus (after Stripe answers) only the hosted URL. A success redirect proves
  nothing; entitlement follows the webhook.
- Finance (#254/#255): `backend/sql/billing-finance.sql` adds `sdi_finance_record`
  (expense, import, correct, reconcile; finance capability + step-up, audited, duplicate
  detection) and `sdi_finance_report` (reconciliation with named discrepancies, period
  summary separating cash movements from recognized records and expenses, CSV-ready
  export without member identity, agent cost vs caps). Every label says these are
  records, not an available balance.

Not deployed, not run against a provider. Activation needs the owner gates below plus the
edge-function runtime (verifier, secret store, executor binding) and sandbox exercises.

## Provider statement reconciliation (#254, 2026-10-14)

`backend/billing/reconciliation.py` compares a Stripe *Balance change from activity —
itemized* CSV with `sdi_finance_report('export')` rows for the same period, by
provider id (invoice id for charges, `re_` refunds, `po_` payouts). The report lists
`missing_in_ledger`, `missing_in_statement`, `amount_mismatch`, `currency_mismatch`,
`duplicate_statement_line`, `outside_period`, `unclassified_category`,
`statement_row_rejected` and `tax_not_in_ledger`, per-currency totals (gross
charges, refunds, provider fees, payouts, tax, adjustments) and fee import rows
(`stripe-fee:<balance transaction>`) for the audited `sdi_finance_record('import')`
path, since webhooks carry no Stripe fee. It reads only allowlisted columns, so
customer e-mail, name and description never reach the report. Test-mode statements
are labelled "not money", never compared with the live ledger and produce no import
rows. Tests: `backend/tests/test_billing_reconciliation.py` with synthetic fixtures.
Apple proceeds (App Store Connect financial reports) have no parser yet.

## Owner-gated (not done, not claimed)

1. Done by the owner (2026-10-20): three monthly auto-renewable subscriptions
   in App Store Connect at USD 4.99, USD 9.99 and USD 19.99, each with a 3-day
   free-trial introductory offer; Release builds carry their ids. Sandbox
   verification of purchase, trial and upgrade flows is deferred to the final
   integration phase.
2. Decide annual amounts and entitlements, if any. Nothing annual ships until
   then.
3. Entitlement rules: the 2026-10-20 contract above (Creator 250, Pro 500,
   Unlimited unlimited, 3-day trial with Spatter preview-only) supersedes
   `docs/PLAN_DECISIONS_2026_10_15.md`. Remaining: the backend must accept the
   `unlimited` tier, meter Pro at 500, report the optional trial flag and
   refuse server-funded prompts and credit spending during a trial; then
   deploy the Spatter metering and billing SQL and handlers. The native client
   already reads `sdi_my_entitlement` and `sdi_spatter_my_usage` with those
   fields.
4. Verify the existing Stripe account before any reuse. Stripe has no
   client-side role in the current contract; any server-side use (web
   payments) must be verified separately and must not be a new paid service.
5. Test purchases only with StoreKit Testing / sandbox accounts. No live charges
   as tests.
6. Mount the views in the settings and onboarding flows once 1–3 are done.

## Follow-ups required in files outside this batch

- `StickDeathInfinity/Services/LiveKit/LiveKitService.swift:289-298` still
  calls `StripeService.shared.chargeForCall(...)`, which no longer exists. The
  call block must be removed with the retired calls scope.
- `docs/BACKEND_ARCHITECTURE_PUBLIC.md` lines 22-23, 58, 198-217 and 263
  describe the old Studio/annual tiers, the `tips` table and the client-side
  `users` sync; they are now historical.
- `StickDeathInfinity/Info.plist` carries the three `SDI_STOREKIT_PLAN_*` keys
  (Release fills them; done 2026-10-20).

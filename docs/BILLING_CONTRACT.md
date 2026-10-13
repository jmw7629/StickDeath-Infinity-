# Billing Contract (native iOS)

Status: implementation batch, 2026-10-12. Verification deferred to the final
integration phase; nothing below is claimed as passed. Source of authority:
`AGENTS.md` (owner scope 2026-09-19 and later) and
`docs/PRODUCT_SCOPE_2026_09_19.md` line 61.

## Approved plan contract

| Plan | Cadence | Requested price | StoreKit product id (placeholder) | Tier mapping |
| --- | --- | --- | --- | --- |
| Creator | Monthly, auto-renewable | USD 4.99 | `com.stickdeath.infinity.creator.monthly` | `AppConfig.SubscriptionTier.creator` |
| Pro | Monthly, auto-renewable | USD 9.99 | `com.stickdeath.infinity.pro.monthly` | `AppConfig.SubscriptionTier.pro` |

- Exactly two paid plans exist. The former USD 19.99 "Studio" tier and all
  annual identifiers were removed from the client catalogue; they were never
  approved by the owner.
- The price the user is charged is the price Apple shows at checkout. The app
  never hard-codes a price string; it displays `Product.displayPrice` from the
  loaded StoreKit product or an honest "not configured" state.
- Annual plans: **not configured.** No annual product id, price or entitlement
  exists. Adding one requires the owner's explicit annual amount, entitlement
  decision and matching App Store Connect products
  (`StoreProductID` TODO in `StickDeathInfinity/Services/Stripe/StripeService.swift`).
- `AppConfig.SubscriptionTier.studio` still exists as an enum case in
  `StickDeathInfinity/App/AppConfig.swift` (not owned by this batch). It maps to
  no product and grants nothing.

## Product identifier configuration

`StoreProductID` reads the identifiers from `Bundle.main.infoDictionary` using
the existing `$(VAR)` xcconfig pattern and falls back to the placeholders above:

| Info.plist key | Plan |
| --- | --- |
| `SDI_STOREKIT_PLAN_4_99_PRODUCT_ID` | USD 4.99 monthly |
| `SDI_STOREKIT_PLAN_9_99_PRODUCT_ID` | USD 9.99 monthly |

The keys are not yet present in `StickDeathInfinity/Info.plist` or the xcconfig
(those files are outside this batch). Until they are added, the placeholders are
used and `StoreProductID.usesPlaceholderIdentifiers` is `true`.

## Implemented client-side (StoreKit 2)

File: `StickDeathInfinity/Services/Stripe/StripeService.swift`
(the historical type name is kept because the Xcode project references the
file; the client calls no Stripe API).

- `loadProducts()` fetches the two approved ids; an empty result sets
  `productLoadState = .notConfigured`, an error sets `.failed(message)`.
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

### Entitlement reconciliation (owner-gated stub)

`StripeService.reconcileEntitlementsWithServer()` throws
`PaymentError.entitlementReconciliationNotConfigured`. After a successful
purchase or restore the service attempts it and publishes the error text in
`reconciliationNotice`, which the Subscription view shows. The real
implementation belongs on the server: verify Apple's signed transaction
(App Store Server API / Server Notifications keyed by `appAccountToken`) and
write the entitlement there.

## Views

Both views are compiled by the Xcode target but are **not mounted** anywhere in
the app flow (no call site constructs `SubscriptionView()` or
`ChoosePlanView(onSelected:)`).

- `StickDeathInfinity/Views/Settings/SubscriptionView.swift`
  - Shows the actual entitlement from Apple (`Active`, purchase date, period end
    when Apple supplies it, transaction id), `Purchase pending`, or
    `No active subscription`. No invented renewal date or status.
  - Lists loaded StoreKit products with `displayPrice`; otherwise
    "Plans are not configured yet" or the App Store error.
  - Purchase goes through `StripeService.purchase(_:)`. The simulated
    two-second "Subscribed!" success was deleted.
- `StickDeathInfinity/Views/Onboarding/ChoosePlanView.swift`
  - Two monthly plan cards. Price comes from the loaded product, otherwise
    "Price shown when configured". The CTA is disabled while no product exists.
  - Feature pills name only what the Studio does today (frame-by-frame Studio,
    layers and audio timeline, MP4/GIF/PNG export, on-device projects, Spatter
    assistant) plus "Extras pending owner configuration". No "Unlimited AI",
    "Commercial license", project counts or AI quotas.
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

## Owner-gated (not done, not claimed)

1. Create the two monthly auto-renewable subscriptions in App Store Connect at
   USD 4.99 and USD 9.99 (or confirm the placeholder ids / set the Info.plist
   keys above). Localized prices and introductory offers are App Store Connect
   configuration.
2. Decide annual amounts and entitlements, if any. Nothing annual ships until
   then.
3. Publish the feature-to-tier entitlement policy and quotas; then bind the native
   client to `sdi_my_entitlement` and replace the throwing stub.
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
- `StickDeathInfinity/Info.plist` and the xcconfig need the two
  `SDI_STOREKIT_*` keys when the owner confirms the identifiers.

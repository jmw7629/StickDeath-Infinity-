# Billing edge-function candidates (pure handlers, tested offline, not deployed)

Nothing in this directory is deployed. `contract.py`, `stripe_checkout.py`,
`stripe_webhook.py` and `appstore_notifications.py` implement the three handlers as
pure functions over injected dependencies (JWT verifier, account check, chain verifier,
webhook secret, SQL executor); the deployment wraps them in its edge-function runtime.
`backend/tests/test_billing.py` exercises them with fakes. The database side is
`backend/sql/billing.sql` plus `billing-finance.sql`, also unapplied candidates.

## Approved offers

- Three monthly tiers (owner decision 2026-10-20), ranked `unlimited` > `pro` >
  `creator` (`sdi_private.billing_tier_rank`): USD 4.99 `creator`
  (`com.willisbmb.StickDeathInfinity.creator.monthly`), USD 9.99 `pro`
  (`...pro.monthly`) and USD 19.99 `unlimited` (`...unlimited.monthly`), each with a
  3-day free trial (App Store introductory offer). Prices live only in App Store
  Connect and the Stripe dashboard; the database stores product identifiers
  (`sdi_private.billing_products`) and never an amount.
- Annual periods are **not** approved. A product row with `period='annual'` cannot be
  approved until the owner records `owner_configured_at` through the owner-only
  `set_product` operation; the check constraint enforces this.
- No Studio tier, coins, tips or call billing exist. The USD 19.99 `unlimited` tier
  is the owner's 2026-10-20 decision, not the retired "Studio" tier; its unlimited
  Spatter prompts still obey the daily safety cap, per-minute rate, global daily
  ceiling and emergency stop.
- Native digital entitlements are sold through StoreKit 2. Stripe is server-side only
  (web checkout/portal) and runs in test mode until the owner separately authorizes
  live activation. No live charge is ever made as a test.

## Shared rules for all three functions

- Run with the service role on the server. Clients never receive the service key and
  never write `subscriptions`, tier, status or `paid_through`.
- Verify the provider signature **before** reading the body. Reject unsigned,
  expired or replayed requests with 400 and do not call the database.
- Map the provider payload to one `sdi_billing_apply_event(...)` call:
  `provider`, `event_id` (provider's unique id), `event_type`, `occurred_at`,
  `payload` (the verified body, minus card data), and when the event concerns a
  subscription: `user_id`, `provider_subscription_id`, `product_id`, `status`,
  `paid_through`, `cancel_at_period_end`, plus `ledger` entries
  (`[{ref, kind, amount_minor, currency}]`) for charges, refunds, fees and payouts.
- A `{duplicate:true}` result means the event was already recorded; return 200 so the
  provider stops retrying. A `{outcome:'ignored'}` result (unapproved product, missing
  dates, out-of-order event) is also 200: nothing was granted and the record explains why.
- Resolve the account from server-side data only: Stripe `client_reference_id` /
  customer metadata set by `stripe-checkout`, or the App Store `appAccountToken`
  bound to the signed-in account at purchase time. Never trust a user id in the body.
- Log event ids and outcomes, never tokens, receipts or customer details.

## `stripe-checkout`

- Input: authenticated session (Supabase JWT, `sdi_private.account_active()` true),
  `product_id` of an approved Stripe product, `return_url` on the configured website
  origin only. Rejects anonymous users and unapproved or annual products.
- Creates a Checkout Session in subscription mode with `client_reference_id = user id`
  and `appAccountToken`-equivalent metadata, and a Customer Portal session for
  management. Returns only the hosted URL.
- A success redirect is **not** proof of payment; entitlement appears only after
  `stripe-webhook` applies the signed `checkout.session.completed` /
  `customer.subscription.*` / `invoice.*` events.

## `stripe-webhook`

- Verifies `Stripe-Signature` with the webhook secret from the server secret store.
- Handles `customer.subscription.created|updated|deleted`, `invoice.paid`,
  `invoice.payment_failed`, `charge.refunded`, `payout.paid`; maps Stripe status to
  the canonical set (`active, trialing, grace, past_due, cancelled, expired, revoked,
  refunded`) with `paid_through = current_period_end` and ledger rows from
  `balance_transaction` amounts and fees.
- Trials (owner decisions 2026-10-14 and 2026-10-20): every paid tier has the free
  trial. A `trialing` subscription maps to `trialing` with `in_trial=True`. A
  zero-amount `subscription_create` invoice (trial start, or a 100%-discount or
  credit-covered first period) is recorded without changing the subscription, so
  the signed subscription event alone decides trial or active. The entitlement view
  grants the tier (Studio unlocked), but the Spatter meter funds no prompt and
  spends no credit while the account's only entitlements are in a trial. Trial
  length is Stripe/App Store configuration; checkout requests carry no trial or
  amount fields.
- Replays and delayed deliveries are safe: `provider_events(provider,event_id)` is
  unique and older events never move a subscription backwards.

## `appstore-notifications`

- Verifies App Store Server Notifications V2 (signed JWS chain against Apple roots)
  and decodes `signedTransactionInfo` / `signedRenewalInfo`.
- Handles `SUBSCRIBED`, `DID_RENEW`, `DID_CHANGE_RENEWAL_STATUS`, `EXPIRED`,
  `GRACE_PERIOD_EXPIRED`, `DID_FAIL_TO_RENEW`, `REFUND`, `REVOKE`; uses
  `originalTransactionId` as `provider_subscription_id`, `productId` as
  `product_id`, `expiresDate` as `paid_through`, and `appAccountToken` for the
  account. Refunds and revocations write ledger rows from the notification.
- Sandbox and production environments are separate configurations; sandbox events
  are recorded with `payload.environment` and never counted as revenue.

## Spatter credit packs (owner decision 2026-10-15)

Consumable packs credit `sdi_private.spatter_credit_ledger` through the
service-only `public.sdi_spatter_credits_grant` / `_refund` (see
`backend/sql/spatter-draft-jobs.sql`); both are idempotent per
(provider, transaction). `contract.CreditPack` / `CreditPackCatalog` hold the
approved packs (no prices; Stripe packs bind a `price_...` id).

- `appstore_credits` (new edge-function candidate): the app posts the StoreKit 2
  signed transaction with the member's bearer token; the handler verifies the
  JWS with the same pinned-root verifier, requires the bundle, environment,
  `type: Consumable`, an approved pack, no revocation and `appAccountToken` equal
  to the member, then grants. Sandbox grants are flagged `livemode = false`.
- `appstore-notifications` with `credit_packs=`: `REFUND` for a pack claws back;
  `ONE_TIME_CHARGE` grants.
- `stripe-checkout` `action: "credits"`: one-time `mode=payment` session for an
  approved Stripe pack only, pack and member in session and PaymentIntent metadata.
- `stripe-webhook` with `credit_packs=`: paid `checkout.session.completed` /
  `async_payment_succeeded` grants by PaymentIntent (plus a live-mode `charge`
  ledger row); fully refunded `charge.refunded` claws back. Partial refunds do not.
- Google Play credit packs: no grant/refund verification path exists; unavailable.
  The read-only subscription inspection foundation below does not activate purchases.

Tests: `backend/tests/test_spatter_credits.py`.

## Reconciliation

- A scheduled service job calls `sdi_billing_reconcile()` after replaying missed
  events (Stripe event list since the last processed id; App Store
  `Get Transaction History`). Lapsed subscriptions expire 16 days after
  `paid_through` so Apple billing grace and Stripe retry windows are honoured.
- Finance administrators read `sdi_finance_admin('summary'|'ledger'|'events'|
  'subscriptions')`. Sums are provider-reported entries in minor units; they are not
  an available balance and are labelled so.

## Statement reconciliation (#254)

`reconciliation.py` matches a Stripe itemized balance-change CSV against the
`sdi_finance_report('export')` rows by provider id and names each discrepancy
(missing on either side, amount or currency mismatch, duplicate, outside the period,
unknown category, rejected row, tax lines). It produces fee rows for the audited
import path because webhooks carry no Stripe fee, reads only allowlisted columns
(no customer data), and treats test-mode statements as "not money" with no
comparison or import. It writes nothing. Tests:
`backend/tests/test_billing_reconciliation.py`.

## Verification status

Implemented as candidates and tested offline on 2026-10-13: `python3 -m unittest
discover -s backend/tests -t .` (40 billing tests among 102) and
`scripts/backend/run_sql_tests.sh` (`050_billing_agents.sql`,
`070_billing_lifecycle_finance.sql`). Not run against any provider or the live
project. Required before activation: provider accounts confirmed by the owner, products
created in App Store Connect and Stripe (test mode), secrets in the server secret store,
the runtime bindings (ES256 chain verifier, JWT verification, service-role executor),
StoreKit sandbox and Stripe test-mode exercises (purchase, pending, cancel, restore,
renewal, revocation, refund, replay). None of that has run.


## Google Play subscription inspection foundation (#289)

`google_play.py` and `google_play_transport.py` add an **undeployed, default-off,
read-only** subscription inspector. They do not grant an entitlement, acknowledge a
purchase, consume a pack, write SQL or enable the Android purchase buttons. Existing
`contract.PROVIDERS` and database provider constraints remain Apple/Stripe only.
A successful inspection response explicitly says `verificationOnly: true`,
`entitlementApplied: false`, `acknowledgementPerformed: false` and
`reconciliationAvailable: false`; it is never an Android `Granted` response.

The deployment must inject a signature/issuer-validating member JWT verifier,
active-account lookup, durable query limiter, approved product/base-plan pairs,
read-only `SecretStore`, and bounded transport. No secret path or reference is
assumed. `PlayVerificationConfig.enabled` defaults to false; missing runtime
bindings prevent secret reads and Google requests. The dedicated service-account
signer validates the key type, credential/token endpoint and response bounds;
requests only `androidpublisher` OAuth scope, not the FCM scope. Keys, bearer
tokens, purchase tokens, provider contact fields and raw responses are never
returned in an inspection receipt. HTTP redirects and arbitrary destinations
are refused; calls have finite timeout/byte bounds and no automatic retry.

Account ownership requires Google's `obfuscatedExternalAccountId` to match the
server's package-separated HMAC of the authenticated member UUID. The binding
key must be 32–64 server-held random bytes; the future authenticated launch
binding endpoint must supply this exact 64-character value to Android's
`setObfuscatedAccountId`. Caller user IDs, emails and provider profile names are
not substitutes. Binding-key rotation needs a versioned migration. Existing
purchases without a binding cannot be silently assigned to a claimant.

Only one configured auto-renewing item is inspected. Pending, paused, held or
expired subscriptions have no current snapshot access. Cancellation retains
snapshot access only through verified expiry; grace follows Google's expiry.
Current `offerPhase.freeTrial` remains a trial; an explicit paid phase clears
it. Missing/prorated phases are unknown and cannot fund paid access. Linked or
deferred replacements require atomic reconciliation first. Test purchases need
a separate explicit switch. An expired resource can represent revocation; no
refund amount/reason is invented from it. The observation fingerprint is for
equality only: **do not use it as a durable event ID** (A→B→A can repeat).

Still required before any purchase/grant activation:

- Reviewed Google provider schema/catalogue upgrade plus canonical durable token
  ownership, encrypted retryable token storage, per-token locks, ordered state
  updates and existing billing ledger integration. Never reuse the current
  16-day Apple/Stripe expiry grace blindly for Google hold/expiry/revocation.
- Authenticated RTDN/Pub/Sub delivery IDs and replay storage, latest Publisher
  requery, atomic linked-token deprovisioning, voided/order/refund handling and
  bounded scheduled catch-up. No fabricated charge/refund rows from list prices.
- Idempotent post-durable-grant acknowledgement/outbox and refund/rejection
  handling; ack never precedes a successful entitlement commit. Consumables,
  prepaid/installment plans and multi-item subscriptions remain unavailable.
- Real runtime SecretStore/JWT/account/limiter/service-role adapters, approved
  Play Console products/access, client binding and verifier integration, then
  sandbox/internal-track purchase/restore/renewal/cancel/refund/device evidence.

Offline assertions: `python3 -m unittest backend.tests.test_google_play -v`.
Fixtures generate a temporary test RSA key in memory and verify the actual
RS256 assertion; injected transports open no socket. This does not prove a
Google account is configured or that a real purchase works.

Primary sources checked November 3, 2026:
[purchases.subscriptionsv2](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2),
[Publisher get/scope](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2/get),
[subscription lifecycle](https://developer.android.com/google/play/billing/lifecycle/subscriptions),
[verification/account binding](https://developer.android.com/google/play/billing/security),
[acknowledgement](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptions/acknowledge),
[service-account OAuth](https://developers.google.com/identity/protocols/oauth2/service-account).

# Billing edge-function candidates (pure handlers, tested offline, not deployed)

Nothing in this directory is deployed. `contract.py`, `stripe_checkout.py`,
`stripe_webhook.py` and `appstore_notifications.py` implement the three handlers as
pure functions over injected dependencies (JWT verifier, account check, chain verifier,
webhook secret, SQL executor); the deployment wraps them in its edge-function runtime.
`backend/tests/test_billing.py` exercises them with fakes. The database side is
`backend/sql/billing.sql` plus `billing-finance.sql`, also unapplied candidates.

## Approved offers

- Two monthly tiers, the owner's stated price points USD 4.99 (`creator`) and USD 9.99
  (`pro`). Prices live only in App Store Connect and the Stripe dashboard; the database
  stores product identifiers (`sdi_private.billing_products`) and never an amount.
- Annual periods are **not** approved. A product row with `period='annual'` cannot be
  approved until the owner records `owner_configured_at` through the owner-only
  `set_product` operation; the check constraint enforces this.
- No Studio tier, coins, tips, call billing or "unlimited AI" offers exist. Earlier
  client code and documentation that described a USD 19.99 tier, annual prices or
  call charges are retired scope and must not be reused.
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
- Trials (owner decision 2026-10-14): the free trial applies to both paid plans.
  A `trialing` subscription on either the Creator or the Pro price maps to
  `trialing` for that tier (`contract.TRIAL_TIERS`), and the entitlement view and
  the Spatter meter treat it as that tier. Trial length is Stripe/App Store
  configuration; checkout requests carry no trial or amount fields.
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
- Google Play: no verification path exists; not implemented.

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

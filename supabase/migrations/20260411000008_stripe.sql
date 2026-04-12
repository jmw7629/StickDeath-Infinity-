-- =============================================================================
-- Migration: Stripe Schema (Managed by Supabase Stripe Extension)
-- StickDeath Infinity — Supabase Migration 008
-- All 29 Stripe tables in the "stripe" schema
--
-- NOTE: These tables use GENERATED ALWAYS AS ... STORED columns that extract
-- fields from _raw_data JSONB. This is the pattern used by the Supabase
-- Stripe Sync extension. If using the extension, it will manage these tables
-- automatically — in that case, skip this migration.
-- =============================================================================

-- Create stripe schema
CREATE SCHEMA IF NOT EXISTS stripe;

-- ─────────────────────────────────────────────
-- Custom ENUM types for Stripe
-- ─────────────────────────────────────────────
DO $$ BEGIN
    CREATE TYPE stripe.pricing_type AS ENUM('one_time', 'recurring');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE stripe.pricing_tiers AS ENUM('graduated', 'volume');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE stripe.subscription_status AS ENUM(
        'trialing', 'active', 'canceled', 'incomplete',
        'incomplete_expired', 'past_due', 'unpaid', 'paused'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE stripe.invoice_status AS ENUM(
        'draft', 'open', 'paid', 'uncollectible', 'void', 'deleted'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE stripe.subscription_schedule_status AS ENUM(
        'not_started', 'active', 'completed', 'released', 'canceled'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────
-- stripe.accounts
-- Connected Stripe accounts
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.accounts (
    _raw_data         jsonb NOT NULL,
    first_synced_at   timestamptz DEFAULT now() NOT NULL,
    _last_synced_at   timestamptz DEFAULT now() NOT NULL,
    _updated_at       timestamptz DEFAULT now() NOT NULL,
    business_name     text GENERATED ALWAYS AS ((_raw_data -> 'business_profile' ->> 'name')) STORED,
    email             text GENERATED ALWAYS AS ((_raw_data ->> 'email')) STORED,
    type              text GENERATED ALWAYS AS ((_raw_data ->> 'type')) STORED,
    charges_enabled   boolean GENERATED ALWAYS AS (((_raw_data ->> 'charges_enabled')::boolean)) STORED,
    payouts_enabled   boolean GENERATED ALWAYS AS (((_raw_data ->> 'payouts_enabled')::boolean)) STORED,
    details_submitted boolean GENERATED ALWAYS AS (((_raw_data ->> 'details_submitted')::boolean)) STORED,
    country           text GENERATED ALWAYS AS ((_raw_data ->> 'country')) STORED,
    default_currency  text GENERATED ALWAYS AS ((_raw_data ->> 'default_currency')) STORED,
    created           integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    api_key_hashes    text[] DEFAULT '{}',
    id                text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS idx_accounts_api_key_hashes ON stripe.accounts USING gin (api_key_hashes);
CREATE INDEX IF NOT EXISTS idx_accounts_business_name ON stripe.accounts (business_name);

-- ─────────────────────────────────────────────
-- stripe._managed_webhooks
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe._managed_webhooks (
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED,
    _raw_data       jsonb,
    object          text,
    url             text NOT NULL UNIQUE,
    enabled_events  jsonb NOT NULL,
    description     text,
    enabled         boolean,
    livemode        boolean,
    metadata        jsonb,
    secret          text NOT NULL,
    status          text,
    api_version     text,
    created         integer,
    updated_at      timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    last_synced_at  timestamptz,
    account_id      text NOT NULL UNIQUE REFERENCES stripe.accounts(id),
    CONSTRAINT managed_webhooks_url_account_unique UNIQUE(url, account_id)
);

CREATE INDEX IF NOT EXISTS stripe_managed_webhooks_enabled_idx ON stripe._managed_webhooks (enabled);
CREATE INDEX IF NOT EXISTS stripe_managed_webhooks_status_idx ON stripe._managed_webhooks (status);

-- ─────────────────────────────────────────────
-- stripe._migrations
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe._migrations (
    id          integer PRIMARY KEY,
    name        varchar(100) NOT NULL UNIQUE,
    hash        varchar(40) NOT NULL,
    executed_at timestamptz DEFAULT CURRENT_TIMESTAMP
);

-- ─────────────────────────────────────────────
-- stripe._sync_status
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe._sync_status (
    id                       serial PRIMARY KEY,
    resource                 text NOT NULL UNIQUE,
    status                   text DEFAULT 'idle' CHECK (status IN ('idle', 'running', 'complete', 'error')),
    last_synced_at           timestamptz DEFAULT now(),
    last_incremental_cursor  timestamptz,
    error_message            text,
    updated_at               timestamptz DEFAULT now(),
    account_id               text NOT NULL UNIQUE REFERENCES stripe.accounts(id),
    CONSTRAINT _sync_status_resource_account_key UNIQUE(resource, account_id)
);

CREATE INDEX IF NOT EXISTS idx_sync_status_resource_account ON stripe._sync_status (resource, account_id);

-- ─────────────────────────────────────────────
-- stripe.active_entitlements
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.active_entitlements (
    _updated_at    timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data      jsonb,
    _account_id    text NOT NULL REFERENCES stripe.accounts(id),
    object         text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    livemode       boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    feature        text GENERATED ALWAYS AS ((_raw_data ->> 'feature')) STORED,
    customer       text GENERATED ALWAYS AS ((_raw_data ->> 'customer')) STORED,
    lookup_key     text GENERATED ALWAYS AS ((_raw_data ->> 'lookup_key')) STORED UNIQUE,
    id             text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_active_entitlements_customer_idx ON stripe.active_entitlements (customer);
CREATE INDEX IF NOT EXISTS stripe_active_entitlements_feature_idx ON stripe.active_entitlements (feature);

-- ─────────────────────────────────────────────
-- stripe.charges
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.charges (
    _updated_at    timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data      jsonb,
    _account_id    text NOT NULL REFERENCES stripe.accounts(id),
    object         text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    paid           boolean GENERATED ALWAYS AS (((_raw_data ->> 'paid')::boolean)) STORED,
    amount         bigint GENERATED ALWAYS AS (((_raw_data ->> 'amount')::bigint)) STORED,
    status         text GENERATED ALWAYS AS ((_raw_data ->> 'status')) STORED,
    created        integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    currency       text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    customer       text GENERATED ALWAYS AS ((_raw_data ->> 'customer')) STORED,
    invoice        text GENERATED ALWAYS AS ((_raw_data ->> 'invoice')) STORED,
    captured       boolean GENERATED ALWAYS AS (((_raw_data ->> 'captured')::boolean)) STORED,
    refunded       boolean GENERATED ALWAYS AS (((_raw_data ->> 'refunded')::boolean)) STORED,
    description    text GENERATED ALWAYS AS ((_raw_data ->> 'description')) STORED,
    payment_intent text GENERATED ALWAYS AS ((_raw_data ->> 'payment_intent')) STORED,
    amount_refunded bigint GENERATED ALWAYS AS (((_raw_data ->> 'amount_refunded')::bigint)) STORED,
    failure_code   text GENERATED ALWAYS AS ((_raw_data ->> 'failure_code')) STORED,
    failure_message text GENERATED ALWAYS AS ((_raw_data ->> 'failure_message')) STORED,
    metadata       jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    livemode       boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    id             text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.checkout_sessions
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.checkout_sessions (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    amount_subtotal integer GENERATED ALWAYS AS (((_raw_data ->> 'amount_subtotal')::integer)) STORED,
    amount_total    integer GENERATED ALWAYS AS (((_raw_data ->> 'amount_total')::integer)) STORED,
    currency        text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    customer        text GENERATED ALWAYS AS ((_raw_data ->> 'customer')) STORED,
    customer_email  text GENERATED ALWAYS AS ((_raw_data ->> 'customer_email')) STORED,
    mode            text GENERATED ALWAYS AS ((_raw_data ->> 'mode')) STORED,
    payment_intent  text GENERATED ALWAYS AS ((_raw_data ->> 'payment_intent')) STORED,
    payment_status  text GENERATED ALWAYS AS ((_raw_data ->> 'payment_status')) STORED,
    status          text GENERATED ALWAYS AS ((_raw_data ->> 'status')) STORED,
    subscription    text GENERATED ALWAYS AS ((_raw_data ->> 'subscription')) STORED,
    invoice         text GENERATED ALWAYS AS ((_raw_data ->> 'invoice')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_checkout_sessions_customer_idx ON stripe.checkout_sessions (customer);
CREATE INDEX IF NOT EXISTS stripe_checkout_sessions_subscription_idx ON stripe.checkout_sessions (subscription);
CREATE INDEX IF NOT EXISTS stripe_checkout_sessions_payment_intent_idx ON stripe.checkout_sessions (payment_intent);
CREATE INDEX IF NOT EXISTS stripe_checkout_sessions_invoice_idx ON stripe.checkout_sessions (invoice);

-- ─────────────────────────────────────────────
-- stripe.checkout_session_line_items
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.checkout_session_line_items (
    _updated_at      timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at  timestamptz,
    _raw_data        jsonb,
    _account_id      text NOT NULL REFERENCES stripe.accounts(id),
    object           text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    amount_subtotal  integer GENERATED ALWAYS AS (((_raw_data ->> 'amount_subtotal')::integer)) STORED,
    amount_total     integer GENERATED ALWAYS AS (((_raw_data ->> 'amount_total')::integer)) STORED,
    currency         text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    description      text GENERATED ALWAYS AS ((_raw_data ->> 'description')) STORED,
    price            text GENERATED ALWAYS AS ((_raw_data ->> 'price')) STORED,
    quantity         integer GENERATED ALWAYS AS (((_raw_data ->> 'quantity')::integer)) STORED,
    checkout_session text GENERATED ALWAYS AS ((_raw_data ->> 'checkout_session')) STORED,
    id               text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_csli_price_idx ON stripe.checkout_session_line_items (price);
CREATE INDEX IF NOT EXISTS stripe_csli_session_idx ON stripe.checkout_session_line_items (checkout_session);

-- ─────────────────────────────────────────────
-- stripe.coupons
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.coupons (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    name            text GENERATED ALWAYS AS ((_raw_data ->> 'name')) STORED,
    valid           boolean GENERATED ALWAYS AS (((_raw_data ->> 'valid')::boolean)) STORED,
    duration        text GENERATED ALWAYS AS ((_raw_data ->> 'duration')) STORED,
    amount_off      bigint GENERATED ALWAYS AS (((_raw_data ->> 'amount_off')::bigint)) STORED,
    percent_off     double precision GENERATED ALWAYS AS (((_raw_data ->> 'percent_off')::double precision)) STORED,
    currency        text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.credit_notes
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.credit_notes (
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    amount          integer GENERATED ALWAYS AS (((_raw_data ->> 'amount')::integer)) STORED,
    currency        text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    customer        text GENERATED ALWAYS AS ((_raw_data ->> 'customer')) STORED,
    invoice         text GENERATED ALWAYS AS ((_raw_data ->> 'invoice')) STORED,
    status          text GENERATED ALWAYS AS ((_raw_data ->> 'status')) STORED,
    total           integer GENERATED ALWAYS AS (((_raw_data ->> 'total')::integer)) STORED,
    reason          text GENERATED ALWAYS AS ((_raw_data ->> 'reason')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_credit_notes_customer_idx ON stripe.credit_notes (customer);
CREATE INDEX IF NOT EXISTS stripe_credit_notes_invoice_idx ON stripe.credit_notes (invoice);

-- ─────────────────────────────────────────────
-- stripe.customers
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.customers (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    email           text GENERATED ALWAYS AS ((_raw_data ->> 'email')) STORED,
    name            text GENERATED ALWAYS AS ((_raw_data ->> 'name')) STORED,
    phone           text GENERATED ALWAYS AS ((_raw_data ->> 'phone')) STORED,
    description     text GENERATED ALWAYS AS ((_raw_data ->> 'description')) STORED,
    balance         integer GENERATED ALWAYS AS (((_raw_data ->> 'balance')::integer)) STORED,
    currency        text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    delinquent      boolean GENERATED ALWAYS AS (((_raw_data ->> 'delinquent')::boolean)) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    deleted         boolean GENERATED ALWAYS AS (((_raw_data ->> 'deleted')::boolean)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.disputes
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.disputes (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    amount          bigint GENERATED ALWAYS AS (((_raw_data ->> 'amount')::bigint)) STORED,
    charge          text GENERATED ALWAYS AS ((_raw_data ->> 'charge')) STORED,
    reason          text GENERATED ALWAYS AS ((_raw_data ->> 'reason')) STORED,
    status          text GENERATED ALWAYS AS ((_raw_data ->> 'status')) STORED,
    currency        text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    payment_intent  text GENERATED ALWAYS AS ((_raw_data ->> 'payment_intent')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_dispute_created_idx ON stripe.disputes (created);

-- ─────────────────────────────────────────────
-- stripe.early_fraud_warnings
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.early_fraud_warnings (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    actionable      boolean GENERATED ALWAYS AS (((_raw_data ->> 'actionable')::boolean)) STORED,
    charge          text GENERATED ALWAYS AS ((_raw_data ->> 'charge')) STORED,
    fraud_type      text GENERATED ALWAYS AS ((_raw_data ->> 'fraud_type')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    payment_intent  text GENERATED ALWAYS AS ((_raw_data ->> 'payment_intent')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_efw_charge_idx ON stripe.early_fraud_warnings (charge);
CREATE INDEX IF NOT EXISTS stripe_efw_payment_intent_idx ON stripe.early_fraud_warnings (payment_intent);

-- ─────────────────────────────────────────────
-- stripe.events
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.events (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    data            jsonb GENERATED ALWAYS AS ((_raw_data -> 'data')) STORED,
    type            text GENERATED ALWAYS AS ((_raw_data ->> 'type')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.features
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.features (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    name            text GENERATED ALWAYS AS ((_raw_data ->> 'name')) STORED,
    lookup_key      text GENERATED ALWAYS AS ((_raw_data ->> 'lookup_key')) STORED UNIQUE,
    active          boolean GENERATED ALWAYS AS (((_raw_data ->> 'active')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.invoices
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.invoices (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    status          text GENERATED ALWAYS AS ((_raw_data ->> 'status')) STORED,
    total           bigint GENERATED ALWAYS AS (((_raw_data ->> 'total')::bigint)) STORED,
    amount_due      bigint GENERATED ALWAYS AS (((_raw_data ->> 'amount_due')::bigint)) STORED,
    amount_paid     bigint GENERATED ALWAYS AS (((_raw_data ->> 'amount_paid')::bigint)) STORED,
    amount_remaining bigint GENERATED ALWAYS AS (((_raw_data ->> 'amount_remaining')::bigint)) STORED,
    currency        text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    customer        text GENERATED ALWAYS AS ((_raw_data ->> 'customer')) STORED,
    subscription    text GENERATED ALWAYS AS ((_raw_data ->> 'subscription')) STORED,
    payment_intent  text GENERATED ALWAYS AS ((_raw_data ->> 'payment_intent')) STORED,
    hosted_invoice_url text GENERATED ALWAYS AS ((_raw_data ->> 'hosted_invoice_url')) STORED,
    paid            boolean GENERATED ALWAYS AS (((_raw_data ->> 'paid')::boolean)) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_invoices_customer_idx ON stripe.invoices (customer);
CREATE INDEX IF NOT EXISTS stripe_invoices_subscription_idx ON stripe.invoices (subscription);

-- ─────────────────────────────────────────────
-- stripe.payment_intents
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.payment_intents (
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    amount          integer GENERATED ALWAYS AS (((_raw_data ->> 'amount')::integer)) STORED,
    amount_received integer GENERATED ALWAYS AS (((_raw_data ->> 'amount_received')::integer)) STORED,
    currency        text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    customer        text GENERATED ALWAYS AS ((_raw_data ->> 'customer')) STORED,
    description     text GENERATED ALWAYS AS ((_raw_data ->> 'description')) STORED,
    invoice         text GENERATED ALWAYS AS ((_raw_data ->> 'invoice')) STORED,
    status          text GENERATED ALWAYS AS ((_raw_data ->> 'status')) STORED,
    payment_method  text GENERATED ALWAYS AS ((_raw_data ->> 'payment_method')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_payment_intents_customer_idx ON stripe.payment_intents (customer);
CREATE INDEX IF NOT EXISTS stripe_payment_intents_invoice_idx ON stripe.payment_intents (invoice);

-- ─────────────────────────────────────────────
-- stripe.payment_methods
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.payment_methods (
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    type            text GENERATED ALWAYS AS ((_raw_data ->> 'type')) STORED,
    customer        text GENERATED ALWAYS AS ((_raw_data ->> 'customer')) STORED,
    billing_details jsonb GENERATED ALWAYS AS ((_raw_data -> 'billing_details')) STORED,
    card            jsonb GENERATED ALWAYS AS ((_raw_data -> 'card')) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_payment_methods_customer_idx ON stripe.payment_methods (customer);

-- ─────────────────────────────────────────────
-- stripe.payouts
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.payouts (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    amount          bigint GENERATED ALWAYS AS (((_raw_data ->> 'amount')::bigint)) STORED,
    status          text GENERATED ALWAYS AS ((_raw_data ->> 'status')) STORED,
    currency        text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    type            text GENERATED ALWAYS AS ((_raw_data ->> 'type')) STORED,
    method          text GENERATED ALWAYS AS ((_raw_data ->> 'method')) STORED,
    description     text GENERATED ALWAYS AS ((_raw_data ->> 'description')) STORED,
    destination     text GENERATED ALWAYS AS ((_raw_data ->> 'destination')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.plans
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.plans (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    name            text GENERATED ALWAYS AS ((_raw_data ->> 'name')) STORED,
    active          boolean GENERATED ALWAYS AS (((_raw_data ->> 'active')::boolean)) STORED,
    amount          bigint GENERATED ALWAYS AS (((_raw_data ->> 'amount')::bigint)) STORED,
    currency        text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    "interval"      text GENERATED ALWAYS AS ((_raw_data ->> 'interval')) STORED,
    interval_count  bigint GENERATED ALWAYS AS (((_raw_data ->> 'interval_count')::bigint)) STORED,
    product         text GENERATED ALWAYS AS ((_raw_data ->> 'product')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.prices
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.prices (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    active          boolean GENERATED ALWAYS AS (((_raw_data ->> 'active')::boolean)) STORED,
    currency        text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    unit_amount     integer GENERATED ALWAYS AS (((_raw_data ->> 'unit_amount')::integer)) STORED,
    type            text GENERATED ALWAYS AS ((_raw_data ->> 'type')) STORED,
    recurring       jsonb GENERATED ALWAYS AS ((_raw_data -> 'recurring')) STORED,
    product         text GENERATED ALWAYS AS ((_raw_data ->> 'product')) STORED,
    nickname        text GENERATED ALWAYS AS ((_raw_data ->> 'nickname')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.products
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.products (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    active          boolean GENERATED ALWAYS AS (((_raw_data ->> 'active')::boolean)) STORED,
    name            text GENERATED ALWAYS AS ((_raw_data ->> 'name')) STORED,
    description     text GENERATED ALWAYS AS ((_raw_data ->> 'description')) STORED,
    default_price   text GENERATED ALWAYS AS ((_raw_data ->> 'default_price')) STORED,
    images          jsonb GENERATED ALWAYS AS ((_raw_data -> 'images')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.refunds
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.refunds (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    amount          integer GENERATED ALWAYS AS (((_raw_data ->> 'amount')::integer)) STORED,
    charge          text GENERATED ALWAYS AS ((_raw_data ->> 'charge')) STORED,
    currency        text GENERATED ALWAYS AS ((_raw_data ->> 'currency')) STORED,
    payment_intent  text GENERATED ALWAYS AS ((_raw_data ->> 'payment_intent')) STORED,
    reason          text GENERATED ALWAYS AS ((_raw_data ->> 'reason')) STORED,
    status          text GENERATED ALWAYS AS ((_raw_data ->> 'status')) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_refunds_charge_idx ON stripe.refunds (charge);
CREATE INDEX IF NOT EXISTS stripe_refunds_payment_intent_idx ON stripe.refunds (payment_intent);

-- ─────────────────────────────────────────────
-- stripe.reviews
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.reviews (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    charge          text GENERATED ALWAYS AS ((_raw_data ->> 'charge')) STORED,
    reason          text GENERATED ALWAYS AS ((_raw_data ->> 'reason')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    payment_intent  text GENERATED ALWAYS AS ((_raw_data ->> 'payment_intent')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_reviews_charge_idx ON stripe.reviews (charge);
CREATE INDEX IF NOT EXISTS stripe_reviews_payment_intent_idx ON stripe.reviews (payment_intent);

-- ─────────────────────────────────────────────
-- stripe.setup_intents
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.setup_intents (
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    status          text GENERATED ALWAYS AS ((_raw_data ->> 'status')) STORED,
    customer        text GENERATED ALWAYS AS ((_raw_data ->> 'customer')) STORED,
    payment_method  text GENERATED ALWAYS AS ((_raw_data ->> 'payment_method')) STORED,
    description     text GENERATED ALWAYS AS ((_raw_data ->> 'description')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_setup_intents_customer_idx ON stripe.setup_intents (customer);

-- ─────────────────────────────────────────────
-- stripe.subscription_items
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.subscription_items (
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    quantity        integer GENERATED ALWAYS AS (((_raw_data ->> 'quantity')::integer)) STORED,
    price           text GENERATED ALWAYS AS ((_raw_data ->> 'price')) STORED,
    subscription    text GENERATED ALWAYS AS ((_raw_data ->> 'subscription')) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.subscription_schedules
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.subscription_schedules (
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    status          text GENERATED ALWAYS AS ((_raw_data ->> 'status')) STORED,
    customer        text GENERATED ALWAYS AS ((_raw_data ->> 'customer')) STORED,
    subscription    text GENERATED ALWAYS AS ((_raw_data ->> 'subscription')) STORED,
    phases          jsonb GENERATED ALWAYS AS ((_raw_data -> 'phases')) STORED,
    end_behavior    text GENERATED ALWAYS AS ((_raw_data ->> 'end_behavior')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.subscriptions
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.subscriptions (
    _updated_at     timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    status          text GENERATED ALWAYS AS ((_raw_data ->> 'status')) STORED,
    customer        text GENERATED ALWAYS AS ((_raw_data ->> 'customer')) STORED,
    cancel_at_period_end boolean GENERATED ALWAYS AS (((_raw_data ->> 'cancel_at_period_end')::boolean)) STORED,
    current_period_end   integer GENERATED ALWAYS AS (((_raw_data ->> 'current_period_end')::integer)) STORED,
    current_period_start integer GENERATED ALWAYS AS (((_raw_data ->> 'current_period_start')::integer)) STORED,
    items           jsonb GENERATED ALWAYS AS ((_raw_data -> 'items')) STORED,
    default_payment_method text GENERATED ALWAYS AS ((_raw_data ->> 'default_payment_method')) STORED,
    latest_invoice  text GENERATED ALWAYS AS ((_raw_data ->> 'latest_invoice')) STORED,
    collection_method text GENERATED ALWAYS AS ((_raw_data ->> 'collection_method')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    metadata        jsonb GENERATED ALWAYS AS ((_raw_data -> 'metadata')) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

-- ─────────────────────────────────────────────
-- stripe.tax_ids
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stripe.tax_ids (
    _last_synced_at timestamptz,
    _raw_data       jsonb,
    _account_id     text NOT NULL REFERENCES stripe.accounts(id),
    object          text GENERATED ALWAYS AS ((_raw_data ->> 'object')) STORED,
    country         text GENERATED ALWAYS AS ((_raw_data ->> 'country')) STORED,
    customer        text GENERATED ALWAYS AS ((_raw_data ->> 'customer')) STORED,
    type            text GENERATED ALWAYS AS ((_raw_data ->> 'type')) STORED,
    value           text GENERATED ALWAYS AS ((_raw_data ->> 'value')) STORED,
    livemode        boolean GENERATED ALWAYS AS (((_raw_data ->> 'livemode')::boolean)) STORED,
    created         integer GENERATED ALWAYS AS (((_raw_data ->> 'created')::integer)) STORED,
    id              text PRIMARY KEY GENERATED ALWAYS AS ((_raw_data ->> 'id')) STORED
);

CREATE INDEX IF NOT EXISTS stripe_tax_ids_customer_idx ON stripe.tax_ids (customer);

-- ─────────────────────────────────────────────
-- Enable RLS on all Stripe tables
-- ─────────────────────────────────────────────
ALTER TABLE stripe.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe._managed_webhooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe._migrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe._sync_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.active_entitlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.charges ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.checkout_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.checkout_session_line_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.coupons ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.credit_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.early_fraud_warnings ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.features ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.payment_intents ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.setup_intents ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.subscription_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.subscription_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe.tax_ids ENABLE ROW LEVEL SECURITY;

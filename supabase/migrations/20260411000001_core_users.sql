-- =============================================================================
-- Migration: Core Users & Auth
-- StickDeath Infinity — Supabase Migration 001
-- Tables: users, profiles, user_stats, sessions, waitlist, policy_acceptance
-- =============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─────────────────────────────────────────────
-- users
-- Core user record, linked to Supabase auth.users
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.users (
    id              uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    username        varchar UNIQUE,
    email           varchar UNIQUE,
    avatar_url      varchar,
    bio             text,
    role            varchar DEFAULT 'user',
    banned          boolean DEFAULT false,
    created_at      timestamptz DEFAULT now(),
    onboarded       boolean DEFAULT false,
    shadowbanned    boolean DEFAULT false,
    accepted_policy_version varchar,
    stripe_customer_id      varchar,
    stripe_subscription_id  varchar,
    subscription_status     varchar DEFAULT 'inactive',
    subscription_tier       varchar DEFAULT 'free',
    creator_mode_enabled    boolean DEFAULT false
);

COMMENT ON TABLE public.users IS 'Core user profile synced with Supabase auth.users';
COMMENT ON COLUMN public.users.id IS 'References auth.users(id) — set on signup trigger';

-- ─────────────────────────────────────────────
-- profiles
-- Extended profile data (display info, social links)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.profiles (
    user_id         uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    handle          varchar(24) NOT NULL,
    display_name    varchar(50),
    bio             text,
    avatar_asset_id varchar,       -- FK added after assets table
    banner_asset_id varchar,       -- FK added after assets table
    website_url     varchar(255),
    location        varchar(100),
    created_at      timestamptz DEFAULT now(),
    updated_at      timestamptz DEFAULT now(),
    pinned_project_id integer,     -- FK added after studio_projects table
    profile_theme   varchar DEFAULT 'dark' NOT NULL,
    youtube_url     text,
    submit_to_channel_enabled boolean DEFAULT false NOT NULL
);

COMMENT ON TABLE public.profiles IS 'User profile display information';

-- ─────────────────────────────────────────────
-- user_stats
-- Denormalized counters for fast profile display
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_stats (
    user_id              uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    followers_count      integer DEFAULT 0 NOT NULL,
    following_count      integer DEFAULT 0 NOT NULL,
    posts_count          integer DEFAULT 0 NOT NULL,
    projects_count       integer DEFAULT 0 NOT NULL,
    likes_received_count integer DEFAULT 0 NOT NULL,
    updated_at           timestamptz DEFAULT now()
);

COMMENT ON TABLE public.user_stats IS 'Denormalized user stat counters';

-- ─────────────────────────────────────────────
-- sessions
-- Server-side session store (express-session compatible)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.sessions (
    sid     varchar PRIMARY KEY,
    sess    jsonb NOT NULL,
    expire  timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_expire ON public.sessions (expire);

COMMENT ON TABLE public.sessions IS 'Server-side session storage';

-- ─────────────────────────────────────────────
-- waitlist
-- Pre-launch email waitlist
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.waitlist (
    id         integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    email      varchar NOT NULL UNIQUE,
    created_at timestamptz DEFAULT now()
);

COMMENT ON TABLE public.waitlist IS 'Pre-launch waitlist signups';

-- ─────────────────────────────────────────────
-- policy_acceptance_log
-- Audit trail for policy/TOS acceptance
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.policy_acceptance_log (
    id              integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id         uuid NOT NULL REFERENCES public.users(id),
    policy_version  varchar NOT NULL,
    accepted_at     timestamptz DEFAULT now(),
    ip_address      varchar,
    user_agent      text
);

COMMENT ON TABLE public.policy_acceptance_log IS 'Audit log of policy acceptance events';

-- ─────────────────────────────────────────────
-- assets
-- Generic file/media uploads for users
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.assets (
    id           varchar PRIMARY KEY DEFAULT gen_random_uuid()::text,
    user_id      uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    kind         varchar NOT NULL,
    mime         varchar(100) NOT NULL,
    storage_path text NOT NULL,
    public_url   text,
    width        integer,
    height       integer,
    bytes        integer,
    created_at   timestamptz DEFAULT now()
);

COMMENT ON TABLE public.assets IS 'Generic uploaded media assets';

-- ─────────────────────────────────────────────
-- Deferred foreign keys for profiles → assets
-- ─────────────────────────────────────────────
ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_avatar_asset_id_fk
    FOREIGN KEY (avatar_asset_id) REFERENCES public.assets(id) ON DELETE SET NULL;

ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_banner_asset_id_fk
    FOREIGN KEY (banner_asset_id) REFERENCES public.assets(id) ON DELETE SET NULL;

-- ─────────────────────────────────────────────
-- Indexes
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_users_stripe_customer ON public.users (stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_assets_user_created ON public.assets (user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_policy_acceptance_user ON public.policy_acceptance_log (user_id);

-- ─────────────────────────────────────────────
-- Enable RLS on all tables
-- ─────────────────────────────────────────────
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.waitlist ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.policy_acceptance_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assets ENABLE ROW LEVEL SECURITY;
